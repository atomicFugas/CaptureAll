import AppKit
import ScreenCaptureKit

/// Apple Screenshot–style recording chrome: red stop button + timer.
/// Optional white region border (never full-screen — that crashed AppKit).
@MainActor
final class RecordingGlassBadge {
    var onStop: (() -> Void)?

    private var controlsPanel: KeyablePanel?
    private var borderWindow: KeyablePanel?
    private var timerLabel: NSTextField?
    private var startedAt: Date?
    private var timer: Timer?
    private var activeRegion: RecordingRegion?

    func show(stopHint: String, region: RecordingRegion?) {
        hide()
        activeRegion = region

        // Border only for window/area — never a screen-filling panel.
        if let region, !region.isFullDisplay {
            showBorder(for: region)
        }
        showControls(stopHint: stopHint, near: region)

        startedAt = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        controlsPanel?.orderOut(nil)
        controlsPanel = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        timerLabel = nil
        startedAt = nil
        activeRegion = nil
        onStop = nil
    }

    private func showControls(stopHint: String, near region: RecordingRegion?) {
        let width: CGFloat = 210
        let height: CGFloat = 68
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true

        // Opaque/material chrome — avoid NSGlassEffectView here (unstable under stream load).
        let effect = NSVisualEffectView(frame: root.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        root.addSubview(effect)

        let stop = AppleRecordButton(style: .stop)
        stop.target = self
        stop.action = #selector(stopClicked)
        stop.toolTip = "Stop recording"
        stop.frame = NSRect(x: 14, y: (height - 44) / 2, width: 44, height: 44)
        root.addSubview(stop)

        let time = NSTextField(labelWithString: "00:00")
        time.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        time.textColor = .labelColor
        time.isBezeled = false
        time.drawsBackground = false
        time.frame = NSRect(x: 68, y: 32, width: 120, height: 20)
        timerLabel = time
        root.addSubview(time)

        let hint = NSTextField(labelWithString: stopHint)
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.isBezeled = false
        hint.drawsBackground = false
        hint.frame = NSRect(x: 68, y: 14, width: 130, height: 16)
        root.addSubview(hint)

        let panel = makeChromePanel(size: NSSize(width: width, height: height))
        panel.contentView = root
        panel.setContentSize(NSSize(width: width, height: height))
        positionControls(panel, near: region)
        panel.orderFrontRegardless()
        controlsPanel = panel
    }

    private func positionControls(_ panel: NSPanel, near region: RecordingRegion?) {
        let size = panel.frame.size
        // Pin under the capture frame when we have a window/area border.
        if let region, !region.isFullDisplay {
            let frame = region.screenRect
            var origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY - size.height - 16
            )
            let visible = region.screen.visibleFrame
            if origin.y < visible.minY + 8 {
                origin.y = min(visible.maxY - size.height - 8, frame.maxY + 16)
            }
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
            panel.setFrameOrigin(origin)
            return
        }

        let screen = region?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 28
        ))
    }

    @objc private func stopClicked() {
        onStop?()
    }

    private func showBorder(for region: RecordingRegion) {
        var rect = region.screenRect.insetBy(dx: -2, dy: -2)
        // Clamp to screen; refuse absurdly large frames (full-screen crash path).
        let screenFrame = region.screen.frame
        rect = rect.intersection(screenFrame.insetBy(dx: 1, dy: 1))
        guard rect.width > 40, rect.height > 40 else { return }
        guard rect.width < screenFrame.width - 8, rect.height < screenFrame.height - 8 else {
            // Nearly full screen — skip border.
            return
        }

        let panel = makeChromePanel(size: rect.size)
        panel.setFrame(rect, display: true)
        panel.level = .floating
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = RecordingBorderView(frame: NSRect(origin: .zero, size: rect.size))
        panel.orderFrontRegardless()
        borderWindow = panel
    }

    private func tick() {
        guard let startedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        timerLabel?.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func makeChromePanel(size: NSSize) -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        return panel
    }
}

struct RecordingRegion {
    var screen: NSScreen
    var screenRect: NSRect
    var isFullDisplay: Bool = false

    static func from(target: VideoTarget) -> RecordingRegion? {
        switch target {
        case .display(let display):
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) ?? NSScreen.main else { return nil }
            return RecordingRegion(screen: screen, screenRect: screen.frame, isFullDisplay: true)
        case .window(let window):
            let frame = window.frame
            guard frame.width > 1, frame.height > 1 else { return nil }
            let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main ?? NSScreen.screens[0]
            return RecordingRegion(screen: screen, screenRect: frame, isFullDisplay: false)
        case .area(let display, let rect):
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) ?? NSScreen.main else { return nil }
            let global = NSRect(
                x: screen.frame.minX + rect.origin.x,
                y: screen.frame.minY + rect.origin.y,
                width: rect.width,
                height: rect.height
            )
            return RecordingRegion(screen: screen, screenRect: global, isFullDisplay: false)
        }
    }
}

/// Clean white recording frame — thin stroke + L-corners.
final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r)

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: -1, dy: -1))

        let arm: CGFloat = min(18, min(r.width, r.height) * 0.12)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.square)

        ctx.beginPath()
        ctx.move(to: CGPoint(x: r.minX, y: r.minY + arm))
        ctx.addLine(to: CGPoint(x: r.minX, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.minX + arm, y: r.minY))
        ctx.move(to: CGPoint(x: r.maxX - arm, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + arm))
        ctx.move(to: CGPoint(x: r.minX, y: r.maxY - arm))
        ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        ctx.addLine(to: CGPoint(x: r.minX + arm, y: r.maxY))
        ctx.move(to: CGPoint(x: r.maxX - arm, y: r.maxY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY - arm))
        ctx.strokePath()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

final class AppleRecordButton: NSButton {
    enum Style { case record, stop }

    var style: Style {
        didSet { needsDisplay = true }
    }

    init(style: Style) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor.systemRed.setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        circle.lineWidth = 1.5
        circle.stroke()

        if style == .stop {
            let square = bounds.insetBy(dx: 14, dy: 14)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: square, xRadius: 3.5, yRadius: 3.5).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.75
        super.mouseDown(with: event)
        alphaValue = 1
    }
}
