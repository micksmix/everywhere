import Foundation

struct NameQuery {
    struct Term {
        let text: String
        let bytes: [UInt8]
        let negated: Bool
        let ascii: Bool
        let wildcard: Bool
        let regex: NSRegularExpression?

        init(_ term: ParsedTerm, matchCase: Bool, wholeWord: Bool) {
            text = matchCase ? term.text : term.text.lowercased()
            bytes = Array(text.utf8)
            negated = term.isNegated
            ascii = bytes.allSatisfy { $0 < 128 }
            wildcard = term.hasWildcards
            var pattern: String?
            if term.hasWildcards {
                pattern = "^" + term.text.map { character in
                    switch character {
                    case "*": return ".*"
                    case "?": return "."
                    default: return NSRegularExpression.escapedPattern(for: String(character))
                    }
                }.joined() + "$"
            } else if wholeWord {
                pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: term.text) + "(?![\\p{L}\\p{N}_])"
            }
            regex = pattern.flatMap { try? NSRegularExpression(pattern: $0, options: matchCase ? [] : [.caseInsensitive]) }
        }
    }

    let groups: [[Term]]
    let matchCase: Bool
    let literalTerms: [String]?

    init(_ request: SearchRequest) {
        matchCase = request.matchCase
        let parsed = SearchQueryParser.parse(request.text)
        groups = parsed.groups.map { group in
            group.terms.map { Term($0, matchCase: request.matchCase, wholeWord: request.wholeWord) }
                .sorted { left, right in
                    if (left.regex == nil) != (right.regex == nil) { return left.regex == nil }
                    return left.bytes.count > right.bytes.count
                }
        }
        literalTerms = parsed.groups.count == 1 && !request.wholeWord &&
            parsed.groups[0].terms.allSatisfy { !$0.isNegated && !$0.hasWildcards }
            ? groups[0].map(\.text) : nil
    }

    func matches(bytes: UnsafeBufferPointer<UInt8>, isASCII: Bool) -> Bool {
        var decoded: String?
        var folded: String?
        return groups.contains { group in
            group.allSatisfy { term in
                let matched: Bool
                if term.wildcard && term.ascii && isASCII && !bytes.contains(where: { $0 >= 10 && $0 <= 13 }) {
                    matched = Self.glob(bytes, pattern: term.bytes, matchCase: matchCase)
                } else if term.regex == nil && isASCII && term.ascii {
                    matched = Self.contains(bytes, needle: term.bytes, matchCase: matchCase)
                } else {
                    if decoded == nil { decoded = String(decoding: bytes, as: UTF8.self) }
                    let name = decoded!
                    if let regex = term.regex {
                        matched = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                    } else {
                        if folded == nil { folded = matchCase ? name : name.lowercased() }
                        matched = folded!.contains(term.text)
                    }
                }
                return term.negated ? !matched : matched
            }
        }
    }

    func matches(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBufferPointer { matches(bytes: $0, isASCII: bytes.allSatisfy { $0 < 128 }) }
    }

    private static func glob(_ bytes: UnsafeBufferPointer<UInt8>, pattern: [UInt8], matchCase: Bool) -> Bool {
        var source = 0
        var token = 0
        var star: Int?
        var retry = 0
        while source < bytes.count {
            let byte = bytes[source]
            let folded = !matchCase && byte >= 65 && byte <= 90 ? byte + 32 : byte
            if token < pattern.count && pattern[token] == 42 {
                star = token
                token += 1
                retry = source
            } else if token < pattern.count && (pattern[token] == 63 || pattern[token] == folded) {
                source += 1
                token += 1
            } else if let star {
                retry += 1
                source = retry
                token = star + 1
            } else {
                return false
            }
        }
        while token < pattern.count && pattern[token] == 42 { token += 1 }
        return token == pattern.count
    }

    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, needle: [UInt8], matchCase: Bool) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= bytes.count else { return false }
        for offset in 0...(bytes.count - needle.count) {
            var index = 0
            while index < needle.count {
                let byte = bytes[offset + index]
                let folded = !matchCase && byte >= 65 && byte <= 90 ? byte + 32 : byte
                if folded != needle[index] { break }
                index += 1
            }
            if index == needle.count { return true }
        }
        return false
    }
}
