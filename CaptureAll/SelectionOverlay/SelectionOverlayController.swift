import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

enum SelectionMode: CaseIterable, Equatable {
    case full
    case window
    case area

    var next: SelectionMode {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var previous: SelectionMode {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index - 1 + all.count) % all.count]
    }

    static func from(photoMode: AppSettings.PhotoMode) -> SelectionMode {
        switch photoMode {
        case .full: return .full
        case .window: return .window
        case .area: return .area
        }
    }

    var asPhotoMode: AppSettings.PhotoMode {
        switch self {
        case .full: return .full
        case .window: return .window
        case .area: return .area
        }
    }
}

enum SelectionPurpose {
    case photo
    case record
}

enum SelectionResult {
    case display(SCDisplay)
    case window(SCWindow)
    case area(display: SCDisplay, rectInDisplay: CGRect)
    case cancelled
}

@MainActor
final class SelectionOverlayController {
    private var overlays: [SelectionOverlayWindow] = []
    private var shareable: SCShareableContent?
    private var continuation: CheckedContinuation<SelectionResult, Never>?
    private var mode: SelectionMode = .window
    private var purpose: SelectionPurpose = .photo
    private var allowModeCycling = false
    private var keyMonitor: Any?
    /// Captures keys while another app was frontmost (local monitors need us to be active).
    private var globalKeyMonitor: Any?
    private var hoverObserver: NSObjectProtocol?
    private var isFinishing = false

    /// Windows the user can pick (stable order for arrow cycling).
    private var pickList: [SCWindow] = []
    private var selectedIndex: Int = 0

    var isActive: Bool { continuation != nil || !overlays.isEmpty }

    func pick(mode: SelectionMode, purpose: SelectionPurpose = .photo) async -> SelectionResult {
        await beginPick(mode: mode, purpose: purpose, cycling: false)
    }

    /// Opens the overlay and allows Cmd+Shift+X / Cmd+Shift+C to cycle Full ↔ Window ↔ Area.
    func pickCycling(purpose: SelectionPurpose, startingMode: SelectionMode) async -> SelectionResult {
        await beginPick(mode: startingMode, purpose: purpose, cycling: true)
    }

    private func beginPick(
        mode: SelectionMode,
        purpose: SelectionPurpose,
        cycling: Bool
    ) async -> SelectionResult {
        cancelActive()
        self.mode = mode
        self.purpose = purpose
        self.allowModeCycling = cycling
        isFinishing = false
        guard PermissionGate.ensureScreenRecording() else {
            return .cancelled
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            shareable = content
            SelectionOverlayDisplayCache.store(content)
        } catch {
            ToastHUD.show("Could not list windows.")
            return .cancelled
        }

        ToastHUD.dismiss()
        rebuildPickList()

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlays()
        }
    }

    func cancelActive() {
        finish(.cancelled, force: true)
    }

    private func rebuildPickList() {
        guard let shareable else {
            pickList = []
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        pickList = shareable.windows
            .filter { $0.owningApplication?.processID != ownPID }
            .filter { $0.isOnScreen }
            .filter { $0.frame.width >= 60 && $0.frame.height >= 60 }
            .sorted { a, b in
                if a.windowLayer != b.windowLayer { return a.windowLayer > b.windowLayer }
                if abs(a.frame.maxY - b.frame.maxY) > 20 { return a.frame.maxY > b.frame.maxY }
                return a.frame.minX < b.frame.minX
            }
        selectedIndex = pickList.isEmpty ? 0 : 0
    }

    private func presentOverlays() {
        guard shareable != nil else { return }

        let primary = NSScreen.main
        for screen in NSScreen.screens {
            let overlay = SelectionOverlayWindow(
                screen: screen,
                mode: mode,
                purpose: purpose,
                pickList: pickList,
                selectedID: pickList[safe: selectedIndex]?.windowID,
                spawnAreaFrame: mode == .area && screen === primary,
                allowModeCycling: allowModeCycling,
                onSelectWindow: { [weak self] window in
                    self?.finish(.window(window))
                },
                onSelectArea: { [weak self] display, rect in
                    self?.finish(.area(display: display, rectInDisplay: rect))
                },
                onSelectFull: { [weak self] in
                    self?.confirmFullDisplay()
                }
            )
            overlays.append(overlay)
            overlay.orderFrontRegardless()
        }

        activateOverlayKeyWindow()
        refreshHighlight()
        installKeyMonitors()

        if let hoverObserver {
            NotificationCenter.default.removeObserver(hoverObserver)
        }
        hoverObserver = NotificationCenter.default.addObserver(
            forName: .captureAllWindowHover,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? CGWindowID else { return }
            Task { @MainActor in
                if let index = self.pickList.firstIndex(where: { $0.windowID == id }) {
                    self.selectedIndex = index
                }
            }
        }
    }

    private func activateOverlayKeyWindow() {
        // Hotkeys fire while another app is focused — local key monitors won't see
        // Space/Enter/⌘⇧X until CaptureAll is active and the overlay is key.
        NSApp.activate(ignoringOtherApps: true)
        let main = overlays.first(where: { $0.targetScreen === NSScreen.main }) ?? overlays.first
        main?.makeKeyAndOrderFront(nil)
        if let main {
            main.makeFirstResponder(main.overlayView)
        }
        // Re-assert after the runloop turns (activation is often deferred).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.overlays.isEmpty else { return }
            NSApp.activate(ignoringOtherApps: true)
            let again = self.overlays.first(where: { $0.targetScreen === NSScreen.main }) ?? self.overlays.first
            again?.makeKeyAndOrderFront(nil)
            if let again {
                again.makeFirstResponder(again.overlayView)
            }
        }
    }

    private func installKeyMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, !self.isFinishing else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
        if globalKeyMonitor == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in
                    guard let self, !self.isFinishing, self.continuation != nil else { return }
                    // Local monitor already handles keys once we are the key app.
                    if NSApp.isActive, self.overlays.contains(where: { $0.isKeyWindow }) {
                        return
                    }
                    _ = self.handleKey(event)
                }
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if allowModeCycling,
           mods.contains(.command),
           mods.contains(.shift),
           !mods.contains(.option),
           !mods.contains(.control) {
            // ⌘⇧X previous · ⌘⇧C next
            if event.keyCode == UInt16(kVK_ANSI_X) {
                cycleCaptureMode(forward: false)
                return true
            }
            if event.keyCode == UInt16(kVK_ANSI_C) {
                cycleCaptureMode(forward: true)
                return true
            }
        }

        let shift = event.modifierFlags.contains(.shift)
        let step: CGFloat = shift ? 10 : 1

        switch event.keyCode {
        case 53: // Esc
            finish(.cancelled)
            return true
        case 36, 76, 49: // Return / Enter / Space — same confirm path for photo and record
            switch mode {
            case .full:
                confirmFullDisplay()
                return true
            case .window:
                if let window = pickList[safe: selectedIndex] {
                    finish(.window(window))
                    return true
                }
                return false
            case .area:
                return confirmFrameSelection()
            }
        case 123: // left
            if mode == .full { return true }
            if mode == .area {
                nudgeArea(dx: -step, dy: 0)
                return true
            }
            moveSelection(direction: .left)
            return true
        case 124: // right
            if mode == .full { return true }
            if mode == .area {
                nudgeArea(dx: step, dy: 0)
                return true
            }
            moveSelection(direction: .right)
            return true
        case 125: // down
            if mode == .full { return true }
            if mode == .area {
                nudgeArea(dx: 0, dy: -step)
                return true
            }
            moveSelection(direction: .down)
            return true
        case 126: // up
            if mode == .full { return true }
            if mode == .area {
                nudgeArea(dx: 0, dy: step)
                return true
            }
            moveSelection(direction: .up)
            return true
        case 48: // Tab — cycle windows
            guard mode == .window else { return false }
            cycleSelection(reversed: shift)
            return true
        default:
            return false
        }
    }

    private func cycleCaptureMode(forward: Bool) {
        mode = forward ? mode.next : mode.previous
        tearDownOverlaysOnly()
        presentOverlays()
    }

    private func confirmFullDisplay() {
        guard let shareable else {
            finish(.cancelled)
            return
        }
        let display: SCDisplay?
        if let main = NSScreen.main,
           let number = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            display = shareable.displays.first { $0.displayID == number } ?? shareable.displays.first
        } else {
            display = shareable.displays.first
        }
        if let display {
            finish(.display(display))
        } else {
            finish(.cancelled)
        }
    }

    private func tearDownOverlaysOnly() {
        if let hoverObserver {
            NotificationCenter.default.removeObserver(hoverObserver)
            self.hoverObserver = nil
        }
        let dying = overlays
        overlays = []
        for overlay in dying {
            overlay.overlayView.prepareForTeardown()
            overlay.orderOut(nil)
        }
        DispatchQueue.main.async {
            _ = dying
        }
    }

    private func nudgeArea(dx: CGFloat, dy: CGFloat) {
        _ = nudgeFrame(dx: dx, dy: dy)
    }

    @discardableResult
    private func nudgeFrame(dx: CGFloat, dy: CGFloat) -> Bool {
        for overlay in overlays {
            if overlay.overlayView.nudgeSelection(dx: dx, dy: dy) { return true }
        }
        return false
    }

    @discardableResult
    private func confirmFrameSelection() -> Bool {
        for overlay in overlays {
            if overlay.overlayView.confirmSelection() { return true }
        }
        return false
    }

    private enum Direction { case left, right, up, down }

    private func cycleSelection(reversed: Bool) {
        guard mode == .window, !pickList.isEmpty else { return }
        if reversed {
            selectedIndex = (selectedIndex - 1 + pickList.count) % pickList.count
        } else {
            selectedIndex = (selectedIndex + 1) % pickList.count
        }
        refreshHighlight()
    }

    private func moveSelection(direction: Direction) {
        guard mode == .window, !pickList.isEmpty else { return }
        let current = pickList[safe: selectedIndex] ?? pickList[0]
        let origin = CGPoint(x: current.frame.midX, y: current.frame.midY)

        var bestIndex: Int?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for (index, window) in pickList.enumerated() {
            if index == selectedIndex { continue }
            let c = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let dx = c.x - origin.x
            let dy = c.y - origin.y

            let aligned: Bool
            let primary: CGFloat
            let secondary: CGFloat
            switch direction {
            case .left:
                aligned = dx < -8
                primary = -dx
                secondary = abs(dy)
            case .right:
                aligned = dx > 8
                primary = dx
                secondary = abs(dy)
            case .down:
                aligned = dy < -8
                primary = -dy
                secondary = abs(dx)
            case .up:
                aligned = dy > 8
                primary = dy
                secondary = abs(dx)
            }
            guard aligned else { continue }
            let score = primary + secondary * 2.5
            if score < bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        if let bestIndex {
            selectedIndex = bestIndex
        } else {
            cycleSelection(reversed: direction == .left || direction == .up)
            return
        }
        refreshHighlight()
    }

    private func refreshHighlight() {
        let id = pickList[safe: selectedIndex]?.windowID
        for overlay in overlays {
            overlay.overlayView.setSelectedWindowID(id)
        }
        if let id {
            NotificationCenter.default.post(
                name: .captureAllWindowSelectIndex,
                object: nil,
                userInfo: ["id": id]
            )
        }
    }

    private func finish(_ result: SelectionResult, force: Bool = false) {
        if isFinishing && !force { return }
        if continuation == nil && !force { return }
        isFinishing = true

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let hoverObserver {
            NotificationCenter.default.removeObserver(hoverObserver)
            self.hoverObserver = nil
        }

        let dying = overlays
        overlays = []
        for overlay in dying {
            overlay.overlayView.prepareForTeardown()
            overlay.orderOut(nil)
            // Keep contentView alive until the next turn so AppKit can drain
            // tracking areas / status-bar interactions without UAF.
        }
        // Release windows after the runloop drains (do NOT nil contentView early).
        DispatchQueue.main.async {
            _ = dying
        }

        pickList = []
        shareable = nil
        SelectionOverlayDisplayCache.clear()

        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        }
        isFinishing = false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class SelectionOverlayWindow: NSWindow {
    let overlayView: SelectionOverlayView
    let targetScreen: NSScreen

    init(
        screen: NSScreen,
        mode: SelectionMode,
        purpose: SelectionPurpose,
        pickList: [SCWindow],
        selectedID: CGWindowID?,
        spawnAreaFrame: Bool,
        allowModeCycling: Bool,
        onSelectWindow: @escaping (SCWindow) -> Void,
        onSelectArea: @escaping (SCDisplay, CGRect) -> Void,
        onSelectFull: @escaping () -> Void
    ) {
        self.targetScreen = screen
        self.overlayView = SelectionOverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screen: screen,
            mode: mode,
            purpose: purpose,
            pickList: pickList,
            selectedID: selectedID,
            spawnAreaFrame: spawnAreaFrame,
            allowModeCycling: allowModeCycling,
            onSelectWindow: onSelectWindow,
            onSelectArea: onSelectArea,
            onSelectFull: onSelectFull
        )

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        sharingType = .none
        animationBehavior = .none
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(overlayView)
    }
}

final class SelectionOverlayView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    private enum ResizeEdge: CaseIterable {
        case n, s, e, w, ne, nw, se, sw
    }

    private enum DragSession {
        case move(startMouse: NSPoint, startRect: NSRect)
        case resize(edge: ResizeEdge, startMouse: NSPoint, startRect: NSRect)
        case create(startMouse: NSPoint)
    }

    private let screen: NSScreen
    private let mode: SelectionMode
    private let purpose: SelectionPurpose
    private let allowModeCycling: Bool
    private var pickList: [SCWindow]
    private var selectedID: CGWindowID?
    private var onSelectWindow: ((SCWindow) -> Void)?
    private var onSelectArea: ((SCDisplay, CGRect) -> Void)?
    private var onSelectFull: (() -> Void)?
    private var hintLabel: NSTextField?
    private var tornDown = false

    /// Active capture frame in view coordinates (area mode only).
    private var selectionRect: NSRect?
    private var dragSession: DragSession?
    private var frameCustomized = false
    private let handleSize: CGFloat = 10
    private let minSize: CGFloat = 40

    private var accentColor: NSColor { .controlAccentColor }

    /// Photo and record share the same area-frame UX (no red button).
    private var allowsFrameAdjust: Bool { mode == .area }

    init(
        frame: NSRect,
        screen: NSScreen,
        mode: SelectionMode,
        purpose: SelectionPurpose,
        pickList: [SCWindow],
        selectedID: CGWindowID?,
        spawnAreaFrame: Bool,
        allowModeCycling: Bool,
        onSelectWindow: @escaping (SCWindow) -> Void,
        onSelectArea: @escaping (SCDisplay, CGRect) -> Void,
        onSelectFull: @escaping () -> Void
    ) {
        self.screen = screen
        self.mode = mode
        self.purpose = purpose
        self.allowModeCycling = allowModeCycling
        self.pickList = pickList
        self.selectedID = selectedID
        self.onSelectWindow = onSelectWindow
        self.onSelectArea = onSelectArea
        self.onSelectFull = onSelectFull
        super.init(frame: frame)
        wantsLayer = true

        if mode == .area, spawnAreaFrame {
            let width = min(480, bounds.width * 0.45)
            let height = min(320, bounds.height * 0.4)
            selectionRect = NSRect(
                x: (bounds.width - width) / 2,
                y: (bounds.height - height) / 2,
                width: width,
                height: height
            )
        }

        let cycleHint = allowModeCycling ? " · ⌘⇧X/C change mode" : ""
        let verb = purpose == .record ? "start" : "capture"
        let hint: String
        switch mode {
        case .full:
            hint = "Full Screen · Enter / Space \(verb)\(cycleHint) · Esc cancel"
        case .window:
            hint = "↑↓←→ or Tab · click or Enter / Space \(verb)\(cycleHint) · Esc cancel"
        case .area:
            hint = "Drag outside to draw · edges resize · Enter / Space \(verb)\(cycleHint) · Esc"
        }
        let label = NSTextField(labelWithString: hint)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        label.wantsLayer = true
        label.layer?.cornerRadius = 8
        label.isBezeled = false
        label.sizeToFit()
        let pad: CGFloat = 12
        label.frame = NSRect(
            x: max(8, (bounds.width - label.frame.width) / 2 - pad),
            y: max(8, bounds.height - 56),
            width: label.frame.width + pad * 2,
            height: label.frame.height + 8
        )
        addSubview(label)
        hintLabel = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func prepareForTeardown() {
        tornDown = true
        onSelectWindow = nil
        onSelectArea = nil
        onSelectFull = nil
        pickList = []
        selectedID = nil
        selectionRect = nil
        dragSession = nil
    }

    func setSelectedWindowID(_ id: CGWindowID?) {
        guard !tornDown else { return }
        selectedID = id
        needsDisplay = true
    }

    @discardableResult
    func nudgeSelection(dx: CGFloat, dy: CGFloat) -> Bool {
        guard !tornDown, allowsFrameAdjust, var rect = selectionRect else { return false }
        rect.origin.x += dx
        rect.origin.y += dy
        selectionRect = clampRect(rect)
        frameCustomized = true
        needsDisplay = true
        return true
    }

    @discardableResult
    func confirmSelection() -> Bool {
        guard !tornDown, mode == .area else { return false }
        guard let rect = selectionRect, rect.width >= 4, rect.height >= 4 else { return false }
        guard let display = matchingDisplay() else { return false }
        onSelectArea?(display, CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height))
        return true
    }

    private var selectedWindow: SCWindow? {
        guard let selectedID else { return nil }
        return pickList.first { $0.windowID == selectedID }
    }

    private var windowsOnThisScreen: [SCWindow] {
        pickList.filter { $0.frame.intersects(screen.frame) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !tornDown, let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fill(bounds)

        if mode == .full {
            let inset = bounds.insetBy(dx: 10, dy: 10)
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(inset)
            context.restoreGState()
            context.setStrokeColor(accentColor.cgColor)
            context.setLineWidth(3)
            context.stroke(inset.insetBy(dx: 1.5, dy: 1.5))
            drawTitleChip("Full Screen", above: inset)
            return
        }

        if mode == .window {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            context.setLineWidth(1)
            for window in windowsOnThisScreen {
                let rect = convertFromScreenSpace(window.frame)
                guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }

            if let selected = selectedWindow, selected.frame.intersects(screen.frame) {
                let rect = convertFromScreenSpace(selected.frame)
                context.saveGState()
                context.setBlendMode(.clear)
                context.fill(rect)
                context.restoreGState()

                context.setStrokeColor(accentColor.cgColor)
                context.setLineWidth(3)
                context.stroke(rect.insetBy(dx: 1.5, dy: 1.5))

                let app = selected.owningApplication?.applicationName ?? "Window"
                let title: String
                if let t = selected.title, !t.isEmpty {
                    title = "\(app) — \(t)"
                } else {
                    title = app
                }
                drawTitleChip(title, above: rect)
            }
        }

        if allowsFrameAdjust, let rect = selectionRect {
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(rect)
            context.restoreGState()

            context.setStrokeColor(accentColor.cgColor)
            context.setLineWidth(2.5)
            context.stroke(rect.insetBy(dx: 1.25, dy: 1.25))

            context.setFillColor(accentColor.withAlphaComponent(0.08).cgColor)
            context.fill(rect)

            drawTitleChip("\(Int(rect.width)) × \(Int(rect.height))", above: rect)

            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(accentColor.cgColor)
            context.setLineWidth(1)
            for handle in handleRects(for: rect).values {
                context.fill(handle)
                context.stroke(handle)
            }
        }
    }

    private func drawTitleChip(_ text: String, above rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var chip = NSRect(
            x: rect.minX,
            y: rect.maxY + 6,
            width: size.width + 16,
            height: size.height + 8
        )
        if chip.maxY > bounds.maxY - 8 {
            chip.origin.y = max(8, rect.minY - chip.height - 6)
        }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            in: NSRect(x: chip.minX + 8, y: chip.minY + 4, width: size.width, height: size.height),
            withAttributes: attrs
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        if mode == .full {
            NSCursor.pointingHand.set()
            return
        }
        if allowsFrameAdjust, let rect = selectionRect {
            let point = event.locationInWindow
            if let edge = hitTestEdge(at: point, in: rect) {
                cursorForEdge(edge).set()
            } else if event.modifierFlags.contains(.shift) {
                cursorForEdge(nearestEdge(to: point, in: rect)).set()
            } else if rect.contains(point) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
            return
        }
        if mode == .area {
            NSCursor.crosshair.set()
            return
        }
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !tornDown else { return }
        if mode == .full {
            cursorUpdate(with: event)
            return
        }
        if mode == .area {
            cursorUpdate(with: event)
            return
        }
        // Window mode: hover highlights (same for photo and record).
        let point = convertToScreen(event.locationInWindow)
        guard screen.frame.contains(point) else { return }
        guard let hit = windowAt(point) else { return }
        if hit.windowID != selectedID {
            selectedID = hit.windowID
            needsDisplay = true
            NotificationCenter.default.post(
                name: .captureAllWindowHover,
                object: nil,
                userInfo: ["id": hit.windowID]
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !tornDown else { return }
        let point = event.locationInWindow

        if mode == .full {
            onSelectFull?()
            return
        }

        // Window: click confirms immediately (photo and record).
        if mode == .window {
            let screenPoint = convertToScreen(point)
            if let window = windowAt(screenPoint) {
                onSelectWindow?(window)
            }
            return
        }

        // Area: draw / move / resize frame.
        guard allowsFrameAdjust else { return }

        if selectionRect == nil {
            let width = min(480, bounds.width * 0.45)
            let height = min(320, bounds.height * 0.4)
            selectionRect = clampRect(NSRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            ))
            needsDisplay = true
        }

        guard let rect = selectionRect else { return }
        let shift = event.modifierFlags.contains(.shift)

        if shift {
            let edge = hitTestEdge(at: point, in: rect) ?? nearestEdge(to: point, in: rect)
            dragSession = .resize(edge: edge, startMouse: point, startRect: rect)
            cursorForEdge(edge).set()
            return
        }

        if let edge = hitTestEdge(at: point, in: rect) {
            dragSession = .resize(edge: edge, startMouse: point, startRect: rect)
            cursorForEdge(edge).set()
            return
        }

        if rect.contains(point) {
            dragSession = .move(startMouse: point, startRect: rect)
            NSCursor.closedHand.set()
            return
        }

        // Click-drag outside the frame draws a new custom area.
        frameCustomized = true
        dragSession = .create(startMouse: point)
        selectionRect = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        needsDisplay = true
        NSCursor.crosshair.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !tornDown, allowsFrameAdjust, let session = dragSession else { return }
        let point = event.locationInWindow
        frameCustomized = true

        switch session {
        case .move(let startMouse, let startRect):
            var next = startRect
            next.origin.x += point.x - startMouse.x
            next.origin.y += point.y - startMouse.y
            selectionRect = clampRect(next)
        case .resize(let edge, let startMouse, let startRect):
            let dx = point.x - startMouse.x
            let dy = point.y - startMouse.y
            selectionRect = clampRect(resized(startRect, edge: edge, dx: dx, dy: dy))
        case .create(let startMouse):
            let x = min(startMouse.x, point.x)
            let y = min(startMouse.y, point.y)
            let w = max(1, abs(point.x - startMouse.x))
            let h = max(1, abs(point.y - startMouse.y))
            selectionRect = clampRect(NSRect(x: x, y: y, width: w, height: h))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !tornDown, allowsFrameAdjust else { return }
        dragSession = nil
        cursorUpdate(with: event)
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        cursorUpdate(with: event)
    }

    override func viewDidMoveToWindow() {
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        updateTrackingAreas()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hoverNote(_:)),
            name: .captureAllWindowHover,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectNote(_:)),
            name: .captureAllWindowSelectIndex,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func hoverNote(_ note: Notification) {
        guard !tornDown, let id = note.userInfo?["id"] as? CGWindowID else { return }
        if selectedID != id {
            selectedID = id
            needsDisplay = true
        }
    }

    @objc private func selectNote(_ note: Notification) {
        guard !tornDown, let id = note.userInfo?["id"] as? CGWindowID else { return }
        selectedID = id
        needsDisplay = true
    }

    private func matchingDisplay() -> SCDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return SelectionOverlayDisplayCache.display(for: number)
    }

    private func windowAt(_ screenPoint: CGPoint) -> SCWindow? {
        windowsOnThisScreen
            .filter { $0.frame.contains(screenPoint) }
            .sorted { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
            .first
    }

    private func convertToScreen(_ windowPoint: NSPoint) -> CGPoint {
        guard let window else { return windowPoint }
        return window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
    }

    private func convertFromScreenSpace(_ screenRect: CGRect) -> NSRect {
        guard let window else { return .zero }
        let bl = window.convertFromScreen(NSRect(origin: screenRect.origin, size: .zero)).origin
        return NSRect(x: bl.x, y: bl.y, width: screenRect.width, height: screenRect.height)
    }

    private func clampRect(_ rect: NSRect) -> NSRect {
        var r = rect
        r.size.width = max(minSize, r.size.width)
        r.size.height = max(minSize, r.size.height)
        r.origin.x = min(max(0, r.origin.x), max(0, bounds.width - r.size.width))
        r.origin.y = min(max(0, r.origin.y), max(0, bounds.height - r.size.height))
        return r
    }

    private func handleRects(for rect: NSRect) -> [ResizeEdge: NSRect] {
        let s = handleSize
        let midX = rect.midX - s / 2
        let midY = rect.midY - s / 2
        return [
            .nw: NSRect(x: rect.minX - s / 2, y: rect.maxY - s / 2, width: s, height: s),
            .n: NSRect(x: midX, y: rect.maxY - s / 2, width: s, height: s),
            .ne: NSRect(x: rect.maxX - s / 2, y: rect.maxY - s / 2, width: s, height: s),
            .e: NSRect(x: rect.maxX - s / 2, y: midY, width: s, height: s),
            .se: NSRect(x: rect.maxX - s / 2, y: rect.minY - s / 2, width: s, height: s),
            .s: NSRect(x: midX, y: rect.minY - s / 2, width: s, height: s),
            .sw: NSRect(x: rect.minX - s / 2, y: rect.minY - s / 2, width: s, height: s),
            .w: NSRect(x: rect.minX - s / 2, y: midY, width: s, height: s)
        ]
    }

    private func hitTestEdge(at point: NSPoint, in rect: NSRect) -> ResizeEdge? {
        let handles = handleRects(for: rect)
        // Prefer corners, then edges.
        let order: [ResizeEdge] = [.nw, .ne, .se, .sw, .n, .e, .s, .w]
        for edge in order {
            if let handle = handles[edge], handle.insetBy(dx: -2, dy: -2).contains(point) {
                return edge
            }
        }
        // Also hit near edges without requiring exact handle.
        let inset: CGFloat = 8
        let nearN = abs(point.y - rect.maxY) <= inset && point.x >= rect.minX - inset && point.x <= rect.maxX + inset
        let nearS = abs(point.y - rect.minY) <= inset && point.x >= rect.minX - inset && point.x <= rect.maxX + inset
        let nearE = abs(point.x - rect.maxX) <= inset && point.y >= rect.minY - inset && point.y <= rect.maxY + inset
        let nearW = abs(point.x - rect.minX) <= inset && point.y >= rect.minY - inset && point.y <= rect.maxY + inset
        switch (nearN, nearS, nearE, nearW) {
        case (true, false, true, false): return .ne
        case (true, false, false, true): return .nw
        case (false, true, true, false): return .se
        case (false, true, false, true): return .sw
        case (true, false, false, false): return .n
        case (false, true, false, false): return .s
        case (false, false, true, false): return .e
        case (false, false, false, true): return .w
        default: return nil
        }
    }

    private func nearestEdge(to point: NSPoint, in rect: NSRect) -> ResizeEdge {
        let distances: [(ResizeEdge, CGFloat)] = [
            (.n, abs(point.y - rect.maxY)),
            (.s, abs(point.y - rect.minY)),
            (.e, abs(point.x - rect.maxX)),
            (.w, abs(point.x - rect.minX)),
            (.ne, hypot(point.x - rect.maxX, point.y - rect.maxY)),
            (.nw, hypot(point.x - rect.minX, point.y - rect.maxY)),
            (.se, hypot(point.x - rect.maxX, point.y - rect.minY)),
            (.sw, hypot(point.x - rect.minX, point.y - rect.minY))
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .se
    }

    private func resized(_ rect: NSRect, edge: ResizeEdge, dx: CGFloat, dy: CGFloat) -> NSRect {
        var r = rect
        switch edge {
        case .n:
            // Keep bottom edge fixed; drag top.
            r.origin.y = rect.minY
            r.size.height = rect.height + dy
        case .s:
            r.origin.y = rect.minY + dy
            r.size.height = rect.height - dy
        case .e:
            r.size.width = rect.width + dx
        case .w:
            r.origin.x = rect.minX + dx
            r.size.width = rect.width - dx
        case .ne:
            r.size.width = rect.width + dx
            r.size.height = rect.height + dy
            r.origin.y = rect.minY
        case .nw:
            r.origin.x = rect.minX + dx
            r.size.width = rect.width - dx
            r.size.height = rect.height + dy
            r.origin.y = rect.minY
        case .se:
            r.size.width = rect.width + dx
            r.origin.y = rect.minY + dy
            r.size.height = rect.height - dy
        case .sw:
            r.origin.x = rect.minX + dx
            r.size.width = rect.width - dx
            r.origin.y = rect.minY + dy
            r.size.height = rect.height - dy
        }
        if r.size.width < minSize {
            if edge == .w || edge == .nw || edge == .sw {
                r.origin.x = r.maxX - minSize
            }
            r.size.width = minSize
        }
        if r.size.height < minSize {
            if edge == .s || edge == .se || edge == .sw {
                r.origin.y = r.maxY - minSize
            }
            r.size.height = minSize
        }
        return r
    }

    private func cursorForEdge(_ edge: ResizeEdge) -> NSCursor {
        switch edge {
        case .n, .s: return NSCursor.resizeUpDown
        case .e, .w: return NSCursor.resizeLeftRight
        case .ne, .sw: return NSCursor.crosshair
        case .nw, .se: return NSCursor.crosshair
        }
    }
}

enum SelectionOverlayDisplayCache {
    private static var map: [CGDirectDisplayID: SCDisplay] = [:]

    static func store(_ content: SCShareableContent) {
        var next: [CGDirectDisplayID: SCDisplay] = [:]
        for display in content.displays {
            next[display.displayID] = display
        }
        map = next
    }

    static func display(for id: CGDirectDisplayID) -> SCDisplay? {
        map[id]
    }

    static func clear() {
        map = [:]
    }
}

extension Notification.Name {
    static let captureAllWindowHover = Notification.Name("captureAllWindowHover")
    static let captureAllWindowSelectIndex = Notification.Name("captureAllWindowSelectIndex")
}
