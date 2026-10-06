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

public struct SearchHighlights {
    private let request: SearchRequest
    private let namePatterns: [NSRegularExpression]
    private let pathPatterns: [NSRegularExpression]

    public init(request: SearchRequest) {
        self.request = request
        let options: NSRegularExpression.Options = request.matchCase ? [] : [.caseInsensitive]
        if request.useRegex {
            let regex = try? NSRegularExpression(pattern: request.text, options: options)
            namePatterns = regex.map { [$0] } ?? []
            pathPatterns = request.matchPath ? namePatterns : []
            return
        }
        let terms = SearchQueryParser.parse(request.text).groups.flatMap(\.terms)
        var names: [NSRegularExpression] = []
        var paths: [NSRegularExpression] = []
        for term in terms where !term.isNegated && FilterQuery.split(term) == nil {
            let needles = term.text.split(whereSeparator: { $0 == "*" || $0 == "?" }).map(String.init)
            for needle in needles where !needle.isEmpty {
                let escaped = NSRegularExpression.escapedPattern(for: needle)
                let pattern = request.wholeWord && !term.hasWildcards ? "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])" : escaped
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
                if !term.hasPathSeparator { names.append(regex) }
                if request.matchPath || term.hasPathSeparator { paths.append(regex) }
            }
        }
        namePatterns = names
        pathPatterns = paths
    }

    public func isCompatible(with request: SearchRequest) -> Bool {
        self.request.text == request.text && self.request.useRegex == request.useRegex
            && self.request.matchCase == request.matchCase && self.request.matchPath == request.matchPath
            && self.request.wholeWord == request.wholeWord
    }

    public func ranges(in text: String, path: Bool = false) -> [NSRange] {
        let fullRange = NSRange(text.startIndex..., in: text)
        return (path ? pathPatterns : namePatterns).flatMap { regex in
            regex.matches(in: text, range: fullRange).map(\.range).filter { !request.useRegex || $0.length > 0 }
        }
    }

    public static func ranges(in text: String, request: SearchRequest, path: Bool = false) -> [NSRange] {
        Self(request: request).ranges(in: text, path: path)
    }
}
