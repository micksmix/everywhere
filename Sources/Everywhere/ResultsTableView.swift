import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers
import EverywhereCore

struct ResultsTableView: NSViewRepresentable {
    @EnvironmentObject var viewModel: ContentViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FSTableView()
        table.headerView = NSTableHeaderView()
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Search results")

        let specs: [(id: String, title: String, width: CGFloat, minWidth: CGFloat, maxWidth: CGFloat, flexible: Bool)] = [
            ("name", "Name", 280, 120, 10_000, true),
            ("path", "Path", 340, 120, 10_000, true),
            ("size", "Size", 90, 60, 220, false),
            ("kind", "Kind", 100, 60, 260, false),
            ("modified", "Date Modified", 160, 110, 320, false)
        ]

        for spec in specs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.maxWidth = spec.maxWidth
            column.resizingMask = spec.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if spec.id == "name" || spec.id == "path" {
                column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true, selector: #selector(NSString.compare(_:)))
            } else {
                column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            }
            table.addTableColumn(column)
        }

        table.autosaveName = "EverywhereResults"
        table.autosaveTableColumns = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.singleClicked(_:))
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onEnter = { [weak viewModel] in viewModel?.openSelection() }
        table.previewItems = { [weak viewModel] in viewModel?.selectedEntries ?? [] }
        viewModel.previewSelection = { [weak table, weak viewModel] in
            viewModel?.rememberSearch()
            table?.togglePreview()
        }
        table.menu = context.coordinator.makeContextMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? FSTableView else { return }
        context.coordinator.sync(table: table)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private let viewModel: ContentViewModel
        private weak var tableView: FSTableView?
        private var lastResults: [Entry] = []
        private var lastSelection: Set<Int64> = []
        private var lastSortKey = ""
        private var lastHighlightRequest = SearchRequest()

        private static let iconCache = NSCache<NSString, NSImage>()

        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter
        }()

        init(viewModel: ContentViewModel) {
            self.viewModel = viewModel
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.loadMoreResults(after: row)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            viewModel.results.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < viewModel.results.count, let column = tableColumn else { return nil }
            let entry = viewModel.results[row]
            let columnID = column.identifier.rawValue

            if let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView {
                cell.textField?.attributedStringValue = highlightedText(for: entry, columnID: columnID)
                if columnID == "name" { cell.imageView?.image = Self.icon(for: entry) }
                return cell
            }

            let text = NSTextField(labelWithString: Self.displayText(for: entry, columnID: columnID))
            text.attributedStringValue = highlightedText(for: entry, columnID: columnID)
            text.lineBreakMode = .byTruncatingMiddle
            text.maximumNumberOfLines = 1
            text.cell?.wraps = false
            text.cell?.isScrollable = false
            text.cell?.usesSingleLineMode = true
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if columnID == "path" {
                text.textColor = .secondaryLabelColor
            }
            if columnID == "size" || columnID == "modified" {
                text.alignment = .right
            }

            let cell = NSTableCellView()
            cell.identifier = column.identifier
            cell.textField = text
            if columnID == "name" {
                let iconView = NSImageView(image: Self.icon(for: entry))
                iconView.translatesAutoresizingMaskIntoConstraints = false
                cell.imageView = iconView
                cell.addSubview(iconView)
                cell.addSubview(text)
                NSLayoutConstraint.activate([
                    iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iconView.widthAnchor.constraint(equalToConstant: 16),
                    iconView.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else {
                cell.addSubview(text)
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            lastSelection = selectedIDs(in: table)
            viewModel.selection = lastSelection
            (table as? FSTableView)?.refreshPreview()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            viewModel.apply(sortDescriptors: tableView.sortDescriptors)
        }

        private func highlightedText(for entry: Entry, columnID: String) -> NSAttributedString {
            let value = Self.displayText(for: entry, columnID: columnID)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            paragraph.alignment = columnID == "size" || columnID == "modified" ? .right : .left
            let result = NSMutableAttributedString(string: value, attributes: [.paragraphStyle: paragraph])
            guard columnID == "name" || columnID == "path" else { return result }
            for range in SearchHighlights.ranges(in: value, request: viewModel.displayedRequest, path: columnID == "path") {
                result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: range)
            }
            return result
        }

        static func displayText(for entry: Entry, columnID: String) -> String {
            switch columnID {
            case "name": return entry.name
            case "path": return entry.path
            case "size": return entry.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            case "kind": return entry.kind
            case "modified": return dateFormatter.string(from: entry.modified)
            default: return ""
            }
        }

        static func icon(for entry: Entry) -> NSImage {
            let extensionKey = (entry.name as NSString).pathExtension.lowercased()
            let key = (entry.isDirectory ? "__folder" : "ext:\(extensionKey)") as NSString
            if let cached = iconCache.object(forKey: key) { return cached }
            let base: NSImage
            if entry.isDirectory {
                base = NSWorkspace.shared.icon(for: .folder)
            } else {
                let ext = (entry.name as NSString).pathExtension
                let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? UTType.data)
                base = NSWorkspace.shared.icon(for: type)
            }
            let sized = base.copy() as! NSImage
            sized.size = NSSize(width: 16, height: 16)
            iconCache.setObject(sized, forKey: key)
            return sized
        }

        private func selectedIDs(in table: NSTableView) -> Set<Int64> {
            var ids = Set<Int64>()
            for row in table.selectedRowIndexes where row < viewModel.results.count && row >= 0 {
                ids.insert(viewModel.results[row].id)
            }
            return ids
        }

        private func targetEntries() -> [Entry] {
            guard let table = tableView else { return [] }
            let row = table.clickedRow
            if row >= 0 && row < viewModel.results.count {
                let entry = viewModel.results[row]
                if viewModel.selection.contains(entry.id) {
                    return viewModel.selectedEntries
                }
                return [entry]
            }
            return viewModel.selectedEntries
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self

            let open = NSMenuItem(title: "Open", action: #selector(openFromMenu(_:)), keyEquivalent: "")
            open.target = self
            menu.addItem(open)

            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let openWithMenu = NSMenu(title: "Open With")
            openWithMenu.autoenablesItems = false
            openWith.submenu = openWithMenu
            menu.addItem(openWith)

            let openInTerminal = NSMenuItem(
                title: "Open in Terminal",
                action: #selector(openInTerminalFromMenu(_:)),
                keyEquivalent: ""
            )
            openInTerminal.target = self
            menu.addItem(openInTerminal)

            let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealFromMenu(_:)), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)

            let preview = NSMenuItem(title: "Quick Look", action: #selector(previewFromMenu(_:)), keyEquivalent: "")
            preview.target = self
            menu.addItem(preview)

            let info = NSMenuItem(title: "Get Info", action: #selector(showInfoFromMenu(_:)), keyEquivalent: "")
            info.target = self
            menu.addItem(info)

            menu.addItem(.separator())

            let copyName = NSMenuItem(title: "Copy Name", action: #selector(copyNameFromMenu(_:)), keyEquivalent: "")
            copyName.target = self
            menu.addItem(copyName)

            let copyPath = NSMenuItem(title: "Copy Path", action: #selector(copyPathFromMenu(_:)), keyEquivalent: "")
            copyPath.target = self
            menu.addItem(copyPath)

            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            let entries = targetEntries()
            for item in menu.items {
                item.isEnabled = !entries.isEmpty
            }
            if let openWithItem = menu.item(withTitle: "Open With"), let submenu = openWithItem.submenu {
                rebuildOpenWithMenu(submenu, for: entries.first)
                openWithItem.isEnabled = entries.count == 1
            }
        }

        private func rebuildOpenWithMenu(_ submenu: NSMenu, for entry: Entry?) {
            submenu.removeAllItems()
            guard let entry else { return }
            let url = URL(fileURLWithPath: entry.path)
            var appURLs = NSWorkspace.shared.urlsForApplications(toOpen: url)
            if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url) {
                appURLs.removeAll { $0 == defaultApp }
                appURLs.insert(defaultApp, at: 0)
            }
            for appURL in appURLs.prefix(12) {
                let displayName = FileManager.default.displayName(atPath: appURL.path)
                let item = NSMenuItem(title: displayName, action: #selector(openWithApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = appURL.path
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                submenu.addItem(item)
            }
            if submenu.items.isEmpty {
                let none = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
                none.isEnabled = false
                submenu.addItem(none)
            }
        }

        @objc func singleClicked(_ sender: Any?) {}

        @objc func doubleClicked(_ sender: Any?) {
            viewModel.openSelection()
        }

        @objc private func openFromMenu(_ sender: Any?) {
            for entry in targetEntries().prefix(10) {
                ContentViewModel.open(entry)
            }
        }

        @objc private func revealFromMenu(_ sender: Any?) {
            let urls = targetEntries().map { URL(fileURLWithPath: $0.path) }
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        @objc private func previewFromMenu(_ sender: Any?) {
            guard let table = tableView else { return }
            let targets = targetEntries()
            viewModel.selection = Set(targets.map(\.id))
            table.togglePreview(entries: targets)
        }

        @objc private func showInfoFromMenu(_ sender: Any?) {
            viewModel.showInfo(targetEntries())
        }

        @objc private func openInTerminalFromMenu(_ sender: Any?) {
            viewModel.openInTerminal(targetEntries())
        }

        @objc private func openWithApp(_ sender: NSMenuItem) {
            guard let appPath = sender.representedObject as? String else { return }
            let appURL = URL(fileURLWithPath: appPath)
            let configuration = NSWorkspace.OpenConfiguration()
            for entry in targetEntries().prefix(5) {
                let url = URL(fileURLWithPath: entry.path)
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            }
        }

        @objc private func copyNameFromMenu(_ sender: Any?) {
            viewModel.copyName(targetEntries())
        }

        @objc private func copyPathFromMenu(_ sender: Any?) {
            viewModel.copyPath(targetEntries())
        }

        func sync(table: FSTableView) {
            if tableView == nil { tableView = table }

            let sortKey = viewModel.sortDescriptors.map { "\($0.key ?? "-"):\($0.ascending)" }.joined(separator: "|")
            let tableSortKey = table.sortDescriptors.map { "\($0.key ?? "-"):\($0.ascending)" }.joined(separator: "|")
            if sortKey != tableSortKey {
                table.sortDescriptors = viewModel.sortDescriptors
            }

            if lastResults != viewModel.results || lastHighlightRequest != viewModel.displayedRequest {
                lastHighlightRequest = viewModel.displayedRequest
                let previouslySelected = viewModel.selection
                lastResults = viewModel.results
                table.reloadData()
                var indexes = IndexSet()
                for (index, entry) in viewModel.results.enumerated() where previouslySelected.contains(entry.id) {
                    indexes.insert(index)
                }
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                lastSelection = selectedIDs(in: table)
                table.refreshPreview()
            }
            let desired = IndexSet(viewModel.results.indices.filter { viewModel.selection.contains(viewModel.results[$0].id) })
            if table.selectedRowIndexes != desired {
                table.selectRowIndexes(desired, byExtendingSelection: false)
            }
        }
    }
}

final class FSTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var previewItems: (() -> [Entry])?
    private var previewURLs: [NSURL] = []
    private weak var previewPanel: QLPreviewPanel?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        previewPanel = panel
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        previewPanel = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index]
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if [49, 53].contains(event.keyCode) { panel.orderOut(nil); return true }
        if [125, 126].contains(event.keyCode) { keyDown(with: event); return true }
        return false
    }

    func togglePreview(entries: [Entry]? = nil) {
        if let panel = previewPanel, panel.isVisible { panel.orderOut(nil); return }
        previewURLs = (entries ?? previewItems?() ?? []).map { NSURL(fileURLWithPath: $0.path) }
        guard !previewURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        window?.makeFirstResponder(self)
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func refreshPreview() {
        guard let panel = previewPanel, panel.isVisible else { return }
        previewURLs = (previewItems?() ?? []).map { NSURL(fileURLWithPath: $0.path) }
        if previewURLs.isEmpty { panel.orderOut(nil) } else { panel.reloadData() }
    }

    var onEnter: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            togglePreview()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function)
            if modifiers.isEmpty {
                onEnter?()
                return
            }
        }
        super.keyDown(with: event)
    }
}
