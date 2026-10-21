import Foundation

/// Voice adapters share exactly the keyboard's wording data and matching rules.
public struct HerSpeechWording {
    private let rewriter: HerRewriter

    public init(rulesData: Data, useTraditional: Bool = false) throws {
        let rules = try JSONDecoder().decode(HerRuleSet.self, from: rulesData)
        rewriter = try HerRewriter(ruleSet: rules, useTraditional: useTraditional)
    }

    public func process(_ text: String, mode: HerWordingMode = .neutral) -> String {
        HerSpeechText.transform(text) { rewriter.rewrite($0, mode: mode).text }
    }
}
