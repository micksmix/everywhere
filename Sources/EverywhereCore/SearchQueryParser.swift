import Foundation

public struct ParsedTerm: Equatable, Sendable {
    public let text: String
    public let isNegated: Bool

    public var hasPathSeparator: Bool { text.contains("/") }
    public var endsWithPathSeparator: Bool { text.count > 1 && text.hasSuffix("/") }
    public var hasWildcards: Bool { text.contains("*") || text.contains("?") }
}

public struct ParsedGroup: Equatable, Sendable {
    public let terms: [ParsedTerm]
}

public struct ParsedQuery: Equatable, Sendable {
    public let groups: [ParsedGroup]

    public var isEmpty: Bool {
        groups.isEmpty || groups.allSatisfy { $0.terms.isEmpty }
    }
}

public enum SearchQueryParser {
    public static func parse(_ text: String) -> ParsedQuery {
        var groups: [[ParsedTerm]] = [[]]
        var current = ""
        var inQuotes = false

        func commitAtom() {
            let atom = current
            current = ""
            guard !atom.isEmpty else { return }
            if atom == "|" {
                groups.append([])
                return
            }
            var negated = false
            var body = atom
            if body.hasPrefix("!"), body.count > 1 {
                negated = true
                body.removeFirst()
            }
            groups[groups.count - 1].append(ParsedTerm(text: body, isNegated: negated))
        }

        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes && character == "|" {
                commitAtom()
                current.append(character)
                commitAtom()
                continue
            }
            if !inQuotes && character.isWhitespace {
                commitAtom()
                continue
            }
            current.append(character)
        }
        commitAtom()

        return ParsedQuery(groups: groups.map { ParsedGroup(terms: $0) })
    }
}
