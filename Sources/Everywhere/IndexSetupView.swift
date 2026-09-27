import SwiftUI
import AppKit
import EverywhereCore

private func openFullDiskAccessSettings() -> Bool {
    let urls = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    ]
    return urls.contains { address in
        guard let url = URL(string: address) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

struct FullDiskAccessView: View {
    @State private var couldNotOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow Full Disk Access for more complete search results and fewer permission prompts. Everywhere indexes filenames and metadata, including in protected folders; it doesn’t read file contents.")
            Button("Open Full Disk Access Settings") {
                couldNotOpen = !openFullDiskAccessSettings()
            }
            Text("Without it, macOS asks once each for Desktop, Documents, Downloads, Photos, and other apps’ data; Full Disk Access removes all of these prompts. In System Settings → Privacy & Security → Full Disk Access, enable Everywhere (use + to add Everywhere from Applications if missing), then quit and reopen Everywhere; if you already scanned, reindex in Settings → File Access. Started from a terminal, it is the terminal that needs the access instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if couldNotOpen {
                Text("Couldn’t open System Settings. Open it from the Apple menu and follow the path above.")
                    .foregroundStyle(.red)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PrivacyHintView: View {
    @EnvironmentObject var indexService: IndexService
    @State private var couldNotOpen = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Indexing skipped \(indexService.progressStats.skipped.formatted()) items that macOS kept unreadable.")
                Text("Allow Full Disk Access in System Settings, then quit and reopen Everywhere and reindex in Settings → File Access. Started from a terminal, it is the terminal that needs the access instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if couldNotOpen {
                    Text("Couldn’t open System Settings. Open it from the Apple menu and follow the path above.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Open Full Disk Access Settings") {
                couldNotOpen = !openFullDiskAccessSettings()
            }
            Button {
                indexService.dismissPrivacyHint()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.1))
    }
}

struct RebuildSuggestionView: View {
    @EnvironmentObject var indexService: IndexService

    private var ageText: String {
        if let date = indexService.settings.lastFullRebuildDate {
            return "This index was last fully rebuilt \(Text(date, style: .date).fontWeight(.medium))."
        }
        return "This index has never been fully rebuilt."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ageText) Rebuilding it now is recommended.")
                Text("Live updates keep results current, but a periodic rebuild clears dead entries and silent drift. Rebuilding takes a few minutes; you can keep searching meanwhile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rebuild Index") {
                indexService.rebuild()
            }
            Button {
                indexService.dismissRebuildSuggestion()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.1))
    }
}

struct IndexSetupView: View {
    @EnvironmentObject var settings: IndexSettings
    @State private var scope = "home"
    @State private var folders: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose where to search")
                .font(.title2.bold())
            Text("Everywhere will start indexing after you choose a location.")
            Picker("Index location", selection: $scope) {
                Text("Home folder (recommended)").tag("home")
                Text("Entire Mac").tag("disk")
                Text("Choose folders").tag("custom")
            }
            .pickerStyle(.radioGroup)
            if scope == "home" {
                Text("Includes your Library folder. You can change locations later in Settings.")
                    .foregroundStyle(.secondary)
            } else if scope == "disk" {
                Text("Searches accessible files under /. A full scan takes longer and benefits from Full Disk Access.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Choose Folders…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK {
                        folders = Array(Set(panel.urls.map(\.path))).sorted()
                    }
                }
                if !folders.isEmpty {
                    ScrollView {
                        Text(folders.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 70)
                }
            }
            HStack {
                Spacer()
                Button("Start Indexing") {
                    switch scope {
                    case "disk": settings.roots = ["/"]
                    case "custom": settings.roots = folders
                    default: settings.roots = [FileManager.default.homeDirectoryForCurrentUser.path]
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(scope == "custom" && folders.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct LaunchAccessView: View {
    @EnvironmentObject var indexService: IndexService
    @State private var hasRetried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if indexService.launchAccessState == .checking {
                ProgressView("Checking file access…")
            } else {
                Text("Allow Full Disk Access")
                    .font(.title2.bold())
                Text("Your index is empty and macOS is restricting access to protected files.")
                FullDiskAccessView()
                if hasRetried, let message = indexService.accessCheckMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Continue with Limited Access") {
                        indexService.continueWithLimitedAccess()
                    }
                    Spacer()
                    Button("Check Again") {
                        hasRetried = true
                        indexService.checkLaunchAccess()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
