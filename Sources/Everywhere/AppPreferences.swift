import AppKit
import Combine

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    struct TerminalApplication: Identifiable {
        let name: String
        let bundleIdentifier: String
        let filenames: [String]

        var id: String { bundleIdentifier }

        func installedURL() -> URL? {
            let manager = FileManager.default
            let home = manager.homeDirectoryForCurrentUser
            let directories = [
                URL(fileURLWithPath: "/Applications"),
                home.appendingPathComponent("Applications"),
                URL(fileURLWithPath: "/Applications/Utilities"),
                home.appendingPathComponent("Applications/Utilities"),
                URL(fileURLWithPath: "/System/Applications"),
                URL(fileURLWithPath: "/System/Applications/Utilities"),
                URL(fileURLWithPath: "/opt/homebrew/opt"),
                URL(fileURLWithPath: "/usr/local/opt")
            ]
            for directory in directories {
                for filename in filenames {
                    let url = directory.appendingPathComponent(filename)
                    if Bundle(url: url)?.bundleIdentifier == bundleIdentifier {
                        return url.resolvingSymlinksInPath()
                    }
                }
            }
            guard let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                  manager.fileExists(atPath: registered.path) else { return nil }
            return registered
        }
    }

    static let terminalApplications = [
        TerminalApplication(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", filenames: ["Ghostty.app", "ghostty/Ghostty.app"]),
        TerminalApplication(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", filenames: ["iTerm.app", "iTerm2.app"]),
        TerminalApplication(name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable", filenames: ["Warp.app"]),
        TerminalApplication(name: "kitty", bundleIdentifier: "net.kovidgoyal.kitty", filenames: ["kitty.app", "kitty/kitty.app"]),
        TerminalApplication(name: "Terminal", bundleIdentifier: "com.apple.Terminal", filenames: ["Terminal.app"])
    ]

    enum Appearance: String, CaseIterable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
    }

    @Published var keepSearchIndexInMemory: Bool {
        didSet { UserDefaults.standard.set(keepSearchIndexInMemory, forKey: "KeepSearchIndexInMemory") }
    }

    @Published var terminalPath: String {
        didSet { UserDefaults.standard.set(terminalPath, forKey: "TerminalApplicationPath") }
    }

    @Published var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "ApplicationAppearance")
            applyAppearance()
        }
    }

    private init() {
        keepSearchIndexInMemory = UserDefaults.standard.object(forKey: "KeepSearchIndexInMemory") == nil
            || UserDefaults.standard.bool(forKey: "KeepSearchIndexInMemory")
        terminalPath = UserDefaults.standard.string(forKey: "TerminalApplicationPath") ?? ""
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "ApplicationAppearance") ?? "") ?? .system
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
