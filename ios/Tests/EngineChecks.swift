import Foundation

/// Compile with ios/Shared/*.swift and run from the repository root.
/// Uses real offline resources as well as focused fixtures; no UIKit/Xcode.
@main
struct EngineChecks {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }
        checks += 1
    }

    private static func fixture(badFirst: Bool = false, traditional: Bool = false) throws -> HerPinyinEngine {
        let values: [(String, String, Double)] = [
            ("你", "ni", 1000), ("好", "hao", 900), ("哈", "ha", 100),
            ("你好", "ni hao", 500), ("吗", "ma", 700),
            ("我", "wo", 1200), ("喜欢", "xi huan", 600),
            ("他", "ta", 500), ("她", "ta", 400), ("塔", "ta", 1000),
            ("他们", "ta men", 200), ("她们", "ta men", 100), ("塔门", "ta men", 600),
            ("其他", "qi ta", 700), ("吉他", "ji ta", 700), ("他人", "ta ren", 700),
            ("他山之石", "ta shan zhi shi", 700),
            ("极度", "ji du", 1000), ("嫉妒", "ji du", 900),
            ("坚韧", "jian ren", 800), ("贱人", "jian ren", badFirst ? 1000 : 700),
            ("圣女", "sheng nv", 500), ("剩女", "sheng nv", 400),
            ("先", "xian", 1000), ("西安", "xi an", 500),
            ("西", "xi", 900), ("安", "an", 600),
            ("女", "nv", 500), ("律", "lv", 500),
        ]
        let rules = HerRuleSet(rules: [
            HerRewriteRule(from: "嫉妒", to: "忮忌"),
            HerRewriteRule(from: "贱人", to: "失礼的人", toTraditional: "失禮的人",
                           community: "失礼者", communityTraditional: "失禮者"),
            HerRewriteRule(from: "剩女", to: "单身女性"),
            HerRewriteRule(from: "坏女", to: "不友善"),
            HerRewriteRule(from: "坏女人", to: "坏人"),
            HerRewriteRule(from: "坏人", to: "友善人"),
            HerRewriteRule(from: "女神", to: "榜样", match: "exact"),
            HerRewriteRule(from: "a+b%[x]", to: "100%好"),
        ], exactAliases: [
            HerExactAlias(input: "jidu", friendly: "忮忌", friendlyNote: "zhì jì · 近义改写"),
            HerExactAlias(input: "jianren", friendly: "失礼的人", friendlyTraditional: "失禮的人",
                          community: "失礼者", communityTraditional: "失禮者",
                          communityNote: "借字"),
            HerExactAlias(input: "shengnv", friendly: "单身女性"),
            HerExactAlias(input: "ta", friendly: "她"),
            HerExactAlias(input: "taren", friendly: "他人"),
        ])
        return try HerPinyinEngine(
            lexicon: values.map { HerLexiconEntry(text: $0.0, pinyin: $0.1, weight: $0.2) },
            ruleSet: rules, useTraditional: traditional)
    }

    static func main() throws {
        let engine = try fixture()
        check(engine.candidates(for: "ta").first?.text == "她", "default feminine ta priority")
        check(engine.candidates(for: "ta", mode: .original).first?.text == "她", "priority in original mode")
        check(engine.candidates(for: "tamen").first?.text == "她们", "default feminine tamen priority")
        let ta = engine.candidates(for: "ta", limit: 40)
        check(ta.filter { $0.text == "她" && $0.consumedInputCount == 2 }.count == 1, "pronoun deduplication")
        for mode in HerWordingMode.allCases {
            let singular = engine.candidates(for: "ta", mode: mode, limit: 40)
            let plural = engine.candidates(for: "tamen", mode: mode, limit: 40)
            check(Array(singular.prefix(2)).map(\.text) == ["她", "他"], "female default with male ta immediately available")
            check(Array(plural.prefix(2)).map(\.text) == ["她们", "他们"], "female default with male plural immediately available")
            check(singular.first { $0.text == "他" }?.originalText == "他", "male selection commits unchanged")
            check(plural.first { $0.text == "他们" }?.originalText == "他们", "male plural selection commits unchanged")
            for (input, expected) in [("qita", "其他"), ("jita", "吉他"), ("taren", "他人"), ("tashanzhishi", "他山之石")] {
                let values = engine.candidates(for: input, mode: mode, limit: 40)
                check(values.contains { $0.text == expected && $0.originalText == expected }, "ordinary word retains 他: " + expected)
            }
            check(!engine.candidates(for: "taren", mode: mode, limit: 40).contains { $0.text == "她人" }, "wording aliases do not force feminine spelling")
            check(engine.rewrite("他和他们拿着吉他帮助其他人", mode: mode) == "他和他们拿着吉他帮助其他人", "ordinary male text remains unchanged in every keyboard mode")
        }
        let jidu = engine.candidates(for: "jidu", limit: 40)
        check(jidu.first?.text == "极度", "benign full-word homophone retains first place")
        check(jidu.dropFirst().first?.text == "忮忌", "alias follows first ordinary candidate")
        check(jidu.filter { $0.text == "忮忌" && $0.consumedInputCount == 4 }.count == 1, "alias/rewrite deduplication")
        check(jidu.dropFirst().first?.annotation.contains("zhì jì") == true, "unusual term pronunciation note")
        check(engine.candidates(for: "shengnv").first?.text == "圣女", "normal shengnv preserved")
        check(engine.candidates(for: "jianren").first?.text == "坚韧", "normal jianren preserved")
        let badFirst = try fixture(badFirst: true)
        check(badFirst.candidates(for: "jianren").first?.text == "失礼的人", "bad first rewritten in place")
        check(badFirst.candidates(for: "jianren").first?.originalText == "贱人", "source wording retained in model")
        check(badFirst.candidates(for: "jianren", mode: .community).first?.text == "失礼者", "community opt-in")
        check(badFirst.candidates(for: "jianren", mode: .original).first?.text == "贱人", "original mode retains source")
        check(engine.candidates(for: "jidu", mode: .original).contains { $0.text == "嫉妒" }, "original mode disables aliases")
        check(engine.rewrite("他是坏女人") == "他是坏人", "longest wording match preserves selected pronoun")
        check(engine.rewrite("坏女人") == "坏人", "replacement is never rescanned")
        check(engine.rewrite("坏人") == "友善人", "independent source rule still works")
        check(engine.rewrite("女神") == "榜样", "exact candidate rule")
        check(engine.rewrite("女神像") == "女神像", "exact rule cannot alter a substring")
        check(engine.rewrite("a+b%[x]a+b%[x]") == "100%好100%好", "literal pattern metacharacters")
        check(engine.rewrite("🙂坏女人和坏人") == "🙂坏人和友善人", "UTF-8 source boundaries")
        check(engine.rewrite("好妈妈和姐姐的婚姻") == "好妈妈和姐姐的婚姻", "unlisted feminine vocabulary preserved")
        check(engine.rewrite("他的坏女人", mode: .original) == "他的坏女人", "original mode retains selected male spelling")
        let traditional = try fixture(badFirst: true, traditional: true)
        check(traditional.candidates(for: "tamen").first?.text == "她們", "traditional pronoun option")
        for mode in HerWordingMode.allCases {
            check(Array(traditional.candidates(for: "ta", mode: mode).prefix(2)).map(\.text) == ["她", "他"], "traditional singular includes male immediately")
            check(Array(traditional.candidates(for: "tamen", mode: mode).prefix(2)).map(\.text) == ["她們", "他們"], "traditional plural includes male immediately")
        }
        check(traditional.rewrite("贱人") == "失禮的人", "declared traditional rule output")
        check(traditional.rewrite("贱人", mode: .community) == "失禮者", "declared traditional community output")

        let completion = engine.candidates(for: "niha").first
        check(completion?.text == "你好" && completion?.isCompletion == true, "unfinished syllable completion")
        check(completion?.consumedInputCount == 4, "completion consumes typed characters only")
        check(engine.candidates(for: "nihao").first?.text == "你好", "whole words precede composition")
        check(engine.candidates(for: "woxihuanni").first?.text == "我喜欢你", "multiword full-pinyin combination")
        let sentence = engine.candidates(for: "nihaoma", limit: 40)
        check(sentence.contains { $0.text == "你好吗" && $0.consumedInputCount == 7 }, "sentence candidates cover full input")
        let segment = sentence.first { $0.text == "你好" && $0.consumedInputCount == 5 }
        check(segment != nil, "multi-syllable prefix remains available for selection")
        let remaining = String("nihaoma".dropFirst(segment!.consumedInputCount))
        check(engine.candidates(for: remaining).first?.text == "吗", "sequential segment selection")
        check(sentence.contains { $0.text == "你" && $0.consumedInputCount == 2 }, "short segment selection")
        check(engine.candidates(for: "xian").first?.text == "先", "unmarked whole-syllable reading")
        let separated = engine.candidates(for: "xi'an", limit: 40)
        check(separated.first?.text == "西安", "apostrophe syllable disambiguation")
        check(!separated.contains { $0.text == "先" && $0.consumedInputCount == 5 }, "apostrophe cannot be silently discarded")
        check(separated.first?.consumedInputCount == 5, "consumption includes interior separator")
        check(engine.candidates(for: "NÜ").first?.text == "女", "uppercase and umlaut normalization")
        check(engine.candidates(for: "nu:").first?.text == "女", "u-colon normalization")
        check(engine.candidates(for: "nu:").first?.consumedInputCount == 3, "u-colon original character count")
        check(engine.candidates(for: "lv").first?.text == "律", "v reading")
        check(engine.candidates(for: "").isEmpty, "empty input")
        check(engine.candidates(for: "'''").isEmpty, "separator-only input")
        check(engine.candidates(for: "ni1").isEmpty, "invalid input does not silently lose characters")
        check(engine.candidates(for: "ni", limit: 0).isEmpty, "zero candidate limit")
        check(engine.candidates(for: String(repeating: "a", count: 129)).isEmpty, "bounded input work")
        check(engine.candidates(for: "ni", limit: 1).count == 1, "candidate limit respected")

        let emptyAlias = try HerPinyinEngine(
            lexicon: [HerLexiconEntry(text: "好", pinyin: "hao", weight: 1)],
            ruleSet: HerRuleSet(exactAliases: [HerExactAlias(input: "jidu", friendly: "忮忌")]))
        check(emptyAlias.candidates(for: "jidu").first?.text == "忮忌", "alias fallback for absent lexical translation")
        let duplicates = try HerPinyinEngine(lexicon: [
            HerLexiconEntry(text: "你", pinyin: "ni", weight: 1),
            HerLexiconEntry(text: "你", pinyin: "ni", weight: 10),
        ])
        check(duplicates.lexiconEntryCount == 1, "duplicate lexicon entry keeps highest frequency")
        let seventy = String(repeating: "a", count: 70)
        let longBoundaries = try HerPinyinEngine(lexicon: [
            HerLexiconEntry(text: "分音长词", pinyin: Array(repeating: "a", count: 70).joined(separator: " "), weight: 1),
            HerLexiconEntry(text: "不分音", pinyin: seventy, weight: 10),
        ])
        for boundary in [63, 64, 65] {
            let separated = String(seventy.prefix(boundary)) + "'" + String(seventy.dropFirst(boundary))
            check(longBoundaries.candidates(for: separated).first?.text == "分音长词",
                  "inline boundary masks cross UInt64 bit \(boundary)")
        }
        do {
            _ = try HerPinyinEngine(lexicon: [])
            fatalError("FAIL: empty lexicon accepted")
        } catch HerEngineError.emptyLexicon { checks += 1 }
        do {
            _ = try HerPinyinEngine(lexicon: [HerLexiconEntry(text: "坏", pinyin: "huai1", weight: 1)])
            fatalError("FAIL: invalid pinyin resource accepted")
        } catch HerEngineError.invalidLexiconEntry { checks += 1 }
        do {
            _ = try HerPinyinEngine(lexicon: [HerLexiconEntry(text: "你", pinyin: "ni", weight: 1)],
                                   ruleSet: HerRuleSet(rules: [HerRewriteRule(from: "女", to: "人")]))
            fatalError("FAIL: blanket radical rule accepted")
        } catch HerEngineError.invalidRule { checks += 1 }

        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ??
                       FileManager.default.currentDirectoryPath, isDirectory: true)
        let resources = root.appendingPathComponent("ios/Keyboard/Resources", isDirectory: true)
        let started = Date()
        let production = try HerPinyinEngine(
            lexiconData: Data(contentsOf: resources.appendingPathComponent("lexicon.json")),
            rulesData: Data(contentsOf: resources.appendingPathComponent("rules.json")))
        let loadTime = Date().timeIntervalSince(started)
        check(production.lexiconEntryCount >= 40_000, "real offline vocabulary rather than a small demo")
        check(production.candidates(for: "nihao").first?.text == "你好", "real-frequency nihao")
        check(production.candidates(for: "zhongguo").first?.text == "中国", "real-frequency zhongguo")
        check(production.candidates(for: "jidu").first?.text == "季度", "real ordinary homophone")
        check(production.candidates(for: "jianren").first?.text == "失礼的人", "real offensive first candidate rewritten")
        let originalShengnv = production.candidates(for: "shengnv", mode: .original).first
        check(originalShengnv != nil &&
              production.candidates(for: "shengnv").first?.text ==
                production.rewrite(originalShengnv!.originalText),
              "real shengnv retains the lexicon or segmentation baseline")
        check(production.candidates(for: "ta").first?.text == "她", "real pronoun priority")
        check(production.candidates(for: "tamen").first?.text == "她们", "real plural priority")
        for mode in HerWordingMode.allCases {
            check(Array(production.candidates(for: "ta", mode: mode).prefix(2)).map(\.text) == ["她", "他"], "real male ta is second in every mode")
            check(Array(production.candidates(for: "tamen", mode: mode).prefix(2)).map(\.text) == ["她们", "他们"], "real male plural is second in every mode")
            for (input, expected) in [("qita", "其他"), ("jita", "吉他"), ("taren", "他人")] {
                check(production.candidates(for: input, mode: mode, limit: 40).contains { $0.text == expected }, "real normal male-containing word preserved: " + expected)
            }
        }
        let forty = production.candidates(for: "shi", limit: 40)
        check(forty.count == 40, "scrollable forty-candidate vocabulary")
        check(production.candidates(for: "woxihuanni", limit: 40).contains { $0.text == "我喜欢你" },
              "real lexicon sentence combination")
        for (directory, mode) in [("neutral-zh-CN", HerWordingMode.neutral),
                                   ("community-zh-CN", HerWordingMode.community)] {
            let packURL = root.appendingPathComponent("packs/\(directory)/pack.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: packURL)) as! [String: Any]
            for entry in object["entries"] as! [[String: Any]] {
                for example in entry["tests"] as! [[String: String]] {
                    let source = example["input"]!
                    let expected = example["expected"]!
                    check(production.rewrite(source, mode: mode) == expected,
                          "shared \(directory) example: \(source)")
                }
            }
        }
        let queryStart = Date()
        for query in ["n", "ni", "niha", "nihao", "woxihuanni", "zhongguorenmin", "jianren", "xi'an"] {
            _ = production.candidates(for: query, limit: 40)
        }
        let queryTime = Date().timeIntervalSince(queryStart)
        print("PASS \(checks) Swift engine checks; \(production.lexiconEntryCount) entries; load \(String(format: "%.3f", loadTime))s; eight queries \(String(format: "%.3f", queryTime))s")
    }
}
