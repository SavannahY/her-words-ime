import CryptoKit
import Foundation

public enum HerASRError: LocalizedError {
    case invalidManifest(String)
    case missingModel(String)
    case invalidModel(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let detail): return "语音模型清单无效：\(detail)"
        case .missingModel(let name): return "尚未下载完整语音模型：\(name)"
        case .invalidModel(let name): return "语音模型校验失败，请重新下载：\(name)"
        case .downloadFailed(let detail): return "语音模型下载失败：\(detail)"
        }
    }
}

public struct HerASRModelFile: Codable, Sendable {
    public let role: String
    public let filename: String
    public let url: URL
    public let bytes: Int64
    public let sha256: String
}

public struct HerASRModelManifest: Codable, Sendable {
    public let id: String
    public let name: String
    public let repository: URL
    public let revision: String
    public let license: String
    public let licenseURL: URL
    public let sampleRate: Int
    public let featureDim: Int
    public let modelType: String
    public let modelingUnit: String
    public let totalBytes: Int64
    public let files: [HerASRModelFile]
}

/// Downloads only public model files. Audio and transcripts never enter this store.
/// Call `validate()` before inference: `isReady` is a fast size/presence check.
public struct HerASRModelStore: Sendable {
    public let manifest: HerASRModelManifest
    public let directory: URL

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HerWordsSpeech", isDirectory: true)
            .appendingPathComponent("zipformer-small-zh-en-2023-02-16", isDirectory: true)
    }

    public init(manifestData: Data? = nil, directory: URL? = nil) throws {
        let data: Data
        if let manifestData {
            data = manifestData
        } else {
            // Standalone signed Mac apps place the manifest in Contents/Resources.
            // SwiftPM's command-line resource bundle remains the fallback for CLI/tests.
            guard let url = Bundle.main.url(forResource: "asr-model", withExtension: "json") ??
                    Bundle.module.url(forResource: "asr-model", withExtension: "json") else {
                throw HerASRError.invalidManifest("缺少内置清单")
            }
            data = try Data(contentsOf: url)
        }
        do {
            manifest = try JSONDecoder().decode(HerASRModelManifest.self, from: data)
        } catch {
            throw HerASRError.invalidManifest(error.localizedDescription)
        }
        self.directory = directory ?? Self.defaultDirectory
        let roles = Set(manifest.files.map(\.role))
        guard roles == Set(["encoder", "decoder", "joiner", "tokens", "bpeVocab"]),
              manifest.files.count == 5,
              Set(manifest.files.map(\.filename)).count == 5,
              manifest.sampleRate == 16000, manifest.featureDim == 80,
              manifest.modelType == "zipformer", manifest.modelingUnit == "cjkchar+bpe",
              manifest.files.allSatisfy({ file in
                  file.bytes > 0 && file.bytes <= 1_000_000_000 &&
                  file.url.scheme == "https" && file.url.host != nil &&
                  file.filename != "." && file.filename != ".." && !file.filename.isEmpty &&
                  !file.filename.contains("/") && !file.filename.contains("\\") &&
                  file.sha256.count == 64 && file.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
              }),
              manifest.totalBytes == manifest.files.reduce(0, { $0 + $1.bytes }) else {
            throw HerASRError.invalidManifest("文件角色、路径、大小或模型配置不正确")
        }
    }

    public var isReady: Bool {
        manifest.files.allSatisfy { file in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: localURL(for: file).path),
                  let bytes = attributes[.size] as? NSNumber,
                  attributes[.type] as? FileAttributeType == .typeRegular else { return false }
            return bytes.int64Value == file.bytes
        }
    }

    public func validate() throws {
        for file in manifest.files { try validate(file, at: localURL(for: file)) }
    }

    public func url(forRole role: String) throws -> URL {
        guard let file = manifest.files.first(where: { $0.role == role }) else {
            throw HerASRError.invalidManifest("缺少 \(role)")
        }
        return localURL(for: file)
    }

    /// Progress is the fraction of the five pinned files downloaded or already verified.
    public func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed: Int64 = 0
        progress(0)
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = localURL(for: file)
            if (try? validate(file, at: destination)) != nil {
                completed += file.bytes
                progress(Double(completed) / Double(manifest.totalBytes))
                continue
            }
            let delegate = ModelDownloadProgress(
                completed: completed, fileBytes: file.bytes,
                totalBytes: manifest.totalBytes, progress: progress
            )
            let (temporary, response) = try await URLSession.shared.download(from: file.url, delegate: delegate)
            defer { try? manager.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HerASRError.downloadFailed(file.filename)
            }
            try validate(file, at: temporary)
            try Task.checkCancellation()
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: temporary, to: destination)
            completed += file.bytes
            progress(Double(completed) / Double(manifest.totalBytes))
        }
        try validate()
        progress(1)
    }

    private func localURL(for file: HerASRModelFile) -> URL {
        directory.appendingPathComponent(file.filename, isDirectory: false)
    }

    private func validate(_ file: HerASRModelFile, at url: URL) throws {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let bytes = attributes[.size] as? NSNumber,
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw HerASRError.missingModel(file.filename)
        }
        guard bytes.int64Value == file.bytes else { throw HerASRError.invalidModel(file.filename) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw HerASRError.invalidModel(file.filename) }
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let completed: Int64
    let fileBytes: Int64
    let totalBytes: Int64
    let progress: @Sendable (Double) -> Void

    init(completed: Int64, fileBytes: Int64, totalBytes: Int64,
         progress: @escaping @Sendable (Double) -> Void) {
        self.completed = completed
        self.fileBytes = fileBytes
        self.totalBytes = totalBytes
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(Double(completed + min(max(0, totalBytesWritten), fileBytes)) / Double(totalBytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
