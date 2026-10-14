import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private var escMonitor: Any?

    init() {
        let hosting = NSHostingView(rootView: SettingsRootView())
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "CaptureAll Settings"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.sharingType = .none
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = hosting
        panel.setContentSize(NSSize(width: 600, height: 460))
        panel.center()
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else {
            NSLog("CaptureAll: settings window nil")
            return
        }
        if window.frame.width < 100 || window.frame.height < 100 {
            window.setContentSize(NSSize(width: 600, height: 460))
        }
        window.alphaValue = 1
        window.center()
        window.orderFrontRegardless()
        window.makeKey()
        installEscMonitor()
        NSLog("CaptureAll: settings shown isVisible=%d frame=%@", window.isVisible, NSStringFromRect(window.frame))
    }

    private func installEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.closePanel()
            return nil
        }
    }

    private func closePanel() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        window?.orderOut(nil)
    }
}
