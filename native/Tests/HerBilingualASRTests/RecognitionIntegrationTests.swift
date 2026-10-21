import AVFoundation
import Foundation
import XCTest
@testable import HerBilingualASR

/// Opt-in public-fixture test; no microphone or private audio is opened.
/// HER_ASR_TEST_MODEL_DIR=/model/cache HER_ASR_TEST_WAV=/official/0.wav swift test
final class RecognitionIntegrationTests: XCTestCase {
    func testOfficialMixedLanguageAudioAndLifecycle() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["HER_ASR_TEST_MODEL_DIR"],
              let wavPath = environment["HER_ASR_TEST_WAV"] else {
            throw XCTSkip("Set HER_ASR_TEST_MODEL_DIR and HER_ASR_TEST_WAV for public model integration")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath),
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let sampleRate = Int(file.processingFormat.sampleRate)
        XCTAssertFalse(samples.isEmpty)
        let recognizer = try HerBilingualRecognizer(modelDirectory: URL(fileURLWithPath: modelPath))
        for start in stride(from: 0, to: samples.count, by: 1024) {
            recognizer.accept(samples: Array(samples[start..<min(samples.count, start + 1024)]), sampleRate: sampleRate)
        }
        let result = recognizer.finish()
        print("PUBLIC MIXED FIXTURE (greedy): \(result)")
        XCTAssertTrue(result.contains(where: { $0 >= "一" && $0 <= "龥" }), result)
        XCTAssertTrue(result.uppercased().contains("MONDAY"), result)
        XCTAssertEqual(recognizer.finish(), result, "Finishing twice must not duplicate text")
        XCTAssertEqual(recognizer.accept(samples: [0]), result, "Finished sessions ignore further input")
        try recognizer.reset()
        XCTAssertEqual(recognizer.rawText, "")
        recognizer.accept(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(recognizer.finish(), result, "Reset must create a fresh input stream")

        let biased = try HerBilingualRecognizer(modelDirectory: URL(fileURLWithPath: modelPath),
                                               hotwords: ["MONDAY", "星期三"])
        biased.accept(samples: samples, sampleRate: sampleRate)
        let biasedText = biased.finish()
        print("PUBLIC MIXED FIXTURE (hotword beam): \(biasedText)")
        XCTAssertTrue(biasedText.uppercased().contains("MONDAY"), biasedText)
        XCTAssertTrue(biasedText.contains("星期三"), biasedText)
    }
}
