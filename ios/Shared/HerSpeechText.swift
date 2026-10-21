import Foundation

/// Deterministic transcript cleanup. Does not change acoustic recognition,
/// translate English, or guess homophones.
public enum HerSpeechText {
    // Protect explicit Markdown code, URLs and common Unicode email addresses.
    // Undelimited arbitrary source code cannot be inferred safely.
    private static let addressPattern = #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s<>"`，。！？；：、（）【】「」『』《》]+|www\.[^\s<>"`，。！？；：、（）【】「」『』《》]+|[\p{L}\p{M}\p{N}._%+\-]+@[\p{L}\p{M}\p{N}.\-]+\.[\p{L}\p{M}\p{N}]+"#
    private static let addressExpression = try! NSRegularExpression(
        pattern: addressPattern, options: .caseInsensitive)

    /// 他/它 -> 她. 牠/祂 and English he/him/it remain unchanged.
    public static func feminine(_ text: String) -> String {
        transform(text, rewrite: { $0 })
    }

    /// Process each ordinary span once: wording rewrite, then pronouns.
    /// Do not run a whole-string wording rewrite on the returned result:
    /// doing so would undo URL/email/code protection.
    public static func transform(_ text: String, rewrite: (String) -> String) -> String {
        guard !text.isEmpty else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for range in protectedRanges(text) {
            if range.location > cursor {
                result += pronouns(rewrite(source.substring(
                    with: NSRange(location: cursor, length: range.location - cursor))))
            }
            result += source.substring(with: range)
            cursor = range.location + range.length
        }
        if cursor < source.length {
            result += pronouns(rewrite(source.substring(from: cursor)))
        }
        return result
    }

    /// Add a space only between ASCII word blocks. Preserve existing whitespace
    /// and all other boundaries. Does not infer split identifiers or words.
    public static func join(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return left + right }
        return left + (asciiWord(last) && asciiWord(first) ? " " : "") + right
    }

    private static func asciiWord(_ value: Character) -> Bool {
        let bytes = Array(String(value).utf8)
        guard bytes.count == 1 else { return false }
        let byte = bytes[0]
        return (65...90).contains(byte) || (97...122).contains(byte) ||
            (48...57).contains(byte) || byte == 95
    }

    private static func pronouns(_ text: String) -> String {
        text.replacingOccurrences(of: "他", with: "她", options: .literal)
            .replacingOccurrences(of: "它", with: "她", options: .literal)
    }

    private static func protectedRanges(_ text: String) -> [NSRange] {
        let source = text as NSString
        var ranges = codeRanges(source)
        ranges += addressExpression.matches(
            in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        ranges.sort {
            $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
        }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location <= last.location + last.length {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: max(last.location + last.length, range.location + range.length) - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Linear UTF-16 scan handles multi-backtick spans and unmatched fences.
    /// ASCII marker boundaries never split a surrogate pair.
    private static func codeRanges(_ source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = 0
        while index < source.length {
            let marker = source.character(at: index)
            guard marker == 96 || marker == 126 else { index += 1; continue }
            var openingEnd = index + 1
            while openingEnd < source.length, source.character(at: openingEnd) == marker {
                openingEnd += 1
            }
            let count = openingEnd - index
            if marker == 126 && count < 3 { index = openingEnd; continue }
            let fenced = count >= 3
            var end = openingEnd
            while end < source.length {
                let value = source.character(at: end)
                if !fenced && (value == 10 || value == 13) { break }
                if value == marker {
                    var closingEnd = end + 1
                    while closingEnd < source.length, source.character(at: closingEnd) == marker {
                        closingEnd += 1
                    }
                    if closingEnd - end >= count { end = closingEnd; break }
                    end = closingEnd
                } else {
                    end += 1
                }
            }
            ranges.append(NSRange(location: index, length: end - index))
            index = end
        }
        return ranges
    }
}
