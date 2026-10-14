import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let guideDefaultsKey = "didShowMenuBarGuide"
    private static let blockedGuideKey = "didShowMenuBarBlockedGuide"
    private static let debugLogPath = "/tmp/captureall-status.log"
    private static let autosaveName = "CaptureAll.StatusItem.mb2"
    private static let itemLength: CGFloat = NSStatusItem.variableLength

    /// System Settings → Menu Bar (macOS 26 StatusKit allow-list).
    private static let menuBarSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension?MenuBar"
    )!

    private var statusItem: NSStatusItem?
    private var visibilityObservers: [NSObjectProtocol] = []
    private lazy var controlMenu: NSMenu = {
        let menu = NSMenu(title: "CaptureAll")
        menu.delegate = self
        return menu
    }()

    var isRecording: (() -> Bool)?
    var onScreenshot: (() -> Void)?
    var onRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onMenuWillOpen: (() -> Void)?

    deinit {
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static func debugLog(_ message: String) {
        let line = "\(Date()): \(message)\n"
        NSLog("CaptureAll: %@", message)
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: debugLogPath)
        if FileManager.default.fileExists(atPath: debugLogPath) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }

    func install() {
        Self.debugLog("install() begin bundle=\(Bundle.main.bundleIdentifier ?? "?") path=\(Bundle.main.bundlePath)")
        MenuBarFallbackPill.shared.hide()
        removeExistingItem()
        clearStalePlacementPrefs()
        createStatusItem()
        installVisibilityObservers()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.ensureVisible()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            self.ensureVisible()
            if self.isStatusItemVisiblyHosted() {
                Self.debugLog("REAL status item hosted on-screen")
                self.showMenuBarGuideIfNeeded()
            } else {
                Self.debugLog("StatusKit likely blocking — prompting Menu Bar settings")
                self.presentBlockedGuidance()
            }
        }
    }

    func ensureVisible() {
        if statusItem == nil {
            createStatusItem()
            return
        }
        guard let statusItem else { return }
        statusItem.isVisible = true
        if let button = statusItem.button {
            configureButton(button)
            let screen = button.window?.screen
            let frame = button.window?.frame ?? .zero
            Self.debugLog(
                "ensureVisible visible=\(statusItem.isVisible) screen=\(screen != nil) frame=\(NSStringFromRect(frame))"
            )
        } else {
            removeExistingItem()
            createStatusItem()
        }
    }

    /// Pop the control menu programmatically (reopen / second instance).
    func popControlMenu() {
        rebuildMenu()
        guard let button = statusItem?.button else { return }
        statusItem?.menu = controlMenu
        button.performClick(nil)
    }

    /// True when Control Center has composited our item into the real menu bar.
    func isStatusItemVisiblyHosted() -> Bool {
        guard let button = statusItem?.button, let window = button.window else {
            Self.debugLog("hosted: no window")
            return false
        }
        if window.screen == nil {
            Self.debugLog("hosted: window.screen == nil (blocked signature)")
            return false
        }
        if window.frame.origin.y < 0 {
            Self.debugLog("hosted: frame.y < 0 (parked off-screen)")
            return false
        }
        let windowNumber = window.windowNumber
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let our = window.frame
        for entry in info {
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            guard layer >= 20 else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (bounds["X"] as? NSNumber)?.doubleValue ?? -1
            let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? -1
            let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            if abs(x - our.origin.x) < 8, abs(w - our.size.width) < 12, h <= 36, y < 40 {
                Self.debugLog("hosted: matched CC window owner=\(owner) x=\(x) w=\(w)")
                return true
            }
            let num = entry[kCGWindowNumber as String] as? Int ?? -1
            if num == windowNumber {
                Self.debugLog("hosted: windowNumber match")
                return true
            }
        }
        Self.debugLog("hosted: no on-screen menu-bar match for frame \(NSStringFromRect(our))")
        return false
    }

    static func openMenuBarSettings() {
        NSWorkspace.shared.open(menuBarSettingsURL)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
    }

    private func rebuildMenu() {
        controlMenu.removeAllItems()
        let hotkeys = SettingsStore.shared.settings.hotkeys
        let recording = isRecording?() ?? false

        let shot = NSMenuItem(
            title: "Screenshot",
            action: #selector(screenshot),
            keyEquivalent: ""
        )
        shot.target = self
        applyKeyEquivalent(shot, storage: hotkeys.screenshot)
        controlMenu.addItem(shot)

        if recording {
            let stop = NSMenuItem(
                title: "Stop Recording",
                action: #selector(stopRecording),
                keyEquivalent: ""
            )
            stop.target = self
            applyKeyEquivalent(stop, storage: hotkeys.recording)
            controlMenu.addItem(stop)
        } else {
            let rec = NSMenuItem(
                title: "Recording",
                action: #selector(startRecording),
                keyEquivalent: ""
            )
            rec.target = self
            applyKeyEquivalent(rec, storage: hotkeys.recording)
            controlMenu.addItem(rec)
        }

        controlMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        controlMenu.addItem(settings)

        let menuBar = NSMenuItem(
            title: "Menu Bar Settings…",
            action: #selector(openSystemMenuBarSettings),
            keyEquivalent: ""
        )
        menuBar.target = self
        controlMenu.addItem(menuBar)

        controlMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit CaptureAll",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        controlMenu.addItem(quit)
    }

    private func applyKeyEquivalent(_ item: NSMenuItem, storage: String) {
        guard let chord = KeyChord.parse(storage) else { return }
        let key = chord.menuKeyEquivalent
        guard !key.isEmpty else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = chord.menuKeyEquivalentModifierMask
    }

    private func presentBlockedGuidance() {
        let defaults = UserDefaults.standard
        ToastHUD.show("Enable CaptureAll in System Settings → Menu Bar", duration: 4.5)
        if defaults.bool(forKey: Self.blockedGuideKey) == false {
            defaults.set(true, forKey: Self.blockedGuideKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Self.openMenuBarSettings()
            }
        }
        MenuBarFallbackPill.shared.hide()
    }

    private func clearStalePlacementPrefs() {
        let defaults = UserDefaults.standard
        for key in Array(defaults.dictionaryRepresentation().keys)
        where key.contains("NSStatusItem") && key.contains("CaptureAll") {
            defaults.removeObject(forKey: key)
            Self.debugLog("cleared pref \(key)")
        }
    }

    private func removeExistingItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: Self.itemLength)
        item.autosaveName = Self.autosaveName
        item.isVisible = true
        rebuildMenu()
        item.menu = controlMenu

        guard let button = item.button else {
            Self.debugLog("ERROR: button nil")
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        configureButton(button)
        statusItem = item
        Self.debugLog(
            "created autosave=\(Self.autosaveName) visible=\(item.isVisible) screen=\(button.window?.screen != nil)"
        )
    }

    private func configureButton(_ button: NSStatusBarButton) {
        let icon = Self.cameraTemplate()
        button.image = icon
        button.image?.isTemplate = true
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = "CaptureAll — Screenshot, Recording, Settings"
        button.appearsDisabled = false
        button.isEnabled = true
    }

    private func installVisibilityObservers() {
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        visibilityObservers.removeAll()
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.ensureVisible() }
        }
        visibilityObservers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: handler)
        )
        visibilityObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler)
        )
    }

    private func showMenuBarGuideIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.guideDefaultsKey) == false else { return }
        defaults.set(true, forKey: Self.guideDefaultsKey)
        ToastHUD.show("CaptureAll is in the menu bar", duration: 3.0)
    }

    private static func cameraTemplate() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "CaptureAll")?
            .withSymbolConfiguration(config) {
            let img = symbol.copy() as! NSImage
            img.isTemplate = true
            return img
        }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 4), xRadius: 2, yRadius: 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc func fallbackPillClicked(_ sender: Any?) {
        popControlMenu()
    }

    @objc private func screenshot() { onScreenshot?() }
    @objc private func startRecording() { onRecording?() }
    @objc private func stopRecording() { onStopRecording?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openSystemMenuBarSettings() { Self.openMenuBarSettings() }
    @objc private func quit() { onQuit?() }
}
