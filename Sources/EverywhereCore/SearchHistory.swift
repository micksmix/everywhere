import Foundation

public struct SearchHistory {
    public private(set) var entries: [String]
    private var position: Int?
    private var draft = ""
    private let limit: Int

    public init(entries: [String] = [], limit: Int = 50) {
        self.limit = max(1, limit)
        var seen = Set<String>()
        self.entries = Array(entries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }.prefix(max(1, limit)))
    }

    public mutating func record(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.removeAll { $0 == text }
        entries.insert(text, at: 0)
        entries = Array(entries.prefix(limit))
        resetNavigation()
    }

    public mutating func resetNavigation() {
        position = nil
        draft = ""
    }

    public mutating func previous(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if position == nil { draft = current }
        position = min((position ?? -1) + 1, entries.count - 1)
        return entries[position!]
    }

    public mutating func next() -> String? {
        guard let position else { return nil }
        if position == 0 {
            let restored = draft
            resetNavigation()
            return restored
        }
        self.position = position - 1
        return entries[position - 1]
    }
}

public enum SearchHighlights {
    public static func ranges(in text: String, request: SearchRequest, path: Bool = false) -> [NSRange] {
        let fullRange = NSRange(text.startIndex..., in: text)
        if request.useRegex {
            guard !path || request.matchPath,
                  let regex = try? NSRegularExpression(pattern: request.text, options: request.matchCase ? [] : [.caseInsensitive]) else { return [] }
            return regex.matches(in: text, range: fullRange).map(\.range).filter { $0.length > 0 }
        }
        let terms = SearchQueryParser.parse(request.text).groups.flatMap(\.terms)
        var ranges: [NSRange] = []
        for term in terms where !term.isNegated && FilterQuery.split(term) == nil {
            let usesPath = request.matchPath || term.hasPathSeparator
            guard path == usesPath || (!path && !term.hasPathSeparator) else { continue }
            let needles = term.text.split(whereSeparator: { $0 == "*" || $0 == "?" }).map(String.init)
            for needle in needles where !needle.isEmpty {
                let escaped = NSRegularExpression.escapedPattern(for: needle)
                let pattern = request.wholeWord && !term.hasWildcards ? "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])" : escaped
                guard let regex = try? NSRegularExpression(pattern: pattern, options: request.matchCase ? [] : [.caseInsensitive]) else { continue }
                ranges.append(contentsOf: regex.matches(in: text, range: fullRange).map(\.range))
            }
        }
        return ranges
    }
}
