import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files received from promise drags last run; nothing refers to them now.
        try? FileManager.default.removeItem(at: DropPanel.dropStaging)
        Presets.seedFileIfMissing()
        Recipes.seedFileIfMissing()
        WatchFolders.shared.load()
        WatchFolders.shared.start()
        DragMonitor.shared.start()
        // Opt-in, once a day at most, and only ever talks to GitHub.
        Updater.shared.checkInBackgroundIfDue()
        Hotkey.register { DropPanel.shared.summon() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
        }

        statusItem.menu = makeMenu()
    }

    /// Every item is handled here, `quit` included. Routing quit straight to
    /// `NSApplication.terminate(_:)` and then pointing the whole menu at this
    /// object silently disables it — AppKit greys out any item whose target
    /// does not respond to its action, and an `NSObject` does not implement
    /// `terminate`. `SelfTest` now asserts every item can actually fire.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Wheel  \(Hotkey.label)", action: #selector(openDropZone), keyEquivalent: "")
        menu.addItem(withTitle: "Convert File…", action: #selector(chooseAndConvert), keyEquivalent: "o")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(withTitle: "Daisy \(ver)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Quit Daisy", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openDropZone() { DropPanel.shared.toggle() }
    @objc private func chooseAndConvert() { DropPanel.shared.summonAndChoose() }
    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc private func checkForUpdates() { SettingsWindow.shared.showAndCheck() }

    /// Finder → Services → "Convert with Daisy…"
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty else { return }
        DropPanel.shared.load(urls: urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DropPanel.shared.summon()
        return true
    }

    /// The flower reduced to a monochrome template, so the menu bar tints it for
    /// light and dark automatically. Five petals rather than the app icon's
    /// eight: at 18pt the eight-petal version closes into a cog, and the centre
    /// is punched out rather than drawn so the shape still reads as a flower.
    private static func menuBarIcon() -> NSImage {
        let d: CGFloat = 18
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        let c = CGPoint(x: d / 2, y: d / 2)
        let petals = 5
        let step = (CGFloat.pi * 2) / CGFloat(petals)
        let petalR = d * 0.185            // radius of one round petal
        let ring = d * 0.255              // centre of the flower to centre of a petal

        NSColor.black.setFill()
        for i in 0..<petals {
            let a = CGFloat.pi / 2 - CGFloat(i) * step
            let p = CGPoint(x: c.x + cos(a) * ring, y: c.y + sin(a) * ring)
            NSBezierPath(ovalIn: CGRect(x: p.x - petalR, y: p.y - petalR,
                                        width: petalR * 2, height: petalR * 2)).fill()
        }
        let hubR = d * 0.155
        let hub = NSBezierPath(ovalIn: CGRect(x: c.x - hubR, y: c.y - hubR,
                                              width: hubR * 2, height: hubR * 2))
        NSGraphicsContext.current?.compositingOperation = .clear
        hub.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}
