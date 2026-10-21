import Foundation

struct SpeechProfile: Decodable {
    let label: String
    let contextualStrings: [String]
    let hotwords: [String]
    enum CodingKeys: String, CodingKey {
        case label, hotwords
        case contextualStrings = "contextual_strings"
    }

    static func load() throws -> [String: SpeechProfile] {
        struct Document: Decodable { let version: Int; let profiles: [String: SpeechProfile] }
        guard let url = Bundle.main.url(forResource: "profiles", withExtension: "json") else {
            throw NSError(domain: "HerWords.Speech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "缺少语音词汇配置。"])
        }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else {
            throw NSError(domain: "HerWords.Speech", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "语音词汇配置版本不支持。"])
        }
        return document.profiles
    }
}
