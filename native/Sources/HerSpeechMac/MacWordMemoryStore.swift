import Foundation
import Darwin

/// The same on-disk protocol used by the Rime filter and the local manager.
/// Rime alone writes learned rows; managers lock and atomically replace policy.
struct MacRememberedWord: Identifiable, Equatable {
    let input: String
    let text: String
    let count: Int
    let lastUsed: Int
    let manual: Bool
    var id: String { input + "\u{0}" + MacWordMemoryFileStore.key(text) }
}

struct MacWordMemorySnapshot {
    var entries: [MacRememberedWord] = []
    var blockedWords: [String] = []
    var learningEnabled = true
}

struct MacWordMemoryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class MacWordMemoryFileStore {
    private struct Policy {
        var learning = true
        var clearBefore = 0
        var manual: [String: MacRememberedWord] = [:]
        var blocked: [String: (String, Int)] = [:]
        var forgotten: [String: (String, Int)] = [:]
    }

    let directory: URL
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Rime", isDirectory: true)
    }
    private let header = "HER_WORD_MEMORY\t1"
    private let maxBytes = 2_000_000
    private let maxEntries = 2_000

    init(directory: URL = MacWordMemoryFileStore.defaultDirectory) {
        self.directory = directory
    }

    static func key(_ text: String) -> String {
        String(decoding: text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }

    static func isBlocked(_ text: String, by blocked: [String]) -> Bool {
        let candidate = Array(key(text).utf8)
        func word(_ byte: UInt8) -> Bool {
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
        }
        for term in blocked {
            let bytes = Array(key(term).utf8)
            guard !bytes.isEmpty, bytes.count <= candidate.count else { continue }
            let ascii = bytes.allSatisfy { $0 < 128 }
            for start in 0...(candidate.count - bytes.count) where candidate[start..<(start + bytes.count)].elementsEqual(bytes) {
                let end = start + bytes.count
                if !ascii || ((start == 0 || !word(candidate[start - 1])) && (end == candidate.count || !word(candidate[end]))) {
                    return true
                }
            }
        }
        return false
    }

    private func word(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/:@，。？！；、（）【】")
        guard !value.isEmpty, value.unicodeScalars.count <= 32, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: {
                  $0.value < 32 || $0.value == 127 || $0.properties.isWhitespace || forbidden.contains($0)
              }) else {
            throw MacWordMemoryError(message: "请输入 1–32 字的单个词语或名字，不含空白、网址、邮箱或句子标点。")
        }
        return value
    }

    private func input(_ text: String) throws -> String {
        let value = Self.key(text).replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (97...122).contains($0) }) else {
            throw MacWordMemoryError(message: "输入码请使用英文字母，例如 zhangxiaofang、zxf 或 github。")
        }
        return value
    }

    private func lines(_ filename: String) throws -> [[String]]? {
        let url = directory.appendingPathComponent(filename)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        guard values.isSymbolicLink != true, (values.fileSize ?? maxBytes + 1) <= maxBytes else {
            throw MacWordMemoryError(message: "词库文件类型或大小异常，未改动原文件。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else {
            throw MacWordMemoryError(message: "词库不是有效 UTF-8，未改动原文件。")
        }
        var rows = text.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        guard rows.first == header, rows.count <= 8_003 else {
            throw MacWordMemoryError(message: "词库版本或格式异常，未改动原文件。")
        }
        return rows.dropFirst().filter { !$0.isEmpty }.map { $0.components(separatedBy: "\t") }
    }

    private func number(_ text: String) throws -> Int {
        guard (1...12).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text) else { throw MacWordMemoryError(message: "词库数字格式异常。") }
        return value
    }

    private func loadPolicy() throws -> Policy {
        var policy = Policy()
        guard let rows = try lines("her_memory_policy.tsv") else { return policy }
        var seen = Set<String>()
        for row in rows {
            let identity: String
            switch row.first {
            case "S":
                guard row.count == 3 else { throw MacWordMemoryError(message: "词库设置行格式异常。") }
                if row[1] == "learning", row[2] == "1" || row[2] == "0" { policy.learning = row[2] == "1" }
                else if row[1] == "clear_before" { policy.clearBefore = try number(row[2]) }
                else { throw MacWordMemoryError(message: "词库设置无法识别。") }
                identity = "S\t" + row[1]
            case "M":
                guard row.count == 4 else { throw MacWordMemoryError(message: "词库词条格式异常。") }
                let code = try input(row[1]), text = try word(row[2]), time = try number(row[3])
                guard code == row[1], text == row[2] else { throw MacWordMemoryError(message: "词库词条不是规范格式。") }
                let entry = MacRememberedWord(input: code, text: text, count: 1, lastUsed: time, manual: true)
                policy.manual[entry.id] = entry
                identity = "M\t" + entry.id
            case "B", "F":
                guard row.count == 3 else { throw MacWordMemoryError(message: "词库删除记录格式异常。") }
                let text = try word(row[1]), time = try number(row[2])
                guard text == row[1] else { throw MacWordMemoryError(message: "词库删除记录不是规范格式。") }
                if row[0] == "B" { policy.blocked[Self.key(text)] = (text, time) }
                else { policy.forgotten[Self.key(text)] = (text, time) }
                identity = row[0] + "\t" + Self.key(text)
            default: throw MacWordMemoryError(message: "词库含有无法识别的记录，未改动原文件。")
            }
            guard seen.insert(identity).inserted else { throw MacWordMemoryError(message: "词库含重复记录，未改动原文件。") }
        }
        guard policy.manual.count <= maxEntries, policy.blocked.count <= maxEntries,
              policy.forgotten.count <= maxEntries else { throw MacWordMemoryError(message: "词库条目超过上限。") }
        return policy
    }

    private func snapshot(_ policy: Policy) throws -> MacWordMemorySnapshot {
        let blocked = policy.blocked.values.map { $0.0 }.sorted()
        var entries = policy.manual.filter { !Self.isBlocked($0.value.text, by: blocked) }
        var seen = Set<String>()
        for row in try lines("her_memory_learned.tsv") ?? [] {
            guard row.count == 5, row[0] == "L" else { throw MacWordMemoryError(message: "已学习词库格式异常。") }
            let code = try input(row[1]), text = try word(row[2])
            let count = try number(row[3]), lastUsed = try number(row[4])
            guard code == row[1], text == row[2], (1...1_000_000).contains(count),
                  seen.insert(code + "\u{0}" + Self.key(text)).inserted, seen.count <= maxEntries else {
                throw MacWordMemoryError(message: "已学习词库记录不是规范格式。")
            }
            guard lastUsed > max(policy.clearBefore, policy.forgotten[Self.key(text)]?.1 ?? 0),
                  !Self.isBlocked(text, by: blocked) else { continue }
            let entry = MacRememberedWord(input: code, text: text, count: count, lastUsed: lastUsed, manual: false)
            if entries[entry.id] == nil { entries[entry.id] = entry }
        }
        let ordered = entries.values.sorted {
            if $0.manual != $1.manual { return $0.manual }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.id < $1.id
        }
        return MacWordMemorySnapshot(entries: ordered, blockedWords: blocked,
                                     learningEnabled: policy.learning)
    }

    func read() throws -> MacWordMemorySnapshot { try snapshot(loadPolicy()) }

    private func serialize(_ policy: Policy) -> Data {
        var rows = [header, "S\tlearning\t" + (policy.learning ? "1" : "0"), "S\tclear_before\t\(policy.clearBefore)"]
        rows += policy.manual.values.sorted { $0.id < $1.id }.map { "M\t\($0.input)\t\($0.text)\t\($0.lastUsed)" }
        rows += policy.blocked.values.sorted { $0.0 < $1.0 }.map { "B\t\($0.0)\t\($0.1)" }
        rows += policy.forgotten.values.sorted { $0.0 < $1.0 }.map { "F\t\($0.0)\t\($0.1)" }
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }

    private func mutate(_ change: (inout Policy, Int) throws -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard (folder[.type] as? FileAttributeType) == .typeDirectory,
              (folder[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw MacWordMemoryError(message: "本地词库目录必须属于当前用户，且不能是符号链接。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lockURL = directory.appendingPathComponent("her_memory_policy.lock")
        let fd = lockURL.path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw MacWordMemoryError(message: "无法锁定本地词库。") }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MacWordMemoryError(message: "无法锁定本地词库。") }
        var policy = try loadPolicy()
        // Refuse to edit when either file is damaged; preserve the original data.
        _ = try snapshot(policy)
        try change(&policy, Int(Date().timeIntervalSince1970))
        guard policy.manual.count <= maxEntries, policy.blocked.count <= maxEntries,
              policy.forgotten.count <= maxEntries else { throw MacWordMemoryError(message: "词库已满，请先清理部分词条。") }
        let destination = directory.appendingPathComponent("her_memory_policy.tsv")
        let temporary = directory.appendingPathComponent(".her-memory-" + UUID().uuidString)
        let data = serialize(policy)
        guard data.count <= maxBytes, FileManager.default.createFile(atPath: temporary.path, contents: data,
                    attributes: [.posixPermissions: 0o600]) else {
            throw MacWordMemoryError(message: "无法写入本地词库，原词库保留。")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard temporary.path.withCString({ source in destination.path.withCString { rename(source, $0) } }) == 0 else {
            throw MacWordMemoryError(message: "无法保存本地词库，原词库保留。")
        }
    }

    func remember(text: String, input: String) throws {
        let value = try word(text), code = try self.input(input)
        try mutate { policy, now in
            guard !Self.isBlocked(value, by: policy.blocked.values.map { $0.0 }) else {
                throw MacWordMemoryError(message: "这个词已设为不再推荐，请先在隐藏列表恢复。")
            }
            let entry = MacRememberedWord(input: code, text: value, count: 1, lastUsed: now, manual: true)
            policy.manual = policy.manual.filter { Self.key($0.value.text) != Self.key(value) }
            policy.manual[entry.id] = entry
        }
    }

    func forget(text: String) throws {
        let value = try word(text)
        try mutate { policy, now in
            policy.manual = policy.manual.filter { Self.key($0.value.text) != Self.key(value) }
            let cutoff = max(now, policy.forgotten[Self.key(value)]?.1 ?? 0)
            policy.forgotten[Self.key(value)] = (value, try latestLearnedTime(matching: { Self.key($0) == Self.key(value) }, since: cutoff))
        }
    }

    func block(text: String) throws {
        let value = try word(text)
        try mutate { policy, now in
            policy.manual = policy.manual.filter { !Self.isBlocked($0.value.text, by: [value]) }
            policy.blocked[Self.key(value)] = (value, now)
            policy.forgotten[Self.key(value)] = (value, max(now, policy.forgotten[Self.key(value)]?.1 ?? 0))
            for row in try lines("her_memory_learned.tsv") ?? [] {
                guard row.count == 5, row[0] == "L" else { throw MacWordMemoryError(message: "已学习词库格式异常。") }
                guard Self.isBlocked(row[2], by: [value]) else { continue }
                let time = max(now, try number(row[4]))
                policy.forgotten[Self.key(row[2])] = (row[2], max(time, policy.forgotten[Self.key(row[2])]?.1 ?? 0))
            }
        }
    }

    func unblock(text: String) throws {
        try mutate { policy, _ in policy.blocked.removeValue(forKey: Self.key(text)) }
    }

    func clearLearned() throws {
        try mutate { policy, now in
            policy.manual.removeAll()
            policy.forgotten.removeAll()
            policy.clearBefore = max(policy.clearBefore, try latestLearnedTime(matching: { _ in true }, since: now))
        }
    }

    func setLearningEnabled(_ enabled: Bool) throws { try mutate { policy, _ in policy.learning = enabled } }

    private func latestLearnedTime(matching: (String) -> Bool, since cutoff: Int) throws -> Int {
        var result = cutoff
        for row in try lines("her_memory_learned.tsv") ?? [] {
            guard row.count == 5, row[0] == "L" else { throw MacWordMemoryError(message: "已学习词库格式异常。") }
            guard matching(row[2]) else { continue }
            result = max(result, try number(row[4]))
        }
        return result
    }
}
