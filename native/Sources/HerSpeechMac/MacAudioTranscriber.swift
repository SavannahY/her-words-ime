import AppKit
import AVFoundation
import Foundation
import HerBilingualASR

/// AVAudioEngine stays on the main actor; all model access stays on one inference queue.
@MainActor
final class MacAudioTranscriber {
    enum State: Equatable {
        case idle, authorizing, listening, finishing
        var isBusy: Bool { self != .idle }
    }

    struct Update {
        let state: State
        let transcript: String
        let message: String
    }

    var onUpdate: ((Update) -> Void)?
    private(set) var state: State = .idle
    private let inference = MacInferenceQueue()
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var hasTap = false
    private var generation = 0
    private var transcript = ""

    func start(directory: URL, hotwords: [String]) {
        guard state == .idle else { return }
        generation += 1
        let token = generation
        transcript = ""
        state = .authorizing
        publish("准备离线模型；首次录音需要允许麦克风。")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            prepare(directory: directory, hotwords: hotwords, token: token)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == token, self.state == .authorizing else { return }
                    if allowed { self.prepare(directory: directory, hotwords: hotwords, token: token) }
                    else { self.cancel(message: "未取得麦克风权限。可在系统设置 → 隐私与安全性 → 麦克风中开启。") }
                }
            }
        default:
            cancel(message: "麦克风权限未开启。可在系统设置 → 隐私与安全性 → 麦克风中为「她说语音」开启。")
        }
    }

    private func prepare(directory: URL, hotwords: [String], token: Int) {
        inference.prepare(directory: directory, hotwords: hotwords, token: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token, self.state == .authorizing else { return }
                switch result {
                case .success:
                    guard NSApplication.shared.isActive else {
                        self.cancel(message: "App 当前不在前台，未开始录音。回到窗口后请重新点击开始。")
                        return
                    }
                    self.begin(token: token)
                case .failure(let error):
                    self.cancel(message: "离线语音未能启动：" + error.localizedDescription)
                }
            }
        }
    }

    private func begin(token: Int) {
        do {
            let audio = AVAudioEngine()
            engine = audio
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  format.commonFormat == .pcmFormatFloat32 else {
                cancel(message: "当前麦克风没有可用的浮点音频输入，请检查输入设备后重试。")
                return
            }
            let inference = self.inference
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                guard channelCount > 0 else { return }
                var samples = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    for channel in 0..<channelCount {
                        samples[frame] += buffer.format.isInterleaved
                            ? channels[0][frame * channelCount + channel] : channels[channel][frame]
                    }
                    samples[frame] /= Float(channelCount)
                }
                let accepted = inference.accept(
                    samples: samples, sampleRate: Int(buffer.format.sampleRate), token: token
                ) { [weak self] text in
                    DispatchQueue.main.async {
                        guard let self = self, self.generation == token,
                              self.state == .listening || self.state == .finishing else { return }
                        self.transcript = text
                        self.publish(self.state == .listening ? "正在本机识别中文与英文…" : "正在整理最后的文字…")
                    }
                }
                if !accepted {
                    DispatchQueue.main.async {
                        guard let self = self, self.generation == token, self.state == .listening else { return }
                        self.cancel(message: "设备暂时跟不上实时识别，已停止并保留当前文字。")
                    }
                }
            }
            hasTap = true
            audio.prepare()
            try audio.start()
            state = .listening
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == token, self.state == .listening else { return }
                    self.cancel(message: "音频输入设备发生变化，录音已停止。请检查麦克风后重新开始。")
                }
            }
            publish("正在本机识别中文与英文；音频不上传、不写入文件。")
        } catch {
            cancel(message: "无法开始录音：" + error.localizedDescription)
        }
    }

    func stop() {
        if state == .authorizing { cancel(message: "已取消本次录音准备。"); return }
        guard state == .listening else { return }
        state = .finishing
        stopAudio()
        publish("麦克风已停止，正在整理最后的文字…")
        let token = generation
        inference.finish(token: token) { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token, self.state == .finishing else { return }
                self.transcript = text
                self.state = .idle
                self.publish(text.isEmpty ? "没有识别到文字，可以再试一次。" : "识别完成，请校对原文与整理结果。")
            }
        }
    }

    func cancel(message: String = "已取消录音，已保留已识别文字。") {
        let token = generation
        generation += 1
        stopAudio()
        inference.cancel(token: token)
        state = .idle
        publish(message)
    }

    private func stopAudio() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        engine = nil
    }

    private func publish(_ message: String) {
        onUpdate?(Update(state: state, transcript: transcript, message: message))
    }
}

/// Only these queue-confined methods may touch the recognizer or its session token.
private final class MacInferenceQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.herwords.speech.mac.inference", qos: .userInitiated)
    private let pending = DispatchSemaphore(value: 8)
    private var recognizer: HerBilingualRecognizer?
    private var activeToken: Int?

    func prepare(directory: URL, hotwords: [String], token: Int,
                 completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            self.activeToken = token
            do {
                self.recognizer = try HerBilingualRecognizer(modelDirectory: directory, hotwords: hotwords)
                completion(.success(()))
            } catch {
                self.recognizer = nil
                completion(.failure(error))
            }
        }
    }

    func accept(samples: [Float], sampleRate: Int, token: Int,
                update: @escaping @Sendable (String) -> Void) -> Bool {
        guard pending.wait(timeout: .now()) == .success else { return false }
        queue.async {
            defer { self.pending.signal() }
            guard self.activeToken == token, let recognizer = self.recognizer else { return }
            update(recognizer.accept(samples: samples, sampleRate: sampleRate))
        }
        return true
    }

    func finish(token: Int, completion: @escaping @Sendable (String) -> Void) {
        queue.async {
            guard self.activeToken == token else { return }
            let text = self.recognizer?.finish() ?? ""
            self.recognizer = nil
            self.activeToken = nil
            completion(text)
        }
    }

    func cancel(token: Int) {
        queue.async {
            guard self.activeToken == token else { return }
            self.recognizer = nil
            self.activeToken = nil
        }
    }
}
