import Foundation

public enum HerWordingMode: String, Codable, CaseIterable, Sendable {
    case neutral
    case community
    case original
}

public struct HerCandidate: Equatable, Sendable {
    public let text: String
    public let originalText: String
    /// Number of Characters to remove from the original, unnormalized input.
    public let consumedInputCount: Int
    public let annotation: String
    public let isCompletion: Bool
    public let score: Double

    public init(text: String, originalText: String, consumedInputCount: Int,
                annotation: String = "", isCompletion: Bool = false, score: Double = 0) {
        self.text = text
        self.originalText = originalText
        self.consumedInputCount = consumedInputCount
        self.annotation = annotation
        self.isCompletion = isCompletion
        self.score = score
    }
}

public struct HerLexiconEntry: Codable, Sendable {
    public let text: String
    /// Full pinyin, with syllables separated by ASCII spaces; v represents ü.
    public let pinyin: String
    public let weight: Double
    /// Public catalog metadata. Aliases are input spellings, never pinyin.
    public let category: String?
    public let aliases: [String]?
    /// Newly added/restored public words follow the existing ordinary first
    /// candidate; they do not change the base dictionary's sentence ranking.
    public let supplemental: Bool?

    public init(text: String, pinyin: String, weight: Double,
                category: String? = nil, aliases: [String]? = nil, supplemental: Bool? = nil) {
        self.text = text
        self.pinyin = pinyin
        self.weight = weight
        self.category = category
        self.aliases = aliases
        self.supplemental = supplemental
    }
}

public struct HerRewriteRule: Codable, Sendable {
    public let from: String
    public let to: String
    public let toTraditional: String?
    public let community: String?
    public let communityTraditional: String?
    public let match: String

    enum CodingKeys: String, CodingKey {
        case from, to, community, match
        case toTraditional = "to_traditional"
        case communityTraditional = "community_traditional"
    }

    public init(from: String, to: String, match: String = "phrase",
                toTraditional: String? = nil, community: String? = nil,
                communityTraditional: String? = nil) {
        self.from = from
        self.to = to
        self.match = match
        self.toTraditional = toTraditional
        self.community = community
        self.communityTraditional = communityTraditional
    }
}

public struct HerExactAlias: Codable, Sendable {
    public let input: String
    public let friendly: String
    public let friendlyTraditional: String?
    public let community: String?
    public let communityTraditional: String?
    public let friendlyNote: String?
    public let communityNote: String?

    enum CodingKeys: String, CodingKey {
        case input, friendly, community
        case friendlyTraditional = "friendly_traditional"
        case communityTraditional = "community_traditional"
        case friendlyNote = "friendly_note"
        case communityNote = "community_note"
    }

    public init(input: String, friendly: String, friendlyTraditional: String? = nil,
                community: String? = nil, communityTraditional: String? = nil,
                friendlyNote: String? = nil, communityNote: String? = nil) {
        self.input = input
        self.friendly = friendly
        self.friendlyTraditional = friendlyTraditional
        self.community = community
        self.communityTraditional = communityTraditional
        self.friendlyNote = friendlyNote
        self.communityNote = communityNote
    }
}

public struct HerRuleSet: Codable, Sendable {
    public let rules: [HerRewriteRule]
    public let exactAliases: [HerExactAlias]

    enum CodingKeys: String, CodingKey {
        case rules
        case exactAliases = "exact_aliases"
    }

    public init(rules: [HerRewriteRule] = [], exactAliases: [HerExactAlias] = []) {
        self.rules = rules
        self.exactAliases = exactAliases
    }
}

public enum HerEngineError: Error, LocalizedError {
    case emptyLexicon
    case invalidLexiconEntry(Int)
    case invalidRule(String)
    case invalidAlias(String)

    public var errorDescription: String? {
        switch self {
        case .emptyLexicon: return "离线拼音词库为空。"
        case .invalidLexiconEntry(let index): return "离线词库第 \(index + 1) 条数据无效。"
        case .invalidRule(let text): return "措辞规则无效：\(text)"
        case .invalidAlias(let input): return "拼音别名无效：\(input)"
        }
    }
}
