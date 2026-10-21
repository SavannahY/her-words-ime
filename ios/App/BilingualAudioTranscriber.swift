import AVFoundation
import Foundation
import HerBilingualASR

/// Model and inference stay on one queue; no microphone data is written to disk.
final class BilingualAudioTranscriber {
    var onUpdate: ((SpeechTranscriber.Update) -> Void)?
    private let queue = DispatchQueue(label: "org.herwords.bilingual", qos: .userInitiated)
    private let pending = DispatchSemaphore(value: 8)
    private var recognizer: HerBilingualRecognizer? // queue only
    private var activeToken: Int? // queue only; rejects delayed taps from earlier recordings
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var hasTap = false
    private var activated = false
    private var generation = 0 // main queue only
    private var state: SpeechTranscriber.State = .idle
    private var transcript = ""

    deinit {
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        if activated { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func start(hotwords: [String]) {
        guard !state.isBusy else { return }
        generation += 1
        let token = generation
        transcript = ""
        state = .authorizing
        publish("准备离线中英模型，首次使用需允许麦克风。")
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token, self.state == .authorizing else { return }
                guard allowed else { self.cancel(message: "麦克风权限未开启，仍可手动编辑文字。"); return }
                self.queue.async {
                    self.activeToken = token
                    do {
                        let store = try HerASRModelStore()
                        let model = try HerBilingualRecognizer(modelDirectory: store.directory, hotwords: hotwords)
                        self.recognizer = model
                        DispatchQueue.main.async {
                            guard self.generation == token, self.state == .authorizing else { return }
                            self.begin(token: token)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            guard self.generation == token else { return }
                            self.cancel(message: "离线语音未能启动：" + error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    private func begin(token: Int) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            activated = true
            let audio = AVAudioEngine()
            engine = audio
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  format.commonFormat == .pcmFormatFloat32 else {
                cancel(message: "当前麦克风音频格式不可用，请换用 Apple 识别或检查麦克风。")
                return
            }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self = self, let channels = buffer.floatChannelData else { return }
                guard self.pending.wait(timeout: .now()) == .success else {
                    DispatchQueue.main.async {
                        guard self.generation == token, self.state == .listening else { return }
                        self.cancel(message: "设备暂时跟不上实时识别，已停止并保留当前文字。可改用 Apple 识别。")
                    }
                    return
                }
                let frames = Int(buffer.frameLength)
                let count = Int(format.channelCount)
                let interleaved = format.isInterleaved
                var samples = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    for channel in 0..<count {
                        samples[frame] += interleaved ? channels[0][frame * count + channel] : channels[channel][frame]
                    }
                    samples[frame] /= Float(count)
                }
                let pcm = samples
                self.queue.async {
                    defer { self.pending.signal() }
                    guard self.activeToken == token, let model = self.recognizer else { return }
                    let text = model.accept(samples: pcm, sampleRate: Int(format.sampleRate))
                    DispatchQueue.main.async {
                        guard self.generation == token, self.state == .listening || self.state == .finishing else { return }
                        self.transcript = text
                        self.publish(self.state == .listening ? "正在离线识别中文与英文，音频留在设备内。" : "正在整理最后的文字…")
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
                guard let self = self, self.generation == token, self.state == .listening else { return }
                self.cancel(message: "音频输入设备发生变化，录音已停止。请检查麦克风后重新开始。")
            }
            publish("正在离线识别中文与英文，音频留在设备内。")
        } catch { cancel(message: "无法开始录音：" + error.localizedDescription) }
    }

    func stop() {
        guard state == .listening else { return }
        state = .finishing
        stopAudio()
        publish("录音已停止，正在整理最后的文字…")
        let token = generation
        queue.async {
            guard self.activeToken == token else { return }
            let final = self.recognizer?.finish() ?? ""
            self.recognizer = nil
            self.activeToken = nil
            DispatchQueue.main.async {
                guard self.generation == token, self.state == .finishing else { return }
                self.transcript = final
                self.state = .idle
                self.publish(final.isEmpty ? "没有识别到文字，可以再试一次。" : "离线识别完成，请核对原文与整理结果。")
            }
        }
    }

    func cancel(message: String) {
        let token = generation
        generation += 1
        stopAudio()
        queue.async {
            guard self.activeToken == token else { return }
            self.recognizer = nil
            self.activeToken = nil
        }
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
        if activated {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activated = false
        }
    }

    private func publish(_ message: String) {
        onUpdate?(SpeechTranscriber.Update(state: state, transcript: transcript, message: message))
    }
}
