import AppKit

public enum FileClipboard {
    @discardableResult
    public static func copyFiles(_ paths: [String], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !paths.isEmpty else { return false }
        let urls = paths.map { NSURL(fileURLWithPath: $0) }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls)
    }
}
