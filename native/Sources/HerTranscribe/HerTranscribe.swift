import AVFoundation
import Darwin
import Foundation
import HerBilingualASR
import HerSpeechTextCore

private enum CommandError: LocalizedError {
    case arguments(String)
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .arguments(let message), .audio(let message): return message
        }
    }
}

private struct Options {
    var downloadModel = false
    var audioURL: URL?
    var modelDirectory: URL?
    var hotwords: [String] = []
    var json = false
    var help = false

    init(arguments: [String]) throws {
        var index = 0
        func fileURL(_ value: String) -> URL {
            URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }
        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CommandError.arguments("\(flag) 后需要一个值。")
            }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h": help = true
            case "--download-model": downloadModel = true
            case "--json": json = true
            case "--audio":
                guard audioURL == nil else { throw CommandError.arguments("--audio 只能指定一次。") }
                audioURL = fileURL(try value(after: argument))
            case "--model-directory":
                guard modelDirectory == nil else {
                    throw CommandError.arguments("--model-directory 只能指定一次。")
                }
                modelDirectory = fileURL(try value(after: argument))
            case "--hotword":
                let word = try value(after: argument).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty, word.count <= 80, hotwords.count < 128 else {
                    throw CommandError.arguments("每个热词需为 1–80 个字符，最多 128 项。")
                }
                hotwords.append(word)
            default: throw CommandError.arguments("无法识别参数：\(argument)。使用 --help 查看用法。")
            }
            index += 1
        }
        guard help || downloadModel || audioURL != nil else {
            throw CommandError.arguments("请指定 --download-model 或 --audio PATH。使用 --help 查看用法。")
        }
        if !help, audioURL == nil, !hotwords.isEmpty {
            throw CommandError.arguments("--hotword 需要与 --audio 一起使用。")
        }
    }
}

private struct Transcript: Encodable {
    let backend: String
    let model: String
    let modelRevision: String
    let audio: String
    let audioDurationSeconds: Double
    let elapsedSeconds: Double
    let rawText: String
    let text: String
    let translation: Bool
}

private struct ModelDownload: Encodable {
    let downloaded: Bool
    let model: String
    let modelRevision: String
    let modelDirectory: String
    let bytes: Int64
}

@main
private enum HerTranscribe {
    private static let usage = """
    她说：本地中英双语文件转写（不会翻译英文，不请求麦克风权限）

    用法：
      her-transcribe --download-model [--model-directory PATH] [--json]
      her-transcribe --audio PATH [--hotword WORD ...] [--model-directory PATH] [--json]

    --download-model        主动下载并校验约 60.2 MB 的固定版模型
    --audio PATH            转写本地音频，自动转换为 16 kHz 单声道 Float32
    --model-directory PATH  使用指定模型目录；默认使用当前用户的应用支持目录
    --hotword WORD          可重复指定拼写提示；只影响识别概率，不保证出现
    --json                  标准输出为 JSON；进度与错误写入标准错误
    --help                  显示帮助

    可同时使用 --download-model 和 --audio。单独 --audio 不会自动下载。
    输出同时包含识别原文与「他／它→她」结果；英文代词、URL、邮箱及显式代码保留。
    识别可能出错，请校对原文。这是文件工具，不会接管其他 App 的听写。
    """

    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(usage)
                return
            }
            let store = try HerASRModelStore(directory: options.modelDirectory)
            if options.downloadModel {
                standardError("下载并校验模型：\(store.manifest.name)\n目标目录：\(store.directory.path)\n")
                try await store.download()
                standardError("模型已校验完成。\n")
            }
            if let audioURL = options.audioURL {
                let started = Date()
                let recognizer = try HerBilingualRecognizer(
                    modelDirectory: store.directory, hotwords: options.hotwords)
                let frameCount = try AudioFileReader.decode(audioURL) { samples in
                    recognizer.accept(samples: samples)
                }
                let rawText = recognizer.finish()
                let result = Transcript(
                    backend: "sherpa-onnx", model: store.manifest.id,
                    modelRevision: store.manifest.revision, audio: audioURL.path,
                    audioDurationSeconds: Double(frameCount) / 16000,
                    elapsedSeconds: Date().timeIntervalSince(started),
                    rawText: rawText, text: HerSpeechText.feminine(rawText), translation: false)
                if options.json {
                    try printJSON(result)
                } else {
                    print("识别原文：\n\(result.rawText)\n\n她说结果：\n\(result.text)")
                    standardError(String(format: "\n音频 %.2f 秒，处理 %.2f 秒；未翻译英文，请校对结果。\n",
                                         result.audioDurationSeconds, result.elapsedSeconds))
                }
            } else if options.json {
                try printJSON(ModelDownload(
                    downloaded: true, model: store.manifest.id, modelRevision: store.manifest.revision,
                    modelDirectory: store.directory.path, bytes: store.manifest.totalBytes))
            } else {
                print("模型可用：\(store.directory.path)")
            }
        } catch {
            standardError("错误：\(error.localizedDescription)\n")
            if case CommandError.arguments = error { exit(2) }
            exit(1)
        }
    }

    private static func printJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    private static func standardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// Converts incrementally so a long file does not require an entire decoded recording in memory.
/// AVAudioFile supports the local file formats provided by the operating system.
private enum AudioFileReader {
    @discardableResult
    static func decode(_ url: URL, consume: ([Float]) -> Void) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { throw CommandError.audio("音频文件不存在：\(url.path)") }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.channelCount > 0,
              file.processingFormat.sampleRate > 0 else {
            throw CommandError.audio("音频文件没有可读取的声音数据。")
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1600) else {
            throw CommandError.audio("无法将音频转换为 16 kHz 单声道格式。")
        }
        converter.downmix = true
        var totalFrames: Int64 = 0
        var emptyPasses = 0
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let count = AVAudioFrameCount(min(max(requested, 1), 8192))
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                    readError = CommandError.audio("无法分配音频转换缓冲区。")
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: count)
                    inputStatus.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if output.frameLength > 0, let samples = output.floatChannelData?[0] {
                consume(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
                totalFrames += Int64(output.frameLength)
                emptyPasses = 0
            } else {
                emptyPasses += 1
            }
            switch status {
            case .endOfStream: return totalFrames
            case .error: throw CommandError.audio("音频转换失败。")
            case .haveData, .inputRanDry:
                guard emptyPasses <= 8 else {
                    throw CommandError.audio("音频转换没有继续产生数据。")
                }
            @unknown default: throw CommandError.audio("系统返回了未知的音频转换状态。")
            }
        }
    }
}
