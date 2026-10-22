import Foundation

/// Standalone persistence and candidate tests; never open real user storage.
@main
struct WordMemoryChecks {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }
        checks += 1
    }

    private static func expectError(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: " + message) }
        catch { checks += 1 }
    }

    private static func fixture(memory: HerWordMemoryStore?) throws -> HerPinyinEngine {
        try HerPinyinEngine(lexicon: [
            HerLexiconEntry(text: "张三", pinyin: "zhang san", weight: 1_000),
            HerLexiconEntry(text: "张三", pinyin: "zs", weight: 1_000),
            HerLexiconEntry(text: "张山", pinyin: "zhang san", weight: 900),
            HerLexiconEntry(text: "张三你好", pinyin: "zhang san ni hao", weight: 1_000),
            HerLexiconEntry(text: "你好", pinyin: "ni hao", weight: 900),
            HerLexiconEntry(text: "张", pinyin: "zhang", weight: 1_000),
            HerLexiconEntry(text: "三", pinyin: "san", weight: 1_000),
            HerLexiconEntry(text: "她", pinyin: "ta", weight: 1_000),
            HerLexiconEntry(text: "塔", pinyin: "ta", weight: 900),
            HerLexiconEntry(text: "贱人", pinyin: "jian ren", weight: 1_000),
            HerLexiconEntry(text: "Ann", pinyin: "ann", weight: 100),
            HerLexiconEntry(text: "planning", pinyin: "planning", weight: 100),
        ], ruleSet: HerRuleSet(rules: [HerRewriteRule(from: "贱人", to: "失礼的人")]), memory: memory)
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("her-word-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HerWordMemoryStore(directory: root.appendingPathComponent("normal"))
        check(store.entries.isEmpty && store.blockedWords.isEmpty, "new store is empty")
        check(store.learningEnabled, "automatic learning initially enabled")
        check(!FileManager.default.fileExists(atPath: store.fileURL.path), "opening storage does not create history")

        try store.learn(text: "张三", input: "zhang san")
        check(store.entries.first?.text == "张三", "confirmed name learned")
        check(store.suggestions(for: "zhangsan").first?.text == "张三", "pinyin separators ignored in lookup")
        check(store.suggestions(for: "zha").first?.text == "张三", "learned name completes typed prefix")
        try store.learn(text: "张三", input: "ZHANG'SAN")
        check(store.entries.count == 1 && store.entries[0].count == 2, "same reading increments without duplicate")
        check(store.suggestions(for: "zhangsanx").isEmpty, "longer unrelated input is not an English completion")
        try store.learn(text: "GitHub", input: "GitHub")
        check(store.suggestions(for: "GIT").first?.text == "GitHub", "English mixed-case preserved and matched")
        try store.remember(text: "C++", input: "c++")
        check(store.suggestions(for: "c+").first?.text == "C++", "technical punctuation accepted in word and key")
        try store.remember(text: "Node.js", input: "node.js")
        check(store.suggestions(for: "node.").first?.text == "Node.js", "technical dotted name accepted")
        try store.remember(text: "吕青", input: "lü qing")
        check(store.suggestions(for: "lvq").first?.text == "吕青", "umlaut pinyin normalization")
        try store.learn(text: "123456", input: "123456")
        check(!store.entries.contains { $0.text == "123456" }, "bare numeric codes not automatically remembered")
        let reopened = try HerWordMemoryStore(directory: store.directory)
        check(reopened.entries == store.entries, "words and usage survive reopening")
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        check((mode?.intValue ?? 0) & 0o777 == 0o600, "word file is owner-readable only")

        try store.setLearningEnabled(false)
        try store.learn(text: "不保存", input: "bubaocun")
        check(!store.entries.contains { $0.text == "不保存" }, "pause stops learning")
        try store.remember(text: "Ada Lovelace", input: "ada")
        check(store.suggestions(for: "ad").first?.text == "Ada Lovelace", "manual word works with learning paused")
        let pausedReload = try HerWordMemoryStore(directory: store.directory)
        check(pausedReload.learningEnabled == false, "pause preference persisted")
        try store.setLearningEnabled(true)

        for invalid in ["https://example.com", "name@example.com", "a\nb", "Hi!", "A sentence. ", String(repeating: "名", count: 65)] {
            expectError("reject non-word text") { try store.remember(text: invalid, input: "test") }
        }
        for invalid in ["", "zhang\nsan", "🙃", "' + '", String(repeating: "a", count: 129)] {
            expectError("reject invalid input key") { try store.remember(text: "名字", input: invalid) }
        }

        let engine = try fixture(memory: store)
        let baseline = try fixture(memory: nil)
        check(baseline.candidates(for: "zhangsan").first?.text == "张三", "base dictionary starts with former name")
        try store.remember(text: "章杉", input: "zhang san")
        for _ in 0..<3 { try store.learn(text: "章杉", input: "zhang san") }
        check(engine.candidates(for: "zhangsan").first?.text == "章杉", "confirmed frequent name is promoted")
        let prefix = engine.candidates(for: "zhangsannihao", limit: 30).first
        check(prefix?.text == "章杉" && prefix?.consumedInputCount == 8, "remembered prefix preserves remaining composition")
        try store.forget(text: "章杉")
        check(!engine.candidates(for: "zhangsan", limit: 30).contains { $0.text == "章杉" }, "forget removes personal candidate immediately")
        try store.forget(text: "张三")
        check(store.suggestions(for: "zhangsan").isEmpty, "forget deletes remembered readings")
        check(engine.candidates(for: "zhangsan").first?.text == "张三", "forget alone does not hide base dictionary")
        try store.learn(text: "张三", input: "zhangsan")
        check(store.suggestions(for: "zha").first?.text == "张三", "a later confirmed selection can relearn forgotten word")

        try store.block(text: "张三")
        check(store.entries.allSatisfy { $0.text != "张三" }, "blocking deletes matching memory")
        check(store.isBlocked("和张三一起") && store.isBlocked("张三"), "Chinese block includes containing phrases")
        check(!store.isBlocked("张山"), "unrelated homophone remains allowed")
        check(engine.candidates(for: "zhangsan", limit: 30).allSatisfy { !$0.text.contains("张三") }, "base candidate suppressed")
        check(engine.candidates(for: "zs", limit: 30).allSatisfy { !$0.text.contains("张三") }, "abbreviation also suppressed")
        check(engine.candidates(for: "zhangsannihao", limit: 30).allSatisfy { !$0.text.contains("张三") }, "whole phrase and generated combinations suppressed")
        check(engine.candidates(for: "zhangsan", mode: .original, limit: 30).allSatisfy { !$0.text.contains("张三") }, "original wording cannot bypass block")
        try store.learn(text: "张三", input: "zhangsan")
        check(store.suggestions(for: "zha").isEmpty, "blocked word cannot be relearned")
        expectError("explicit addition cannot silently restore a blocked name") { try store.remember(text: "张三", input: "zs") }
        let blockedReload = try HerWordMemoryStore(directory: store.directory)
        check(blockedReload.isBlocked("张三"), "block survives reopening")
        try store.unblock(text: "张三")
        check(!store.isBlocked("张三") && store.suggestions(for: "zha").isEmpty, "restore does not resurrect learned history")
        check(engine.candidates(for: "zs").contains { $0.text == "张三" }, "restoring allows base dictionary again")

        try store.remember(text: "Ann Smith", input: "annsmith")
        try store.remember(text: "planning", input: "planning")
        try store.block(text: "ANN")
        check(store.isBlocked("Ann") && store.isBlocked("hello ann!") && store.isBlocked("给Ann写信"), "English block ignores ASCII case")
        check(!store.isBlocked("planning") && !store.isBlocked("Annabelle") && !store.isBlocked("annual"), "English block respects word boundaries")
        check(!store.entries.contains { $0.text == "Ann Smith" }, "blocking term deletes compound personal name")
        check(store.entries.contains { $0.text == "planning" }, "boundary keeps unrelated remembered English")
        check(engine.candidates(for: "ann").allSatisfy { $0.text != "Ann" }, "English dictionary candidate suppressed")
        check(engine.candidates(for: "planning").contains { $0.text == "planning" }, "English substring not oversuppressed")

        try store.remember(text: "贱人", input: "jian ren")
        check(engine.candidates(for: "jianren").first?.text == "失礼的人", "memory cannot bypass friendly rewrite")
        try store.remember(text: "他他", input: "tata")
        try store.remember(text: "其他人", input: "qi ta ren")
        for mode in HerWordingMode.allCases {
            check(engine.candidates(for: "tata", mode: mode).first?.text == "他他", "personal male spelling remains unchanged")
            check(engine.candidates(for: "qitaren", mode: mode).first?.text == "其他人", "personal word containing 他 is not rewritten")
            check(Array(engine.candidates(for: "ta", mode: mode).prefix(2)).map(\.text) == ["她", "他"], "both singular pronouns stay easy to select with memory")
            check(Array(engine.candidates(for: "tamen", mode: mode).prefix(2)).map(\.text) == ["她们", "他们"], "both plural pronouns stay easy to select with memory")
        }
        check(engine.candidates(for: "ta").first?.text == "她", "pronoun priority survives learned alternatives")
        try store.block(text: "他他")
        check(engine.candidates(for: "tata", limit: 30).allSatisfy { $0.originalText != "他他" }, "personal male word still respects blocking")
        try store.block(text: "他")
        check(engine.candidates(for: "ta").allSatisfy { $0.text != "他" }, "explicit male pronoun respects private block")
        check(engine.candidates(for: "ta").first?.text == "她", "private male block keeps female default")
        try store.unblock(text: "他")
        check(engine.candidates(for: "ta").dropFirst().first?.text == "他", "explicit restore makes male pronoun second again")
        try store.block(text: "她")
        check(engine.candidates(for: "ta").first?.text == "他", "private female block outranks default priority")
        try store.unblock(text: "她")
        try store.clearLearned()
        check(store.entries.isEmpty && store.isBlocked("ANN"), "clear learned words keeps suppression preference")

        let corruptDirectory = root.appendingPathComponent("corrupt")
        let beforeCorruption = try HerWordMemoryStore(directory: corruptDirectory)
        try beforeCorruption.remember(text: "保留", input: "baoliu")
        let corruptBytes = Data("not json\n".utf8)
        try corruptBytes.write(to: beforeCorruption.fileURL)
        expectError("corrupt file reported on open") { _ = try HerWordMemoryStore(directory: corruptDirectory) }
        expectError("existing instance cannot overwrite corruption") { try beforeCorruption.remember(text: "新词", input: "xinci") }
        let afterCorruption = try Data(contentsOf: beforeCorruption.fileURL)
        check(afterCorruption == corruptBytes, "corrupt bytes preserved for recovery")

        let invalidDirectory = root.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let invalidURL = invalidDirectory.appendingPathComponent("word-memory.json")
        for invalidState: [String: Any] in [
            ["version": 2, "learningEnabled": true, "entries": [], "blockedWords": []],
            ["version": 1, "learningEnabled": true, "entries": [["text": "名字", "input": "mingzi", "count": 0, "lastUsed": 0]], "blockedWords": []],
            ["version": 1, "learningEnabled": true, "entries": [], "blockedWords": Array(repeating: "重复", count: 2)],
            ["version": 1, "learningEnabled": true, "entries": [], "blockedWords": Array(repeating: "超限", count: 2_001)],
        ] {
            let bytes = try JSONSerialization.data(withJSONObject: invalidState)
            try bytes.write(to: invalidURL)
            expectError("invalid persisted state rejected") { _ = try HerWordMemoryStore(directory: invalidDirectory) }
            let afterInvalid = try Data(contentsOf: invalidURL)
            check(afterInvalid == bytes, "invalid persisted state not reset")
        }

        let capacityDirectory = root.appendingPathComponent("capacity")
        try FileManager.default.createDirectory(at: capacityDirectory, withIntermediateDirectories: true)
        let capacityURL = capacityDirectory.appendingPathComponent("word-memory.json")
        let fullEntries = (0..<HerWordMemoryStore.maximumEntries).map { index -> [String: Any] in
            ["text": "Word\(index)", "input": "word\(index)", "count": 100, "lastUsed": Double(index)]
        }
        let fullState: [String: Any] = ["version": 1, "learningEnabled": true, "entries": fullEntries, "blockedWords": []]
        try JSONSerialization.data(withJSONObject: fullState).write(to: capacityURL)
        let capacityStore = try HerWordMemoryStore(directory: capacityDirectory)
        try capacityStore.learn(text: "Newest", input: "newest")
        check(capacityStore.entries.count == HerWordMemoryStore.maximumEntries, "capacity bounded after learning")
        check(capacityStore.entries.contains { $0.text == "Newest" }, "new low-frequency word is not immediately evicted")
        check(!capacityStore.entries.contains { $0.text == "Word0" }, "least recently used word evicted at capacity")
        let capacityReload = try HerWordMemoryStore(directory: capacityDirectory)
        check(capacityReload.entries == capacityStore.entries, "capacity update remains valid durable state")
        print("Word memory: \(checks) checks passed")
    }
}
