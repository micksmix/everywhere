import Foundation
import Combine

public struct SearchScope: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var folders: [String]
    public var expression: String
    public var isPinned: Bool

    public init(id: UUID = UUID(), name: String, folders: [String] = [], expression: String = "", isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.folders = folders
        self.expression = expression
        self.isPinned = isPinned
    }

    public var isUnrestricted: Bool {
        folders.isEmpty && expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func validated() throws -> SearchScope {
        var scope = self
        scope.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.name.isEmpty else { throw DatabaseError.invalidQuery("Give the scope a name.") }
        guard scope.name.caseInsensitiveCompare("All") != .orderedSame else {
            throw DatabaseError.invalidQuery("All is reserved for searching every indexed location.")
        }
        scope.folders = try folders.map { folder in
            let expanded = (folder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw DatabaseError.invalidQuery("Scope folders need an absolute path or ~/path.") }
            return (expanded as NSString).standardizingPath
        }
        scope.folders = Array(Set(scope.folders)).sorted()
        scope.expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try FilterQuery("", scope: scope)
        return scope
    }
}

public final class SearchScopeSettings: ObservableObject {
    @Published public private(set) var scopes: [SearchScope]
    @Published public var defaultScopeID: UUID? {
        didSet { defaults.set(defaultScopeID?.uuidString, forKey: "DefaultSearchScope") }
    }
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var names = Set<String>()
        var ids = Set<UUID>()
        scopes = (defaults.data(forKey: "SearchScopes").flatMap { try? JSONDecoder().decode([SearchScope].self, from: $0) } ?? [])
            .compactMap { try? $0.validated() }
            .filter { ids.insert($0.id).inserted && names.insert($0.name.lowercased()).inserted }
        let saved = defaults.string(forKey: "DefaultSearchScope").flatMap(UUID.init(uuidString:))
        defaultScopeID = scopes.contains(where: { $0.id == saved }) ? saved : nil
    }

    public var orderedScopes: [SearchScope] {
        scopes.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func save(_ scope: SearchScope) throws {
        let scope = try scope.validated()
        guard !scopes.contains(where: { $0.id != scope.id && $0.name.caseInsensitiveCompare(scope.name) == .orderedSame }) else {
            throw DatabaseError.invalidQuery("A scope with that name already exists.")
        }
        var updated = scopes.filter { $0.id != scope.id }
        updated.append(scope)
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: "SearchScopes")
        scopes = updated
    }

    public func relocateFolders(using paths: [String: String]) {
        let moves = paths.filter { $0.key.hasPrefix("/") && $0.value.hasPrefix("/") && $0.key != $0.value }
            .sorted { $0.key.count > $1.key.count }
        guard !moves.isEmpty else { return }
        let updated = scopes.map { scope -> SearchScope in
            var scope = scope
            scope.folders = Array(Set(scope.folders.map { folder in
                guard let move = moves.first(where: { folder == $0.key || folder.hasPrefix($0.key == "/" ? "/" : $0.key + "/") }) else { return folder }
                var suffix = String(folder.dropFirst(move.key.count))
                if suffix.hasPrefix("/") { suffix.removeFirst() }
                return Walk.normalizePath(suffix.isEmpty ? move.value : Walk.joinPath(move.value, suffix))
            })).sorted()
            return scope
        }
        guard updated != scopes, let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: "SearchScopes")
        scopes = updated
    }

    public func delete(id: UUID) {
        let updated = scopes.filter { $0.id != id }
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: "SearchScopes")
            if defaultScopeID == id { defaultScopeID = nil }
            scopes = updated
        }
    }
}
