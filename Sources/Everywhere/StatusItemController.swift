import AppKit

final class StatusItemController {
    private var statusItem: NSStatusItem?
    var onOpen: (() -> Void)?
    var onRebuild: (() -> Void)?
    var onSettings: (() -> Void)?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusIcon()
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Everywhere"
        statusItem = item
    }

    @objc private func statusClicked() {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp else {
            onOpen?()
            return
        }
        presentMenu()
    }

    private func presentMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "Open Everywhere", action: #selector(openClicked), keyEquivalent: " ")
        open.keyEquivalentModifierMask = [.option]
        open.target = self
        open.isEnabled = true
        menu.addItem(open)

        let rebuild = NSMenuItem(title: "Rebuild Index", action: #selector(rebuildClicked), keyEquivalent: "")
        rebuild.target = self
        rebuild.isEnabled = true
        menu.addItem(rebuild)

        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        settings.isEnabled = true
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Everywhere", action: #selector(quitClicked), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openClicked() {
        onOpen?()
    }

    @objc private func rebuildClicked() {
        onRebuild?()
    }

    @objc private func settingsClicked() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let onSettings {
            onSettings()
            return
        }
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private static func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = 16.0 / 598.0
            ctx.translateBy(x: 1 - 214 * scale, y: 17 + 214 * scale)
            ctx.scaleBy(x: scale, y: -scale)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(84)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 622, y: 622))
            ctx.addLine(to: CGPoint(x: 770, y: 770))
            ctx.strokePath()
            ctx.setLineWidth(58)
            ctx.strokeEllipse(in: CGRect(x: 243, y: 243, width: 444, height: 444))
            for (y, width) in [(350.0, 166.0), (445.0, 127.0), (540.0, 166.0)] {
                ctx.addPath(CGPath(roundedRect: CGRect(x: 350, y: y, width: 40, height: 40),
                                   cornerWidth: 10, cornerHeight: 10, transform: nil))
                ctx.addPath(CGPath(roundedRect: CGRect(x: 413, y: y, width: width, height: 40),
                                   cornerWidth: 20, cornerHeight: 20, transform: nil))
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
