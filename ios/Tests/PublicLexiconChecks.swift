import Foundation

@main
private enum PublicLexiconChecks {
    private static var count = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }
        count += 1
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("her-public-lexicon-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try HerWordMemoryStore(directory: root)
        let ordinary = [
            HerLexiconEntry(text: "一家", pinyin: "yi jia", weight: 1_000),
            HerLexiconEntry(text: "衣架", pinyin: "yi jia", weight: 950),
            HerLexiconEntry(text: "图", pinyin: "tu", weight: 900),
            HerLexiconEntry(text: "悠悠", pinyin: "you you", weight: 700),
            HerLexiconEntry(text: "你", pinyin: "ni", weight: 1_000),
            HerLexiconEntry(text: "西", pinyin: "xi", weight: 1_000),
            HerLexiconEntry(text: "她", pinyin: "ta", weight: 1_000),
        ]
        let additions = [
            HerLexiconEntry(text: "宜家", pinyin: "yi jia", weight: 1_000_000,
                            category: "brand", aliases: ["ikea"], supplemental: true),
            HerLexiconEntry(text: "耐克", pinyin: "nai ke", weight: 1,
                            category: "brand", aliases: ["nike"], supplemental: true),
            HerLexiconEntry(text: "屠呦呦", pinyin: "tu you you", weight: 1,
                            category: "woman", supplemental: true),
            HerLexiconEntry(text: "西蒙娜·德·波伏瓦", pinyin: "xi meng na de bo fu wa", weight: 1,
                            category: "woman", supplemental: true),
            HerLexiconEntry(text: "自强不息", pinyin: "zi qiang bu xi", weight: 1,
                            category: "idiom", supplemental: true),
            HerLexiconEntry(text: "他山之石", pinyin: "ta shan zhi shi", weight: 1,
                            category: "idiom", supplemental: true),
        ]
        let base = try HerPinyinEngine(lexicon: ordinary)
        let engine = try HerPinyinEngine(lexicon: ordinary + additions, memory: memory)
        let existingPublic = try HerPinyinEngine(lexicon: ordinary + [
            HerLexiconEntry(text: "宜架", pinyin: "yi jia", weight: 900),
            HerLexiconEntry(text: "宜佳", pinyin: "yi jia", weight: 800),
            HerLexiconEntry(text: "宜家", pinyin: "yi jia", weight: 1, category: "brand", aliases: ["ikea"]),
        ])
        let existingSuggestions = existingPublic.candidates(for: "yijia")
        check(existingSuggestions.first?.text == "一家", "existing low-frequency public metadata preserves ordinary first")
        check(existingSuggestions.dropFirst().first?.text == "宜家", "existing low-frequency public word appears near front")
        for mode in HerWordingMode.allCases {
            let yijia = engine.candidates(for: "yijia", mode: mode)
            check(yijia.first?.text == "一家", "public contribution does not steal normal first place")
            check(yijia.dropFirst().first?.text == "宜家", "public full-pinyin candidate remains visible")
            check(engine.candidates(for: "tuyouyou", mode: mode).first?.text == base.candidates(for: "tuyouyou", mode: mode).first?.text,
                  "new person does not alter ordinary beam ranking")
            check(engine.candidates(for: "tuyouyou", mode: mode).contains { $0.text == "屠呦呦" }, "female person reachable")
            check(engine.candidates(for: "ziqiangbuxi", mode: mode).contains { $0.text == "自强不息" }, "idiom reachable")
            check(engine.candidates(for: "ikea", mode: mode).contains { $0.text == "宜家" && $0.annotation.contains("英文别名") },
                  "official English input stays an alias")
            check(engine.candidates(for: "NIKE", mode: mode).contains { $0.text == "耐克" }, "ASCII input accepts uppercase typing")
            check(engine.candidates(for: "ta", mode: mode).first?.text == "她", "public layer keeps feminine priority")
            check(engine.candidates(for: "ta", mode: mode).dropFirst().first?.text == "他", "public layer preserves immediately selectable male pronoun")
            check(engine.candidates(for: "tashanzhishi", mode: mode).contains { $0.text == "他山之石" }, "public idiom keeps original 他 spelling")
        }
        check(!engine.candidates(for: "t").contains { $0.text == "屠呦呦" }, "public words do not flood one-letter prefixes")
        let middle = engine.candidates(for: "ximengnadebofuwa").first { $0.text == "西蒙娜·德·波伏瓦" }
        check(middle?.consumedInputCount == "ximengnadebofuwa".count, "name middle dots do not consume fictitious syllables")
        let partial = engine.candidates(for: "tuyouyouni").first { $0.text == "屠呦呦" }
        check(partial?.consumedInputCount == "tuyouyou".count, "public name selection leaves trailing composition")
        try memory.block(text: "一家")
        let afterPrimaryBlock = engine.candidates(for: "yijia")
        check(afterPrimaryBlock.first?.text == "衣架", "next allowed normal homophone stays first after primary block")
        check(afterPrimaryBlock.dropFirst().first?.text == "宜家", "public follows next allowed normal homophone")
        try memory.unblock(text: "一家")
        try memory.block(text: "宜家")
        for mode in HerWordingMode.allCases {
            check(engine.candidates(for: "yijia", mode: mode).allSatisfy { $0.text != "宜家" }, "private block outranks public pinyin")
            check(engine.candidates(for: "ikea", mode: mode).allSatisfy { $0.text != "宜家" }, "private block outranks public English aliases")
        }
        try memory.block(text: "屠呦呦")
        check(!engine.candidates(for: "tuyouyouni").contains { $0.text.contains("屠呦呦") }, "private block covers public partial selection")
        try memory.unblock(text: "宜家")
        check(engine.candidates(for: "ikea").contains { $0.text == "宜家" }, "explicit restore allows public suggestions again")
        let oldJSON = Data("[{\"text\":\"你好\",\"pinyin\":\"ni hao\",\"weight\":20}]".utf8)
        let decoded = try JSONDecoder().decode([HerLexiconEntry].self, from: oldJSON)
        check(decoded[0].category == nil && decoded[0].aliases == nil && decoded[0].supplemental == nil,
              "old three-field resource shape remains compatible")
        let encoded = try JSONEncoder().encode(additions)
        let reopened = try JSONDecoder().decode([HerLexiconEntry].self, from: encoded)
        check(reopened[0].pinyin == "yi jia" && reopened[0].aliases == ["ikea"], "alias and true pronunciation survive Codable")

        let repository = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let resources = repository.appendingPathComponent("ios/Keyboard/Resources", isDirectory: true)
        let realLexiconData = try Data(contentsOf: resources.appendingPathComponent("lexicon.json"))
        let realRules = try Data(contentsOf: resources.appendingPathComponent("rules.json"))
        let publicRows = try JSONDecoder().decode([HerLexiconEntry].self, from: realLexiconData).filter { $0.category != nil }
        check(publicRows.count >= 200, "actual contributed catalog is present")
        let categories = Set(publicRows.compactMap(\.category))
        check(Set(["woman", "idiom", "brand"]).isSubset(of: categories)
              && categories.isSubset(of: Set(["woman", "idiom", "brand", "internet"])),
              "actual catalog retains the original categories and permits internet vocabulary")
        let realMemory = try HerWordMemoryStore(directory: root.appendingPathComponent("actual"))
        let realEngine = try HerPinyinEngine(lexiconData: realLexiconData, rulesData: realRules, memory: realMemory)
        for row in publicRows {
            let code = row.pinyin.replacingOccurrences(of: " ", with: "")
            let expected = realEngine.rewrite(row.text)
            check(realEngine.candidates(for: code, limit: 40).contains { $0.text == expected },
                  "actual public full-pinyin word reachable: " + row.text)
            for alias in row.aliases ?? [] {
                check(realEngine.candidates(for: alias, limit: 40).contains { $0.text == expected },
                      "actual English alias reachable: " + alias)
            }
        }
        print("Public lexicon: \(count) checks passed")
    }
}
