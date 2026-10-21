import Foundation

/// Compile with ios/Shared/*.swift; no UIKit or microphone is required.
@main
struct SpeechTextChecks {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }
        checks += 1
    }

    static func main() throws {
        let examples: [(String, String)] = [
            ("", ""),
            ("他它她他们它们牠祂", "她她她她们她们牠祂"),
            ("He told him it works. he/him/it IT", "He told him it works. he/him/it IT"),
            ("他在GitHub用SwiftUI写API，it works on iPhone和Mac。",
             "她在GitHub用SwiftUI写API，it works on iPhone和Mac。"),
            ("她用Xcode，Python、JavaScript和TypeScript。", "她用Xcode，Python、JavaScript和TypeScript。"),
            ("他贴了 https://他.example/它?q=他#它 。它很好",
             "她贴了 https://他.example/它?q=他#它 。她很好"),
            ("他看 https://example.com/它。它在这里", "她看 https://example.com/它。她在这里"),
            ("它在 www.例子.公司/他", "她在 www.例子.公司/他"),
            ("它给 他@例子.公司 和 User+It@EXAMPLE.com 发信",
             "她给 他@例子.公司 和 User+It@EXAMPLE.com 发信"),
            ("它看 `他/它/he/it`，他回答", "她看 `他/它/he/it`，她回答"),
            ("它看 ``他`它``，他回答", "她看 ``他`它``，她回答"),
            ("他看\n```swift\nlet 他 = 它\n```\n它答", "她看\n```swift\nlet 他 = 它\n```\n她答"),
            ("他看\n~~~text\n他它\n~~~\n它答", "她看\n~~~text\n他它\n~~~\n她答"),
            ("他 ```未关闭的它\n他", "她 ```未关闭的它\n他"),
            ("他 `它\n它", "她 `它\n她"),
            ("🙂他 café e\u{301} 它", "🙂她 café e\u{301} 她"),
            ("他\n\t它  她", "她\n\t她  她"),
        ]
        for (source, expected) in examples {
            check(HerSpeechText.feminine(source) == expected, "speech preference: \(source)")
            check(HerSpeechText.feminine(expected) == expected, "idempotence: \(source)")
        }
        let joins: [(String, String, String)] = [
            ("", "world", "world"), ("Hello", "", "Hello"),
            ("Hello", "world", "Hello world"), ("GitHub", "API", "GitHub API"),
            ("Xcode", "26", "Xcode 26"), ("api_v2", "works", "api_v2 works"),
            ("Hello ", "world", "Hello world"), ("Hello ", " world", "Hello  world"),
            ("a\t", "b", "a\tb"), ("a\n", "b", "a\nb"),
            ("她", "们", "她们"), ("她用", "GitHub", "她用GitHub"),
            ("GitHub", "很好", "GitHub很好"), ("Hello", ", world", "Hello, world"),
            ("Hello,", "world", "Hello,world"), ("(", "API", "(API"),
            ("https://", "example.com", "https://example.com"),
            ("user@", "example.com", "user@example.com"),
            ("🙂", "API", "🙂API"),
        ]
        for (left, right, expected) in joins {
            check(HerSpeechText.join(left, right) == expected, "segment join: \(left)|\(right)")
        }
        var spans: [String] = []
        let protected = "他 `它` 它 https://他.example/它"
        let transformed = HerSpeechText.transform(protected) { value in
            spans.append(value)
            return value.replacingOccurrences(of: "他", with: "她")
        }
        check(transformed == "她 `它` 她 https://他.example/它", "callback cannot repollute protected spans")
        check(spans == ["他 ", " 它 "], "callback only sees ordinary spans")
        check(HerSpeechText.transform("这件事", rewrite: { _ in "它" }) == "她", "rewrite runs before pronouns")
        var called = false
        check(HerSpeechText.transform("https://他.example/它", rewrite: {
            called = true; return $0.uppercased()
        }) == "https://他.example/它" && !called, "all-protected source never calls rewrite")

        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ??
                       FileManager.default.currentDirectoryPath, isDirectory: true)
        let ruleData = try Data(contentsOf: root.appendingPathComponent("ios/Keyboard/Resources/rules.json"))
        let rules = try JSONDecoder().decode(HerRuleSet.self, from: ruleData)
        let engine = try HerPinyinEngine(
            lexicon: [HerLexiconEntry(text: "你好", pinyin: "ni hao", weight: 1)], ruleSet: rules)
        let source = "他很奸诈，它在这里，链接 https://他.example/它 和代码 `他很奸诈它`"
        check(HerSpeechText.transform(source, rewrite: { engine.rewrite($0) }) ==
              "她很狡诈，她在这里，链接 https://他.example/它 和代码 `他很奸诈它`",
              "real language rules respect protected URLs and code")
        check(HerSpeechText.transform("它有能力", rewrite: { engine.rewrite($0, mode: .original) }) == "她有能力",
              "speech pronouns independent of wording mode")
        let wording = try HerSpeechWording(rulesData: ruleData)
        let plain = "他很奸诈，它在这里"
        check(wording.process(plain) == "她很狡诈，她在这里", "public wrapper default neutral wording")
        check(wording.process(plain, mode: .community) == "她很仠诈，她在这里", "public wrapper community opt-in")
        check(wording.process(plain, mode: .original) == "她很奸诈，她在这里", "public wrapper original wording")
        for mode in HerWordingMode.allCases {
            check(wording.process("他 `他很奸诈它` https://他.example/它", mode: mode) ==
                  "她 `他很奸诈它` https://他.example/它",
                  "public wrapper preserves code and URLs in \(mode.rawValue) mode")
        }
        check(wording.process("嫉妒") == "忮忌" && wording.process("我嫉妒他") == "我嫉妒她",
              "public wrapper retains exact rule boundaries")
        let emptyRules = try HerSpeechWording(rulesData: JSONEncoder().encode(HerRuleSet()))
        check(emptyRules.process("他和它 `他它`") == "她和她 `他它`",
              "valid empty rule data still applies protected speech pronouns")
        for missing in [Data(), Data("{".utf8), Data(#"{"exact_aliases":[]}"#.utf8)] {
            do {
                _ = try HerSpeechWording(rulesData: missing)
                fatalError("FAIL: missing or malformed public wrapper rules accepted")
            } catch is DecodingError { checks += 1 }
        }
        do {
            let invalid = HerRuleSet(rules: [HerRewriteRule(from: "女", to: "人")])
            _ = try HerSpeechWording(rulesData: JSONEncoder().encode(invalid))
            fatalError("FAIL: invalid blanket radical rule accepted by wrapper")
        } catch HerEngineError.invalidRule { checks += 1 }
        print("PASS \(checks) Swift speech text checks")
    }
}
