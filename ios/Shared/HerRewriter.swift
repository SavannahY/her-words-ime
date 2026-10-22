import Foundation

struct HerRewriteResult {
    let text: String
    let changedWording: Bool
}

/// Shared wording rules only. Keyboard pronouns keep their selected spelling;
/// speech adapters apply their separate default through HerSpeechText.
/// Replacement output never enters the rules a second time.
struct HerRewriter {
    let rules: [HerRewriteRule]
    let aliases: [String: [HerExactAlias]]
    let useTraditional: Bool

    init(ruleSet: HerRuleSet, useTraditional: Bool) throws {
        for rule in ruleSet.rules {
            guard rule.from.count >= 2, !rule.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rule.match == "phrase" || rule.match == "exact",
                  rule.toTraditional.map({ !$0.isEmpty }) ?? true,
                  rule.community.map({ !$0.isEmpty }) ?? true,
                  rule.communityTraditional.map({ !$0.isEmpty }) ?? true else {
                throw HerEngineError.invalidRule(rule.from)
            }
        }
        var indexed: [String: [HerExactAlias]] = [:]
        for alias in ruleSet.exactAliases {
            guard !alias.input.isEmpty, alias.input.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }),
                  !alias.friendly.isEmpty else {
                throw HerEngineError.invalidAlias(alias.input)
            }
            indexed[alias.input, default: []].append(alias)
        }
        self.rules = ruleSet.rules.enumerated().sorted {
            if $0.element.from.utf8.count == $1.element.from.utf8.count {
                return $0.offset < $1.offset
            }
            return $0.element.from.utf8.count > $1.element.from.utf8.count
        }.map(\.element)
        self.aliases = indexed
        self.useTraditional = useTraditional
    }

    func ruleOutput(_ rule: HerRewriteRule, mode: HerWordingMode) -> String {
        if mode == .community {
            if useTraditional, let text = rule.communityTraditional { return text }
            if let text = rule.community { return text }
        }
        if useTraditional, let text = rule.toTraditional { return text }
        return rule.to
    }

    func aliasOutput(_ alias: HerExactAlias, mode: HerWordingMode) -> String {
        if mode == .community {
            if useTraditional, let text = alias.communityTraditional { return text }
            if let text = alias.community { return text }
        }
        if useTraditional, let text = alias.friendlyTraditional { return text }
        return alias.friendly
    }

    func annotation(mode: HerWordingMode, note: String? = nil) -> String {
        let label = mode == .community ? "社群写法" : "友好表达"
        guard let note = note, !note.isEmpty else { return label }
        return label + " · " + note
    }

    func rewrite(_ source: String, mode: HerWordingMode) -> HerRewriteResult {
        if mode == .original || source.isEmpty {
            return HerRewriteResult(text: source, changedWording: false)
        }
        var position = source.startIndex
        var result = ""
        var changed = false
        while position < source.endIndex {
            var selected: (Range<String.Index>, HerRewriteRule)?
            for rule in rules {
                if rule.match == "exact" && source != rule.from { continue }
                guard let range = source.range(of: rule.from, options: .literal,
                                               range: position..<source.endIndex) else { continue }
                if selected == nil || range.lowerBound < selected!.0.lowerBound {
                    selected = (range, rule)
                }
            }
            guard let (range, rule) = selected else {
                result += source[position...]
                break
            }
            result += source[position..<range.lowerBound]
            let replacement = ruleOutput(rule, mode: mode)
            result += replacement
            changed = changed || replacement != String(source[range])
            position = range.upperBound
        }
        return HerRewriteResult(text: result, changedWording: changed)
    }
}
