import AppKit

/// Borderless floating NSPanel with glass / material chrome.
final class GlassPanelController: NSWindowController {
    private(set) var contentHost: NSView

    init(content: NSView, size: NSSize, title: String = "") {
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: body.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10)
        ])

        let glassRoot = GlassContainerHosting.makeGlassContainer(content: body)
        glassRoot.translatesAutoresizingMaskIntoConstraints = false
        self.contentHost = glassRoot

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = title
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        // Keep CaptureAll chrome out of ScreenCaptureKit / system screenshots.
        panel.sharingType = .none

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(glassRoot)
        NSLayoutConstraint.activate([
            glassRoot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glassRoot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glassRoot.topAnchor.constraint(equalTo: root.topAnchor),
            glassRoot.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        panel.contentView = root
        panel.setContentSize(size)

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentCentered(on screen: NSScreen? = nil) {
        guard let window else { return }
        let target = screen ?? NSScreen.main
        if let frame = target?.visibleFrame {
            let origin = NSPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2
            )
            window.setFrameOrigin(origin)
        }
        window.alphaValue = 1
        // `.nonactivatingPanel` keeps the frontmost app’s menu bar. Do not call
        // `NSApp.activate` — that flashes CaptureAll’s app menu in the top bar.
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Resize while keeping the top edge fixed (avoids recenter jumps on drill).
    func setContentSizeKeepingTop(_ size: NSSize, animated: Bool = false) {
        guard let window else { return }
        let oldFrame = window.frame
        let newOrigin = NSPoint(x: oldFrame.origin.x, y: oldFrame.maxY - size.height)
        let newFrame = NSRect(origin: newOrigin, size: size)
        // Always instant — animated height morph looked like a crushing effect.
        _ = animated
        window.setFrame(newFrame, display: true)
    }

    func dismiss() {
        window?.orderOut(nil)
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
