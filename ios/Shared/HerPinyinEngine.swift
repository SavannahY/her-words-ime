import Foundation

/// Offline full-pinyin candidate engine. No UIKit, network, App Groups or
/// keyboard "full access" APIs are used by this module.
public final class HerPinyinEngine {
    private struct Reading {
        let bytes: [UInt8]
        let key: String
        let explicitBoundaries: Set<Int>
        let consumedCounts: [Int]
        let originalCount: Int

        func consumed(upTo end: Int) -> Int {
            end == bytes.count ? originalCount : consumedCounts[end]
        }

        static func parse(_ source: String) -> Reading? {
            let characters = Array(source)
            var bytes: [UInt8] = []
            var boundaries = Set<Int>()
            var consumed = [0]
            var index = 0
            while index < characters.count {
                let value = String(characters[index]).lowercased()
                if value == "'" || value == "’" || characters[index].isWhitespace {
                    if !bytes.isEmpty { boundaries.insert(bytes.count) }
                    index += 1
                    continue
                }
                let letter: UInt8
                var count = 1
                if value == "ü" {
                    letter = 118
                } else if value == "u", index + 1 < characters.count,
                          characters[index + 1] == ":" {
                    letter = 118
                    count = 2
                } else {
                    let encoded = Array(value.utf8)
                    guard encoded.count == 1, encoded[0] >= 97, encoded[0] <= 122 else { return nil }
                    letter = encoded[0]
                }
                bytes.append(letter)
                index += count
                consumed.append(index)
                guard bytes.count <= 128 else { return nil }
            }
            return Reading(bytes: bytes, key: String(bytes: bytes, encoding: .utf8)!,
                           explicitBoundaries: boundaries, consumedCounts: consumed,
                           originalCount: characters.count)
        }
    }

    /// Input consumption arrays are needed only for the current composition.
    /// Store dictionary syllable boundaries in two inline masks instead of
    /// keeping three heap collections for every one of the 47k+ readings.
    private struct Record {
        let text: String
        let key: String
        let lowerBoundaries: UInt64
        let upperBoundaries: UInt64
        let weight: Double
        var logWeight: Double { log1p(weight) }
        var length: Int { key.utf8.count }

        init(text: String, reading: Reading, weight: Double) {
            self.text = text
            self.key = reading.key
            self.weight = weight
            var lower: UInt64 = 0
            var upper: UInt64 = 0
            for boundary in reading.explicitBoundaries where boundary < reading.bytes.count {
                if boundary < 64 { lower |= UInt64(1) << boundary }
                else { upper |= UInt64(1) << (boundary - 64) }
            }
            self.lowerBoundaries = lower
            self.upperBoundaries = upper
        }

        func hasBoundary(_ position: Int) -> Bool {
            if position < 64 { return lowerBoundaries & (UInt64(1) << position) != 0 }
            guard position < 128 else { return false }
            return upperBoundaries & (UInt64(1) << (position - 64)) != 0
        }
    }

    private struct Draft {
        let text: String
        let end: Int
        let score: Double
        let completion: Bool
        let syllableCompletion: Bool

        init(text: String, end: Int, score: Double, completion: Bool,
             syllableCompletion: Bool = false) {
            self.text = text
            self.end = end
            self.score = score
            self.completion = completion
            self.syllableCompletion = syllableCompletion
        }
    }

    private struct BeamPath {
        let text: String
        let score: Double
        let words: Int
    }

    private struct WrappedLexicon: Decodable {
        let entries: [HerLexiconEntry]
    }

    private let records: [Record]
    private let publicRecords: [Record]
    private let publicAliases: [String: [String]]
    private let exactIndex: [String: [Int]]
    private let sortedKeys: [String]
    private let shortPrefixIndex: [String: [Int]]
    private let longestKey: Int
    private let normalization: Double
    private let rewriter: HerRewriter
    private let memory: HerWordMemoryStore?
    public let lexiconEntryCount: Int

    public convenience init(lexiconData: Data, rulesData: Data,
                            useTraditional: Bool = false,
                            memory: HerWordMemoryStore? = nil) throws {
        let decoder = JSONDecoder()
        let entries: [HerLexiconEntry]
        if let array = try? decoder.decode([HerLexiconEntry].self, from: lexiconData) {
            entries = array
        } else {
            entries = try decoder.decode(WrappedLexicon.self, from: lexiconData).entries
        }
        let rules = try decoder.decode(HerRuleSet.self, from: rulesData)
        try self.init(lexicon: entries, ruleSet: rules, useTraditional: useTraditional, memory: memory)
    }

    public init(lexicon: [HerLexiconEntry], ruleSet: HerRuleSet = HerRuleSet(),
                useTraditional: Bool = false, memory: HerWordMemoryStore? = nil) throws {
        guard !lexicon.isEmpty else { throw HerEngineError.emptyLexicon }
        var unique: [String: Record] = [:]
        var supplements: [String: Record] = [:]
        var publicAliases: [String: Set<String>] = [:]
        for (index, entry) in lexicon.enumerated() {
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.weight.isFinite, entry.weight >= 0,
                  let reading = Reading.parse(entry.pinyin), !reading.bytes.isEmpty else {
                throw HerEngineError.invalidLexiconEntry(index)
            }
            guard entry.category == nil || ["woman", "idiom", "brand"].contains(entry.category!),
                  entry.supplemental != true || entry.category != nil else {
                throw HerEngineError.invalidLexiconEntry(index)
            }
            if let aliases = entry.aliases {
                guard entry.category == "brand", aliases.count <= 8, Set(aliases).count == aliases.count,
                      aliases.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy { (97...122).contains($0) } }) else {
                    throw HerEngineError.invalidLexiconEntry(index)
                }
                for alias in aliases { publicAliases[alias, default: []].insert(entry.text) }
            }
            let record = Record(text: entry.text, reading: reading, weight: entry.weight)
            // Syllable boundaries distinguish xian from xi an.
            let identity = reading.key + "\u{0}" + String(record.lowerBoundaries) + ":" +
                String(record.upperBoundaries) + "\u{0}" + entry.text
            if entry.category != nil {
                if supplements[identity] == nil || supplements[identity]!.weight < entry.weight {
                    supplements[identity] = record
                }
            }
            if entry.supplemental == true {
                continue
            }
            if let existing = unique[identity], existing.weight >= entry.weight { continue }
            unique[identity] = record
        }
        let ordered = unique.values.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.text != $1.text { return $0.text < $1.text }
            if $0.key != $1.key { return $0.key < $1.key }
            if $0.lowerBoundaries != $1.lowerBoundaries { return $0.lowerBoundaries < $1.lowerBoundaries }
            return $0.upperBoundaries < $1.upperBoundaries
        }
        let addedPublicCount = supplements.keys.filter { unique[$0] == nil }.count
        let publicOrdered = supplements.values.sorted {
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.text < $1.text
        }
        // Release the temporary deduplication table before allocating indexes.
        unique.removeAll(keepingCapacity: false)
        var exact: [String: [Int]] = [:]
        var prefixes: [String: [Int]] = [:]
        for index in ordered.indices {
            let key = ordered[index].key
            exact[key, default: []].append(index)
            // Bounded top lists avoid scanning the dictionary on the first two
            // keypresses without allocating a large trie.
            for length in 1...min(2, key.utf8.count) {
                let prefix = String(key.prefix(length))
                if prefixes[prefix, default: []].count < 128 {
                    prefixes[prefix, default: []].append(index)
                }
            }
        }
        let totalWeight = ordered.reduce(0.0) { $0 + $1.weight }
        let logTotal = totalWeight.isFinite ? log1p(totalWeight)
            : (ordered.map(\.logWeight).max() ?? 0) + log(Double(ordered.count))
        self.records = ordered
        self.publicRecords = publicOrdered
        self.publicAliases = publicAliases.mapValues { $0.sorted() }
        self.exactIndex = exact
        self.sortedKeys = exact.keys.sorted()
        self.shortPrefixIndex = prefixes
        self.longestKey = ordered.reduce(1) { max($0, $1.length) }
        self.normalization = max(10, logTotal)
        self.rewriter = try HerRewriter(ruleSet: ruleSet, useTraditional: useTraditional)
        self.memory = memory
        self.lexiconEntryCount = ordered.count + addedPublicCount
    }

    public func rewrite(_ text: String, mode: HerWordingMode = .neutral) -> String {
        rewriter.rewrite(text, mode: mode).text
    }

    private func compatible(_ record: Record, start: Int, input: Reading) -> Bool {
        let end = start + record.length
        for boundary in input.explicitBoundaries where boundary > start && boundary < end {
            if !record.hasBoundary(boundary - start) { return false }
        }
        return true
    }

    private func lexicalMatches(_ input: Reading, start: Int) -> [(Int, Int)] {
        guard start < input.bytes.count else { return [] }
        var result: [(Int, Int)] = []
        for end in (start + 1)...min(input.bytes.count, start + longestKey) {
            let key = String(bytes: input.bytes[start..<end], encoding: .utf8)!
            if let indices = exactIndex[key] {
                for index in indices where compatible(records[index], start: start, input: input) {
                    result.append((end, index))
                }
            }
        }
        return result
    }

    private func completionMatches(_ input: Reading, maximum: Int) -> [Draft] {
        let indices: [Int]
        if input.bytes.count <= 2 {
            indices = shortPrefixIndex[input.key] ?? []
        } else {
            var low = 0
            var high = sortedKeys.count
            while low < high {
                let middle = (low + high) / 2
                if sortedKeys[middle] < input.key { low = middle + 1 } else { high = middle }
            }
            var matching: [Int] = []
            while low < sortedKeys.count, sortedKeys[low].hasPrefix(input.key) {
                matching.append(contentsOf: exactIndex[sortedKeys[low]] ?? [])
                low += 1
            }
            indices = matching
        }
        return indices.filter {
            records[$0].length > input.bytes.count && compatible(records[$0], start: 0, input: input)
        }.sorted {
            if records[$0].weight != records[$1].weight { return records[$0].weight > records[$1].weight }
            return records[$0].text < records[$1].text
        }.prefix(maximum).map {
            Draft(text: records[$0].text, end: input.bytes.count,
                  score: records[$0].logWeight, completion: true,
                  syllableCompletion: !records[$0].hasBoundary(input.bytes.count))
        }
    }

    private func prune(_ paths: [BeamPath], width: Int) -> [BeamPath] {
        let ordered = paths.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.words != $1.words { return $0.words < $1.words }
            return $0.text < $1.text
        }
        var seen = Set<String>()
        var result: [BeamPath] = []
        for path in ordered where seen.insert(path.text).inserted {
            result.append(path)
            if result.count == width { break }
        }
        return result
    }

    private func combinedMatches(_ input: Reading, width: Int) -> [Draft] {
        let length = input.bytes.count
        var paths = Array(repeating: [BeamPath](), count: length + 1)
        paths[0] = [BeamPath(text: "", score: 0, words: 0)]
        for start in 0..<length where !paths[start].isEmpty {
            paths[start] = prune(paths[start], width: width)
            var perEnd: [Int: Int] = [:]
            for (end, index) in lexicalMatches(input, start: start) {
                if perEnd[end, default: 0] >= 8 { continue }
                perEnd[end, default: 0] += 1
                let record = records[index]
                for path in paths[start] {
                    paths[end].append(BeamPath(text: path.text + record.text,
                                              score: path.score + record.logWeight - normalization,
                                              words: path.words + 1))
                }
                if paths[end].count > width * 3 { paths[end] = prune(paths[end], width: width) }
            }
        }
        return prune(paths[length], width: width).filter { $0.words > 1 }.map {
            Draft(text: $0.text, end: length, score: $0.score, completion: false)
        }
    }

    /// Selection commits candidate.text, removes consumedInputCount Characters,
    /// then may remove leading apostrophes/spaces from the remaining buffer.
    /// A candidate can translate the whole input, complete an unfinished word,
    /// or translate a prefix for selecting a sentence one segment at a time.
    public func candidates(for rawInput: String, mode: HerWordingMode = .neutral,
                           limit: Int = 9) -> [HerCandidate] {
        guard limit > 0, let input = Reading.parse(rawInput), !input.bytes.isEmpty else { return [] }
        let limit = min(limit, 128)
        let length = input.bytes.count
        let starting = lexicalMatches(input, start: 0)
        let exact = starting.filter { $0.0 == length }.map {
            Draft(text: records[$0.1].text, end: length,
                  score: records[$0.1].logWeight, completion: false)
        }
        let partial = starting.filter { $0.0 < length }.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            return records[$0.1].weight > records[$1.1].weight
        }.prefix(limit * 3).map {
            Draft(text: records[$0.1].text, end: $0.0,
                  score: records[$0.1].logWeight, completion: false)
        }
        let completions = completionMatches(input, maximum: max(40, limit * 2))
        // niha -> 你好 should precede an unlikely 你哈 composition.
        let strongCompletions = completions.filter(\.syllableCompletion)
        let combined = combinedMatches(input, width: min(80, max(16, limit * 2)))
        var result: [HerCandidate] = []
        var seen = Set<String>()
        @discardableResult func append(_ candidate: HerCandidate) -> Bool {
            guard result.count < limit else { return false }
            // Apply after every rewriting/composition path. Suppression also
            // covers base dictionary entries, partial selections and phrases.
            guard memory?.isBlocked(candidate.text) != true,
                  memory?.isBlocked(candidate.originalText) != true else { return false }
            let identity = String(candidate.consumedInputCount) + ":" + candidate.text
            guard seen.insert(identity).inserted else { return false }
            result.append(candidate)
            return true
        }
        @discardableResult func appendDraft(_ draft: Draft) -> Bool {
            let rewritten = rewriter.rewrite(draft.text, mode: mode)
            let annotation = rewritten.changedWording ? rewriter.annotation(mode: mode)
                : (draft.end < length ? "分段" : "")
            return append(HerCandidate(text: rewritten.text, originalText: draft.text,
                                consumedInputCount: input.consumed(upTo: draft.end),
                                annotation: annotation, isCompletion: draft.completion, score: draft.score))
        }
        if input.key == "ta" || input.key == "tamen" {
            let female = input.key == "ta" ? "她" : (rewriter.useTraditional ? "她們" : "她们")
            let male = input.key == "ta" ? "他" : (rewriter.useTraditional ? "他們" : "他们")
            append(HerCandidate(text: female, originalText: female,
                                consumedInputCount: input.originalCount, score: 1_000_000))
            // Keep the default feminine choice while making an explicit male
            // selection easy to find, independent of dictionary frequency.
            // append() still applies the user's private suppression list.
            append(HerCandidate(text: male, originalText: male,
                                consumedInputCount: input.originalCount, score: 999_999))
        }
        if let memory = memory {
            for word in memory.entries {
                guard let savedInput = Reading.parse(word.input), !savedInput.bytes.isEmpty else { continue }
                let completion = savedInput.key.hasPrefix(input.key)
                let partial = input.key.hasPrefix(savedInput.key)
                guard completion || partial else { continue }
                let end = min(input.bytes.count, savedInput.bytes.count)
                // Preserve explicit syllable distinctions such as xi'an/xian.
                guard input.explicitBoundaries.allSatisfy({ boundary in
                    boundary >= end || savedInput.explicitBoundaries.contains(boundary)
                }) else { continue }
                let rewritten = rewriter.rewrite(word.text, mode: mode)
                let note = rewritten.changedWording ? "本地词库 · " + rewriter.annotation(mode: mode) : "本地词库"
                append(HerCandidate(text: rewritten.text, originalText: word.text,
                                    consumedInputCount: input.consumed(upTo: end),
                                    annotation: note,
                                    isCompletion: savedInput.bytes.count > input.bytes.count,
                                    score: 100_000 + Double(word.count)))
            }
        }
        let primary = exact.first ?? strongCompletions.first ?? combined.first ??
            completions.first ?? partial.first
        let ordinaryPools = [Array(exact.prefix(4)), Array(strongCompletions.prefix(2)),
                             Array(combined.prefix(2)), Array(partial.prefix(2)),
                             exact, combined, completions, Array(partial)]
        let appendedPrimary = primary.map { appendDraft($0) } ?? false
        if !appendedPrimary {
            // A deleted/blocked first translation must not let a public word
            // jump above the next ordinary homophone that is still allowed.
            outer: for pool in ordinaryPools {
                for draft in pool where appendDraft(draft) { break outer }
            }
        }
        // Public contributions are supplemental suggestions. Do not feed them
        // into the ordinary beam or promote them above its existing first word.
        for record in publicRecords {
            let partial = input.key.hasPrefix(record.key)
            guard partial else { continue }
            let end = min(record.length, length)
            guard input.explicitBoundaries.allSatisfy({ $0 >= end || record.hasBoundary($0) }) else { continue }
            let rewritten = rewriter.rewrite(record.text, mode: mode)
            append(HerCandidate(text: rewritten.text, originalText: record.text,
                                consumedInputCount: input.consumed(upTo: end), annotation: "公共词库",
                                isCompletion: false, score: record.logWeight))
        }
        for original in publicAliases[input.key] ?? [] {
            let rewritten = rewriter.rewrite(original, mode: mode)
            append(HerCandidate(text: rewritten.text, originalText: original,
                                consumedInputCount: input.originalCount, annotation: "公共词库 · 英文别名"))
        }
        // Preserve the first ordinary translation before offering friendly
        // aliases; then deduplicate rewrites by their output and input coverage.
        if mode != .original {
            for alias in rewriter.aliases[input.key] ?? [] {
                let text = rewriter.aliasOutput(alias, mode: mode)
                let note = mode == .community ? alias.communityNote ?? alias.friendlyNote : alias.friendlyNote
                append(HerCandidate(text: text, originalText: text,
                                    consumedInputCount: input.originalCount,
                                    annotation: rewriter.annotation(mode: mode, note: note)))
            }
        }
        // Reserve early places for whole-word alternatives and segment choices,
        // then fill the scrollable list with the remaining translations.
        for pool in ordinaryPools {
            for draft in pool { appendDraft(draft) }
        }
        return result
    }
}
