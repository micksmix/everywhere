import AppKit
import SwiftUI

struct SearchHelpButton: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.showTips(_:)))
        button.bezelStyle = .helpButton
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Show search syntax tips"
        button.setAccessibilityLabel("Search syntax tips")
        button.setAccessibilityHelp("Shows examples of filename patterns and search filters.")
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {}

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.popover.close()
    }

    final class Coordinator: NSObject {
        let popover = NSPopover()

        @objc func showTips(_ sender: NSButton) {
            if popover.isShown { popover.performClose(sender); return }
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: SearchTipsView { [weak self] in
                self?.popover.performClose(nil)
                AppHelp.showSearchSyntax()
            })
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

struct SearchTipsView: View {
    var openGuide: () -> Void

    private let examples = [
        ("report budget", "Require both fragments"),
        ("\"annual report\"", "Keep a phrase together"),
        ("*.pdf", "Match a filename pattern"),
        ("report !draft", "Exclude a fragment"),
        ("report | invoice", "Match either group"),
        ("ext:pdf;txt", "Filter file extensions"),
        ("type:image", "Filter a file category"),
        ("size:>100MB", "Filter by file size"),
        ("dm:pastweek", "Modified in the past week"),
        ("in:~/Documents", "Include subfolders"),
        ("parent:~/Downloads", "Direct children only")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search Syntax")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Words match anywhere in a filename. Combine filters with name terms.")
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                ForEach(examples, id: \.0) { example in
                    GridRow {
                        Text(example.0).font(.system(.callout, design: .monospaced))
                        Text(example.1).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Quote paths with spaces: in:\"~/My Documents\". * matches any text; ? matches one character.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Turn off .* for these examples. When it’s on, the entire query is a regular expression.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Full Search Guide", action: openGuide)
                .buttonStyle(.link)
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(20)
        .frame(width: 440)
    }
}

enum AppHelp {
    private static var controller: HelpWindowController?

    static func showGuide() { open(anchor: nil) }

    static func showSearchSyntax() { open(anchor: "search-with-patterns") }

    private static func open(anchor: String?) {
        if let folder = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookFolder") as? String,
           let resources = Bundle.main.resourceURL,
           let book = Bundle(url: resources.appendingPathComponent(folder)),
           let page = book.url(forResource: "index", withExtension: "html") {
            if controller == nil { controller = HelpWindowController(directory: page.deletingLastPathComponent()) }
            controller?.open(anchor: anchor)
        } else {
            var url = URLComponents(string: "https://github.com/micksmix/everywhere/blob/main/docs/USER_GUIDE.md")!
            url.fragment = anchor
            if let url = url.url { NSWorkspace.shared.open(url) }
        }
    }
}
