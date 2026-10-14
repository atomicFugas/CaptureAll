import AppKit

/// Clickable chip pinned to the top-right of the menu bar area.
/// Used when `NSStatusItem` fails to host under Control Center (common when
/// launching debug builds / agent apps on macOS 26).
@MainActor
final class MenuBarFallbackPill {
    static let shared = MenuBarFallbackPill()

    private var panel: NSPanel?
    private weak var target: StatusItemController?

    private init() {}

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    var buttonView: NSView? { panel?.contentView }

    func show(target: StatusItemController) {
        self.target = target
        hide()

        let button = NSButton(title: "CA", target: target, action: #selector(StatusItemController.fallbackPillClicked(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .bold)
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.systemBlue.cgColor
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "CaptureAll — Screenshot, Recording, Settings"
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        host.wantsLayer = true
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
            button.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -2),
            button.topAnchor.constraint(equalTo: host.topAnchor, constant: 1),
            button.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -1)
        ])

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 36, height: 22),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.contentView = host
        panel.setContentSize(NSSize(width: 36, height: 22))

        if let screen = NSScreen.main {
            // Top-right, just left of Control Center / clock cluster.
            let f = screen.frame
            let origin = NSPoint(x: f.maxX - 220, y: f.maxY - 22)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        NSLog("CaptureAll: fallback menu-bar pill shown at %@", NSStringFromRect(panel.frame))
    }
}
