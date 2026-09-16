import SwiftUI
import EverywhereCore

struct ContentView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @EnvironmentObject var indexService: IndexService
    @EnvironmentObject var settings: IndexSettings

    private var needsLaunchModal: Bool {
        indexService.showsLaunchAccessPrompt ||
        (indexService.launchAccessState == .ready && settings.needsLocationSetup)
    }

    var body: some View {
        VStack(spacing: 0) {
            ResultsTableView()
            statusBar
        }
        .overlay {
            if !viewModel.searchText.isEmpty && viewModel.results.isEmpty && indexService.phase == .idle {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    SearchField(text: $viewModel.searchText, focusToken: viewModel.focusToken) {
                        viewModel.openSelection()
                    }
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 340)
                    searchModifiers
                }
            }
            ToolbarItem {
                Picker("Filter", selection: $viewModel.kindFilter) {
                    Text("All").tag(KindFilter.all)
                    Text("Folders").tag(KindFilter.folders)
                    Text("Files").tag(KindFilter.files)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 190)
                .accessibilityLabel("Filter results")
            }
        }
        .sheet(isPresented: Binding(get: { needsLaunchModal }, set: { _ in })) {
            Group {
                if indexService.showsLaunchAccessPrompt {
                    LaunchAccessView()
                } else {
                    IndexSetupView()
                }
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            indexService.startIfNeeded()
        }
        .onChange(of: settings.needsLocationSetup) { needsSetup in
            if !needsSetup { indexService.startIfNeeded() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Matches")
                .font(.title3)
            Text("Try different keywords.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultSummary: String {
        if let error = viewModel.searchError {
            return error
        }
        if viewModel.searchText.isEmpty {
            if let error = indexService.indexCountError { return error }
            if !indexService.hasLoadedIndexCount { return "Loading saved index…" }
            if indexService.indexedRows > 0 {
                return "\(indexService.indexedRows.formatted()) items indexed"
            }
            return indexService.isBusy ? "Index not ready yet" : "No items indexed"
        }
        let shown = viewModel.results.count.formatted()
        let total = viewModel.totalMatches.formatted()
        return "\(shown) of \(total) matches · \(String(format: "%.1f", viewModel.elapsedMS)) ms"
    }

    private var indexState: some View {
        HStack(spacing: 6) {
            switch indexService.phase {
            case .waiting:
                Text("Waiting to index")
            case .indexing:
                Text(indexService.isPaused ? "Paused" : "Indexing")
            case .reconciling:
                Text(indexService.isPaused ? "Paused" : "Updating index")
            case .finalizing:
                Text("Preparing search index")
            case .idle:
                if indexService.isCompacting {
                    Text("Compacting index…")
                } else if !settings.indexingEnabled {
                    Text("Indexing disabled")
                } else if indexService.live {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Live")
                } else {
                    Text("Live updates paused")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text(resultSummary)
                    .foregroundStyle(viewModel.searchError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                Spacer()
                if indexService.isBusy {
                    IndexingProgressView()
                } else {
                    indexState
                }
                Toggle("Live Updates", isOn: Binding(
                    get: { settings.liveUpdates },
                    set: { enabled in
                        settings.liveUpdates = enabled
                        indexService.setLive(enabled)
                    }
                ))
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(!settings.indexingEnabled)
                .help(settings.indexingEnabled
                      ? "Toggle live filesystem updates. Changes take effect after any current scan finishes."
                      : "Enable indexing in Settings to control live updates.")
                .accessibilityLabel("Live filesystem updates")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    private var searchModifiers: some View {
        HStack(spacing: 3) {
            searchModifier("Aa", title: "Match Case", isOn: $viewModel.matchCase)
            searchModifier("Word", title: "Match Whole Words", isOn: $viewModel.wholeWord)
            searchModifier("Path", title: "Match Path", isOn: $viewModel.matchPath)
            searchModifier(".*", title: "Use Regular Expressions", isOn: $viewModel.useRegex)
            searchModifier("Hidden", title: "Show Hidden Files", isOn: $viewModel.showHidden)
        }
        .fixedSize()
    }

    private func searchModifier(_ label: String, title: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(SearchModifierToggleStyle())
            .controlSize(.small)
            .fixedSize()
            .help(title)
            .accessibilityLabel(title)
    }
}

private struct SearchModifierToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 11))
                .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(configuration.isOn ? Color.blue : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(configuration.isOn ? Color.blue : Color.primary.opacity(0.18))
                }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
