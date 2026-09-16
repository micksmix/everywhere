import SwiftUI
import AppKit
import EverywhereCore

struct FullDiskAccessView: View {
    @State private var couldNotOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow Full Disk Access for more complete search results and fewer permission prompts. Everywhere indexes filenames and metadata, including in protected folders; it doesn’t read file contents.")
            Button("Open Full Disk Access Settings") {
                let urls = [
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                ]
                couldNotOpen = !urls.contains { address in
                    guard let url = URL(string: address) else { return false }
                    return NSWorkspace.shared.open(url)
                }
            }
            Text("In System Settings → Privacy & Security → Full Disk Access, enable Everywhere. If missing, use + to add Everywhere from Applications. Then quit and reopen Everywhere; if you already scanned, reindex in Settings → Locations.")
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
