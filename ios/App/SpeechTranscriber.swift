import Foundation
import AVFoundation
import Speech

/// Owns one foreground recognition session. UI calls and all state callbacks
/// run on the main queue; the audio tap only feeds its captured request.
final class SpeechTranscriber: NSObject {
    enum Route {
        case onDevice
        case allowNetwork
    }

    enum State {
        case idle
        case authorizing
        case listening
        case finishing

        var isBusy: Bool { self != .idle }
    }

    struct Update {
        let state: State
        let transcript: String
        let message: String
    }

    var onUpdate: ((Update) -> Void)?
    private(set) var state: State = .idle
    private var transcript = ""
    private var message = "点击开始后才会申请麦克风和语音识别权限。"
    private var generation = 0
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var audioEngine: AVAudioEngine?
    private var installedTap = false
    private var endedAudio = false
    private var activatedAudioSession = false
    private var finishTimeout: DispatchWorkItem?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
                  AVAudioSession.InterruptionType(rawValue: value.uintValue) == .began,
                  self.state.isBusy else { return }
            self.cancel(message: "录音被系统中断，已保留已识别文字。")
        }
    }

    deinit {
        finishTimeout?.cancel()
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        recognitionTask?.cancel()
        if let engine = audioEngine {
            engine.stop()
            if installedTap { engine.inputNode.removeTap(onBus: 0) }
        }
        if activatedAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func start(route: Route) {
        guard !state.isBusy else { return }
        generation += 1
        let token = generation
        transcript = ""
        state = .authorizing
        message = "等待语音识别与麦克风授权，可随时取消。"
        publish()

        // Authorization is only requested from this explicit user action.
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token,
                      self.state == .authorizing else { return }
                guard authorization == .authorized else {
                    let explanation: String
                    switch authorization {
                    case .denied:
                        explanation = "语音识别权限未开启。可在系统设置中为「她说」开启；仍可手动编辑文字。"
                    case .restricted:
                        explanation = "这台设备限制了语音识别。仍可手动编辑文字。"
                    default:
                        explanation = "未取得语音识别权限，请稍后重试。"
                    }
                    self.complete(message: explanation, cancelTask: true)
                    return
                }
                self.requestMicrophonePermission(route: route, token: token)
            }
        }
    }

    private func requestMicrophonePermission(route: Route, token: Int) {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token,
                      self.state == .authorizing else { return }
                guard allowed else {
                    self.complete(message: "麦克风权限未开启。可在系统设置中为「她说」开启；仍可手动编辑文字。",
                                  cancelTask: true)
                    return
                }
                self.beginRecording(route: route, token: token)
            }
        }
    }

    private func beginRecording(route: Route, token: Int) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            complete(message: "当前设备没有可用的中文语音识别器。", cancelTask: true)
            return
        }
        if route == .onDevice && !recognizer.supportsOnDeviceRecognition {
            complete(message: "当前设备或中文模型不支持设备端识别。可继续手动输入，或主动选择「允许联网」后重试；未自动改用联网识别。",
                     cancelTask: true)
            return
        }
        guard recognizer.isAvailable else {
            complete(message: "中文语音服务当前不可用，请稍后重试。", cancelTask: true)
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)
            activatedAudioSession = true

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = route == .onDevice
            request.taskHint = .dictation
            request.contextualStrings = ["她们", "女性互助", "女性友好", "女力"]
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                complete(message: "当前麦克风没有可用音频输入，请检查后重试。", cancelTask: true)
                return
            }
            self.recognizer = recognizer
            self.audioEngine = engine
            self.request = request
            endedAudio = false
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            installedTap = true
            state = .listening
            message = route == .onDevice
                ? "正在设备端识别中文。停止后可检查和编辑原文。"
                : "正在识别中文；此模式允许 Apple 使用联网语音服务。"

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == token,
                          self.state == .listening || self.state == .finishing else { return }
                    if let result = result {
                        self.transcript = result.bestTranscription.formattedString
                        self.publish()
                        if result.isFinal {
                            self.complete(message: self.transcript.isEmpty
                                ? "没有识别到文字，可以再试一次。"
                                : "识别完成。请检查原文与结果，再复制使用。", cancelTask: false)
                            return
                        }
                    }
                    if let error = error {
                        self.complete(message: "语音识别已结束，已保留当前文字。\n" + error.localizedDescription,
                                      cancelTask: true)
                    }
                }
            }
            engine.prepare()
            try engine.start()
            publish()
        } catch {
            complete(message: "无法开始录音：" + error.localizedDescription, cancelTask: true)
        }
    }

    /// End audio input while retaining the task long enough for its final result.
    func stop() {
        guard state.isBusy else { return }
        if state == .authorizing {
            cancel(message: "已取消本次录音。")
            return
        }
        guard state == .listening else { return }
        state = .finishing
        message = "录音已停止，正在整理最后的文字…"
        finishAudioInput()
        publish()
        let token = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token, self.state == .finishing else { return }
            self.complete(message: self.transcript.isEmpty
                ? "录音已停止，没有识别到文字。"
                : "录音已停止，已保留当前识别结果，可继续编辑。", cancelTask: true)
        }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    /// Cancels immediately and invalidates permission and recognition callbacks.
    func cancel(message: String = "已取消录音，已保留已识别文字。") {
        guard state.isBusy else { return }
        complete(message: message, cancelTask: true)
    }

    private func finishAudioInput() {
        if let engine = audioEngine {
            engine.stop()
            if installedTap {
                engine.inputNode.removeTap(onBus: 0)
                installedTap = false
            }
        }
        if !endedAudio {
            request?.endAudio()
            endedAudio = true
        }
        if activatedAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedAudioSession = false
        }
    }

    private func complete(message: String, cancelTask: Bool) {
        generation += 1
        finishTimeout?.cancel()
        finishTimeout = nil
        finishAudioInput()
        if cancelTask { recognitionTask?.cancel() }
        recognitionTask = nil
        request = nil
        audioEngine = nil
        recognizer = nil
        state = .idle
        self.message = message
        publish()
    }

    private func publish() {
        onUpdate?(Update(state: state, transcript: transcript, message: message))
    }
}
