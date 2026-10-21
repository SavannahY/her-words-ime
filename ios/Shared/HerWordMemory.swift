import Foundation

/// A confirmed word and its input key. This is not a chat or sentence history.
public struct HerRememberedWord: Codable, Equatable, Sendable {
    public let text: String
    public let input: String
    public let count: Int
    public let lastUsed: Double

    public init(text: String, input: String, count: Int = 1,
                lastUsed: Double = Date().timeIntervalSince1970) {
        self.text = text
        self.input = input
        self.count = count
        self.lastUsed = lastUsed
    }
}

public enum HerWordMemoryError: Error, LocalizedError {
    case invalidWord
    case invalidInput
    case blockedWord
    case invalidFile
    case tooManyBlockedWords

    public var errorDescription: String? {
        switch self {
        case .invalidWord: return "请添加 1–64 字的单个词或短专名，不要加入网址、邮箱或整段文字。"
        case .invalidInput: return "输入码需为 1–128 个英文字母、数字或分词符号。"
        case .blockedWord: return "这个词已设为不再推荐，请先在不再推荐列表中恢复。"
        case .invalidFile: return "本地词库文件损坏或版本不受支持，已保留原文件，未覆盖。"
        case .tooManyBlockedWords: return "不再推荐列表已满，请先移除不需要的条目。"
        }
    }
}

/// Keep one store on the owning UI/inference queue. There is no shared App
/// Group, network service, host-document access, or automatic sentence capture.
/// Atomic writes preserve the prior file if persistence fails. A corrupt file
/// is surfaced to the caller and is never reset silently.
public final class HerWordMemoryStore {
    public static let maximumEntries = 2_000
    public static let maximumBlockedWords = 2_000
    public let directory: URL
    public let fileURL: URL

    private struct State: Codable, Equatable {
        var version = 1
        var learningEnabled = true
        var entries: [HerRememberedWord] = []
        var blockedWords: [String] = []
    }

    private var state: State

    public var entries: [HerRememberedWord] { Self.ranked(state.entries) }
    public var blockedWords: [String] { state.blockedWords.sorted() }
    public var learningEnabled: Bool { state.learningEnabled }

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw HerWordMemoryError.invalidFile }
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("word-memory.json", isDirectory: false)
        self.state = State()
        try refresh()
    }

    public func refresh() throws {
        state = try readState()
    }

    /// Only call after the user confirms a candidate or finishes an English
    /// word. Never feed the surrounding document or a transcript to this API.
    public func learn(text: String, input: String) throws {
        try update { value in
            guard value.learningEnabled else { return }
            let word = try Self.word(text)
            // Verification codes and other bare numbers are not words. An
            // explicit manual addition remains available if truly wanted.
            guard word.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return }
            let key = try Self.inputKey(input)
            guard !Self.isBlocked(word, words: value.blockedWords) else { return }
            Self.record(word, input: key, in: &value)
        }
    }

    /// An explicit user addition also works when automatic learning is off.
    public func remember(text: String, input: String) throws {
        try update { value in
            let word = try Self.word(text)
            let key = try Self.inputKey(input)
            guard !Self.isBlocked(word, words: value.blockedWords) else {
                throw HerWordMemoryError.blockedWord
            }
            Self.record(word, input: key, in: &value)
        }
    }

    /// Forget learned frequency/readings. The base dictionary can still offer
    /// the word, and a later explicit selection can learn it again. Use block
    /// when the user wants it removed from every generated candidate.
    public func forget(text: String) throws {
        let word = try Self.word(text)
        try update { value in
            value.entries.removeAll { Self.identity($0.text) == Self.identity(word) }
        }
    }

    /// A durable recommendation preference. It also removes remembered words
    /// that contain the blocked term and prevents them from being relearned.
    public func block(text: String) throws {
        let word = try Self.word(text)
        try update { value in
            if !value.blockedWords.contains(where: { Self.identity($0) == Self.identity(word) }) {
                guard value.blockedWords.count < Self.maximumBlockedWords else {
                    throw HerWordMemoryError.tooManyBlockedWords
                }
                value.blockedWords.append(word)
            }
            value.entries.removeAll { Self.isBlocked($0.text, words: value.blockedWords) }
        }
    }

    public func unblock(text: String) throws {
        let word = try Self.word(text)
        try update { value in
            value.blockedWords.removeAll { Self.identity($0) == Self.identity(word) }
        }
    }

    /// Clear the learned words without restoring unwanted recommendations.
    public func clearLearned() throws {
        try update { $0.entries.removeAll() }
    }

    public func setLearningEnabled(_ enabled: Bool) throws {
        try update { $0.learningEnabled = enabled }
    }

    public func suggestions(for input: String, limit: Int = 20) -> [HerRememberedWord] {
        guard limit > 0, let query = try? Self.inputKey(input), !query.isEmpty else { return [] }
        let prefix = Self.compactKey(query)
        return Self.ranked(state.entries.filter {
            Self.compactKey($0.input).hasPrefix(prefix) && !isBlocked($0.text)
        }).prefix(min(limit, Self.maximumEntries)).map { $0 }
    }

    public func isBlocked(_ text: String) -> Bool {
        Self.isBlocked(text, words: state.blockedWords)
    }

    private func readState() throws -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return State() }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1_024 * 1_024 else {
            throw HerWordMemoryError.invalidFile
        }
        let value: State
        do { value = try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL)) }
        catch { throw HerWordMemoryError.invalidFile }
        guard value.version == 1, value.entries.count <= Self.maximumEntries,
              value.blockedWords.count <= Self.maximumBlockedWords else {
            throw HerWordMemoryError.invalidFile
        }
        var identities = Set<String>()
        for entry in value.entries {
            guard (try? Self.word(entry.text)) == entry.text,
                  (try? Self.inputKey(entry.input)) == entry.input,
                  (1...1_000_000).contains(entry.count), entry.lastUsed.isFinite,
                  entry.lastUsed >= 0,
                  identities.insert(Self.identity(entry.text) + "\u{0}" + Self.compactKey(entry.input)).inserted else {
                throw HerWordMemoryError.invalidFile
            }
        }
        var blockedIdentities = Set<String>()
        for word in value.blockedWords {
            guard (try? Self.word(word)) == word,
                  blockedIdentities.insert(Self.identity(word)).inserted else {
                throw HerWordMemoryError.invalidFile
            }
        }
        guard !value.entries.contains(where: { Self.isBlocked($0.text, words: value.blockedWords) }) else {
            throw HerWordMemoryError.invalidFile
        }
        return value
    }

    private func update(_ mutation: (inout State) throws -> Void) throws {
        // Read before mutation so an externally damaged file cannot be silently
        // overwritten by a previously loaded instance.
        var value = try readState()
        let previous = value
        try mutation(&value)
        guard value != previous else { state = value; return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        state = value
    }

    private static func record(_ text: String, input: String, in value: inout State) {
        let identity = Self.identity(text)
        let key = compactKey(input)
        let index = value.entries.firstIndex { Self.identity($0.text) == identity && compactKey($0.input) == key }
        let count = index.map { min(1_000_000, value.entries[$0].count + 1) } ?? 1
        if let index = index { value.entries.remove(at: index) }
        value.entries.append(HerRememberedWord(text: text, input: input, count: count))
        if value.entries.count > maximumEntries {
            // Keep the newly confirmed word even when every older word has a
            // higher frequency. Capacity eviction follows last actual use.
            value.entries = Array(value.entries.sorted {
                if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.text != $1.text { return $0.text < $1.text }
                return $0.input < $1.input
            }.prefix(maximumEntries))
        }
    }

    private static func ranked(_ words: [HerRememberedWord]) -> [HerRememberedWord] {
        words.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            if $0.text != $1.text { return $0.text < $1.text }
            return $0.input < $1.input
        }
    }

    private static func word(_ source: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let disallowed = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\t\n\r<>[]{}\\/@=;!?。！？；，"))
        guard !value.isEmpty, value.count <= 64, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ !disallowed.contains($0) && (!$0.properties.isWhitespace || $0 == " ") }),
              !value.lowercased().contains("://"), !value.lowercased().hasPrefix("www."),
              !value.hasSuffix("."), value.split(separator: " ").count <= 4 else {
            throw HerWordMemoryError.invalidWord
        }
        return value
    }

    private static func inputKey(_ source: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ü", with: "v")
            .replacingOccurrences(of: "Ü", with: "v")
            .replacingOccurrences(of: "u:", with: "v")
            .replacingOccurrences(of: "U:", with: "v")
        let key = asciiLowercase(value)
        guard !key.isEmpty, key.utf8.count <= 128,
              key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [32, 39, 43, 45, 46, 58, 95].contains($0) }),
              key.utf8.contains(where: { (97...122).contains($0) || (48...57).contains($0) }),
              !compactKey(key).isEmpty else { throw HerWordMemoryError.invalidInput }
        return key
    }

    private static func compactKey(_ input: String) -> String {
        input.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
    }

    private static func identity(_ value: String) -> String { asciiLowercase(value) }

    private static func asciiLowercase(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? UnicodeScalar(scalar.value + 32)! : scalar
        }))
    }

    private static func isBlocked(_ text: String, words: [String]) -> Bool {
        let source = asciiLowercase(text)
        for term in words {
            let needle = asciiLowercase(term)
            let asciiWord = needle.unicodeScalars.allSatisfy { $0.value < 128 }
                && needle.utf8.contains { (97...122).contains($0) || (48...57).contains($0) }
            var searchStart = source.startIndex
            while let range = source.range(of: needle, range: searchStart..<source.endIndex) {
                if !asciiWord { return true }
                let before = range.lowerBound == source.startIndex ? nil : source[source.index(before: range.lowerBound)]
                let after = range.upperBound == source.endIndex ? nil : source[range.upperBound]
                if !isASCIIWordCharacter(before) && !isASCIIWordCharacter(after) { return true }
                searchStart = range.upperBound
                if searchStart == source.endIndex { break }
            }
        }
        return false
    }

    private static func isASCIIWordCharacter(_ character: Character?) -> Bool {
        guard let character = character, character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar.value == 95
    }
}
