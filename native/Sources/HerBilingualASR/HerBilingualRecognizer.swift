import Foundation
import HerSpeechTextCore
import SherpaOnnx

/// A single recording session. Confine every call, including reset, to one serial queue.
/// Returns cumulative recognition text; apply the shared feminine-text policy at display/export.
public final class HerBilingualRecognizer {
    private let store: HerASRModelStore
    private let hotwords: [String]
    private var recognizer: SherpaOnnxRecognizer
    private var committed = ""
    private var partial = ""
    private var finished = false
    private var inputSampleRate = 16000

    public init(modelDirectory: URL, hotwords: [String] = []) throws {
        let store = try HerASRModelStore(directory: modelDirectory)
        try store.validate()
        self.store = store
        self.hotwords = Self.cleanHotwords(hotwords)
        recognizer = try Self.makeRecognizer(store: store, hotwords: self.hotwords)
    }

    public var rawText: String { HerSpeechText.join(committed, partial) }

    @discardableResult
    public func accept(samples: [Float], sampleRate: Int = 16000) -> String {
        guard !finished, !samples.isEmpty, sampleRate > 0, sampleRate <= 384000 else { return rawText }
        inputSampleRate = sampleRate
        let finiteSamples = samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        recognizer.acceptWaveform(samples: finiteSamples, sampleRate: sampleRate)
        drain()
        if recognizer.isEndpoint() {
            committed = HerSpeechText.join(committed, partial)
            partial = ""
            recognizer.reset()
        }
        return rawText
    }

    @discardableResult
    public func finish() -> String {
        guard !finished else { return rawText }
        recognizer.acceptWaveform(samples: [Float](repeating: 0, count: max(1, inputSampleRate / 5)),
                                  sampleRate: inputSampleRate)
        recognizer.inputFinished()
        drain()
        finished = true
        return rawText
    }

    /// Recreates the stream, including after inputFinished. May fail if model files changed.
    public func reset() throws {
        try store.validate()
        recognizer = try Self.makeRecognizer(store: store, hotwords: hotwords)
        committed = ""
        partial = ""
        finished = false
        inputSampleRate = 16000
    }

    private func drain() {
        while recognizer.isReady() { recognizer.decode() }
        partial = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanHotwords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.prefix(128).compactMap { word in
            // A newline/colon in user input must not become a second hotword or a boosting score.
            let cleaned = word.components(separatedBy: .newlines).joined(separator: " ")
                .replacingOccurrences(of: ":", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !cleaned.isEmpty, cleaned.count <= 80, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
    }

    private static func makeRecognizer(store: HerASRModelStore, hotwords: [String]) throws
        -> SherpaOnnxRecognizer {
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: try store.url(forRole: "encoder").path,
            decoder: try store.url(forRole: "decoder").path,
            joiner: try store.url(forRole: "joiner").path
        )
        let model = sherpaOnnxOnlineModelConfig(
            tokens: try store.url(forRole: "tokens").path,
            transducer: transducer,
            numThreads: 2,
            provider: "cpu",
            modelType: store.manifest.modelType,
            modelingUnit: store.manifest.modelingUnit,
            bpeVocab: try store.url(forRole: "bpeVocab").path
        )
        let buffer = hotwords.joined(separator: "\n")
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: model,
            enableEndpoint: true,
            rule2MinTrailingSilence: 0.8,
            decodingMethod: hotwords.isEmpty ? "greedy_search" : "modified_beam_search",
            maxActivePaths: 4,
            hotwordsScore: 1.5,
            hotwordsBuf: buffer,
            hotwordsBufSize: buffer.utf8.count
        )
        return SherpaOnnxRecognizer(config: &config)
    }
}
