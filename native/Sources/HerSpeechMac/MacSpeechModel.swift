import AppKit
import Foundation
import HerBilingualASR
import HerSpeechTextCore
import SwiftUI

private struct MacSpeechProfile: Decodable {
    let label: String
    let contextualStrings: [String]
    let hotwords: [String]
    enum CodingKeys: String, CodingKey {
        case label, hotwords
        case contextualStrings = "contextual_strings"
    }
}

@MainActor
final class MacSpeechModel: ObservableObject {
    @Published var originalText = ""
    @Published var mode: HerWordingMode = .neutral
    @Published var hotwordsEnabled = true
    @Published var profile = "contextual"
    @Published var customHotwords = ""
    @Published private(set) var state: MacAudioTranscriber.State = .idle
    @Published private(set) var status = "点击开始后才会申请并使用麦克风；离开 App 会停止录音。"
    @Published private(set) var resourceError = ""
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadFraction = 0.0
    @Published private(set) var modelReady = false
    @Published private(set) var downloadStatus = ""
    private var wording: HerSpeechWording?
    private var profiles: [String: MacSpeechProfile] = [:]
    private let recorder = MacAudioTranscriber()
    private var modelDownload: Task<Void, Never>?
    private var downloadID: UUID?
    private var recordingPrefix = ""

    init() {
        do {
            guard let url = Bundle.main.url(forResource: "rules", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            wording = try HerSpeechWording(rulesData: Data(contentsOf: url))
        } catch {
            resourceError = "词包未能载入，当前只处理「他／它→她」：" + error.localizedDescription
        }
        do {
            struct Document: Decodable {
                let version: Int
                let profiles: [String: MacSpeechProfile]
                let defaultProfile: String
                enum CodingKeys: String, CodingKey {
                    case version, profiles
                    case defaultProfile = "default_profile"
                }
            }
            guard let url = Bundle.main.url(forResource: "profiles", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            profiles = document.profiles
            if ["neutral", "contextual", "hotword"].contains(document.defaultProfile) {
                profile = document.defaultProfile
            }
        } catch {
            resourceError += (resourceError.isEmpty ? "" : "\n") + "词汇提示配置未能载入：" + error.localizedDescription
        }
        refreshModelStatus()
        recorder.onUpdate = { [weak self] update in
            guard let self = self else { return }
            self.state = update.state
            self.status = update.message
            if !update.transcript.isEmpty { self.originalText = self.recordingPrefix + update.transcript }
        }
    }

    var resultText: String {
        wording?.process(originalText, mode: mode) ?? HerSpeechText.feminine(originalText)
    }

    var canStart: Bool { state == .idle && !isDownloading && modelReady }
    var modelDirectory: URL { HerASRModelStore.defaultDirectory }

    private func refreshModelStatus() {
        modelReady = (try? HerASRModelStore().isReady) == true
        downloadStatus = modelReady
            ? "离线中英模型已下载；录音开始前会校验完整性。"
            : "首次使用请下载约 60.2 MB 的模型。文件识别和录音均在本机进行。"
    }

    func downloadModel() {
        if let task = modelDownload { task.cancel(); return }
        guard !state.isBusy else { return }
        let id = UUID()
        downloadID = id
        isDownloading = true
        downloadFraction = 0
        downloadStatus = "正在下载并校验固定版模型…"
        modelDownload = Task { [weak self] in
            guard let self = self else { return }
            do {
                let store = try HerASRModelStore()
                try await store.download { [weak self] fraction in
                    DispatchQueue.main.async {
                        guard let self = self, self.downloadID == id, self.isDownloading else { return }
                        self.downloadFraction = fraction
                    }
                }
                self.finishDownload(id: id, error: nil)
            } catch {
                self.finishDownload(id: id, error: Task.isCancelled ? "模型下载已取消，可稍后重试。" : error.localizedDescription)
            }
        }
    }

    private func finishDownload(id: UUID, error: String?) {
        guard downloadID == id else { return }
        modelDownload = nil
        downloadID = nil
        isDownloading = false
        refreshModelStatus()
        if let error { downloadStatus = error }
    }

    func startRecording() {
        guard canStart else { return }
        recordingPrefix = originalText
        if !recordingPrefix.isEmpty && !recordingPrefix.hasSuffix("\n") { recordingPrefix += "\n" }
        var words: [String] = []
        if hotwordsEnabled {
            if let selected = profiles[profile] { words += selected.contextualStrings + selected.hotwords }
            words += customHotwords.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        recorder.start(directory: modelDirectory, hotwords: words)
    }

    func stopRecording() { recorder.stop() }
    func cancelRecording() { recorder.cancel() }

    func resignActive() {
        // The permission dialog may temporarily take focus. Preparation checks foreground again
        // before opening the microphone, so granting permission cannot start a background session.
        if state == .listening || state == .finishing {
            recorder.cancel(message: "已离开 App，录音已停止并保留当前文字。回到窗口后可重新开始。")
        }
    }

    func shutdown() {
        recorder.cancel(message: "录音已停止。")
        modelDownload?.cancel()
    }

    func copyResult() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(resultText, forType: .string)
        status = "整理结果已复制；请在目标 App 中粘贴。"
    }

    func showLicenses() {
        if let window = licenseWindow { window.makeKeyAndOrderFront(nil); return }
        let names = ["Speech-Notice", "Sherpa-LICENSE", "ONNXRuntime-LICENSE", "ONNXRuntime-ThirdPartyNotices", "LICENSE", "AUTHORS"]
        let text = names.compactMap { name -> String? in
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return name + "\n\n" + content
        }.joined(separator: "\n\n────────\n\n")
        let controller = NSViewController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = text.isEmpty ? "许可资源未能载入，请查看项目仓库的 NOTICE。" : text
        scroll.documentView = view
        controller.view = scroll
        let window = NSWindow(contentViewController: controller)
        window.title = "开源组件与许可"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 520))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        licenseWindow = window
    }

    private var licenseWindow: NSWindow?
}
