import SwiftUI
import AppKit
import EverywhereCore

struct SearchScopesSettingsView: View {
    @ObservedObject var store: SearchScopeSettings
    @ObservedObject var indexSettings: IndexSettings
    @State private var editingScope: SearchScope?

    var body: some View {
        Section("Default Scope") {
            Picker("On opening Everywhere", selection: $store.defaultScopeID) {
                Text("All").tag(nil as UUID?)
                ForEach(store.orderedScopes) { scope in
                    Text(scope.name).tag(Optional(scope.id))
                }
            }
            Text("All searches every indexed location. Changing scopes never changes what is indexed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Saved Scopes") {
            ForEach(store.orderedScopes) { scope in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((scope.isPinned ? "★ " : "") + scope.name)
                        Text(scopeSummary(scope))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Edit…") { editingScope = scope }
                    Button {
                        store.delete(id: scope.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Delete \(scope.name)")
                }
            }
            Button("New Scope…") { editingScope = SearchScope(name: "") }
        }
        .sheet(item: $editingScope) { scope in
            SearchScopeEditor(scope: scope, store: store, indexedFolders: indexSettings.roots)
        }
    }

    private func scopeSummary(_ scope: SearchScope) -> String {
        let folders = scope.folders.isEmpty ? "All indexed locations" : scope.folders.joined(separator: ", ")
        return scope.expression.isEmpty ? folders : folders + " · " + scope.expression
    }
}

private struct SearchScopeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var scope: SearchScope
    @ObservedObject var store: SearchScopeSettings
    let indexedFolders: [String]
    @State private var folderDraft = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(scope.name.isEmpty ? "New Search Scope" : "Edit Search Scope")
                .font(.title2.bold())
            Form {
                TextField("Name", text: $scope.name)
                Toggle("Pin near the top of the scope menu", isOn: $scope.isPinned)
                Section("Locations (optional)") {
                    ForEach(scope.folders, id: \.self) { folder in
                        HStack {
                            Text(folder).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button {
                                scope.folders.removeAll { $0 == folder }
                            } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove \(folder) from scope")
                        }
                    }
                    HStack {
                        TextField("/Volumes/Share or ~/Projects", text: $folderDraft)
                            .onSubmit(addFolder)
                        Button("Add", action: addFolder).disabled(folderDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Choose…", action: chooseFolders)
                    }
                    if !indexedFolders.isEmpty {
                        Menu("Add Indexed Location") {
                            ForEach(indexedFolders, id: \.self) { folder in
                                Button(folder) { appendFolders([folder]) }
                            }
                        }
                    }
                    Text("Search any of these folders and their descendants, using indexed entries only. Leave empty to use every indexed location, including retained offline entries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Saved Search Expression (optional)") {
                    TextField("For example: ext:pdf dm:thismonth", text: $scope.expression)
                    Text("Use the normal search syntax: ext:pdf;docx, size:>1GB, dm:thismonth, !draft, or | for OR. The saved expression is ANDed with your search text. Tags, AND/OR words, and parenthesized groups are not supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 400)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        if !folderDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addFolder() }
                        try store.save(scope)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func addFolder() {
        let folder = folderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return }
        appendFolders([folder])
        folderDraft = ""
    }

    private func appendFolders(_ folders: [String]) {
        scope.folders = Array(Set(scope.folders + folders)).sorted()
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose indexed folders for this scope. Adding a folder here does not index it."
        guard panel.runModal() == .OK else { return }
        appendFolders(panel.urls.map(\.path))
    }
}
