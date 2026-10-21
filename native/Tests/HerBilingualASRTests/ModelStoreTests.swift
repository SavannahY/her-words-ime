import CryptoKit
import Foundation
import XCTest
@testable import HerBilingualASR

final class ModelStoreTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func canonicalData() throws -> Data {
        try Data(contentsOf: repository.appendingPathComponent("speech/asr-model.json"))
    }

    private func changedManifest(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: canonicalData()) as? [String: Any])
        change(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testBundledManifestAndSourceAreIdentical() throws {
        let source = try canonicalData()
        let resource = try Data(contentsOf: repository.appendingPathComponent(
            "native/Sources/HerBilingualASR/Resources/asr-model.json"))
        XCTAssertEqual(source, resource)
        let store = try HerASRModelStore()
        XCTAssertEqual(store.manifest.totalBytes, 60_155_435)
        XCTAssertEqual(store.manifest.revision, "e2382758de9a0219b4efe682b95af30b399db3b8")
        XCTAssertEqual(store.manifest.files.count, 5)
        XCTAssertEqual(store.manifest.license, "Apache-2.0")
        XCTAssertEqual(store.manifest.files.reduce(0, { $0 + $1.bytes }), store.manifest.totalBytes)
        XCTAssertTrue(store.manifest.files.allSatisfy { $0.url.path.contains(store.manifest.revision) })
    }

    func testMissingModelsThrowBeforeCallingNativeRecognizer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(try HerASRModelStore(directory: directory).isReady)
        XCTAssertThrowsError(try HerASRModelStore(directory: directory).validate())
        XCTAssertThrowsError(try HerBilingualRecognizer(modelDirectory: directory))
    }

    func testRejectsMalformedOrUnsafeManifest() throws {
        XCTAssertThrowsError(try HerASRModelStore(manifestData: Data("{}".utf8)))
        for invalid in ["../escape", ".", "..", "/absolute", "folder\\escape"] {
            let data = try changedManifest { json in
                var files = json["files"] as! [[String: Any]]
                files[0]["filename"] = invalid
                json["files"] = files
            }
            XCTAssertThrowsError(try HerASRModelStore(manifestData: data))
        }
        let data = try changedManifest { $0["totalBytes"] = 1 }
        XCTAssertThrowsError(try HerASRModelStore(manifestData: data))
    }

    func testHashValidationDetectsSameSizeCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data("x".utf8)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let data = try changedManifest { json in
            var files = json["files"] as! [[String: Any]]
            for index in files.indices {
                files[index]["bytes"] = 1
                files[index]["sha256"] = hash
            }
            json["files"] = files
            json["totalBytes"] = 5
        }
        let store = try HerASRModelStore(manifestData: data, directory: directory)
        for file in store.manifest.files {
            try body.write(to: directory.appendingPathComponent(file.filename))
        }
        XCTAssertTrue(store.isReady)
        XCTAssertNoThrow(try store.validate())
        try Data("y".utf8).write(to: store.url(forRole: "tokens"))
        XCTAssertTrue(store.isReady, "Readiness is deliberately a cheap size check")
        XCTAssertThrowsError(try store.validate(), "Inference must verify SHA-256, including same-size files")
    }

    /// Downloads five copies of the official 12 KB public BPE vocabulary, never audio.
    /// Opt in with HER_ASR_TEST_DOWNLOAD=1; ordinary unit tests require no network.
    func testURLSessionDownloadAndVerifiedCache() async throws {
        guard ProcessInfo.processInfo.environment["HER_ASR_TEST_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set HER_ASR_TEST_DOWNLOAD=1 for the small public HTTPS download check")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try changedManifest { json in
            var files = json["files"] as! [[String: Any]]
            let vocab = files.first(where: { $0["role"] as? String == "bpeVocab" })!
            for index in files.indices {
                for key in ["url", "bytes", "sha256"] { files[index][key] = vocab[key] }
            }
            json["files"] = files
            json["totalBytes"] = 12_564 * 5
        }
        let store = try HerASRModelStore(manifestData: data, directory: directory)
        let progress = ProgressValues()
        try await store.download { progress.append($0) }
        XCTAssertTrue(store.isReady)
        XCTAssertNoThrow(try store.validate())
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertTrue(progress.values.allSatisfy { 0...1 ~= $0 })
        // A second call verifies all cached files and completes without network.
        try await store.download()
        XCTAssertNoThrow(try store.validate())
    }
}

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
