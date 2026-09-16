import AppKit
import WebKit

final class HelpWindowController: NSWindowController, NSToolbarDelegate, WKNavigationDelegate {
    private let webView = WKWebView()
    private let directory: URL
    private let findField = NSSearchField()
    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?

    init(directory: URL) {
        self.directory = directory
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Everywhere Help"
        window.minSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("EverywhereHelp")
        window.contentView = webView
        super.init(window: window)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        let toolbar = NSToolbar(identifier: "EverywhereHelpToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func open(anchor: String?) {
        var components = URLComponents(url: directory.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
        components.fragment = anchor
        if let url = components.url { webView.loadFileURL(url, allowingReadAccessTo: directory) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("back"), NSToolbarItem.Identifier("forward"), NSToolbarItem.Identifier("home"),
         .flexibleSpace, NSToolbarItem.Identifier("find")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.autovalidates = false
        switch identifier.rawValue {
        case "back":
            item.label = "Back"
            item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
            item.action = #selector(goBack)
            item.isEnabled = webView.canGoBack
            backItem = item
        case "forward":
            item.label = "Forward"
            item.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward")
            item.action = #selector(goForward)
            item.isEnabled = webView.canGoForward
            forwardItem = item
        case "home":
            item.label = "User Guide"
            item.image = NSImage(systemSymbolName: "house", accessibilityDescription: "User Guide")
            item.action = #selector(goHome)
        case "find":
            item.label = "Find on Page"
            findField.placeholderString = "Find on Page"
            findField.setAccessibilityLabel("Find on Page")
            findField.target = self
            findField.action = #selector(findOnPage)
            findField.sendsSearchStringImmediately = false
            findField.sendsWholeSearchString = true
            findField.widthAnchor.constraint(equalToConstant: 180).isActive = true
            item.view = findField
        default: return nil
        }
        item.toolTip = item.label
        return item
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func goHome() { open(anchor: nil) }

    @objc private func findOnPage() {
        let configuration = WKFindConfiguration()
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(findField.stringValue, configuration: configuration) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        backItem?.isEnabled = webView.canGoBack
        forwardItem?.isEnabled = webView.canGoForward
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.isFileURL && url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }
    }
}
