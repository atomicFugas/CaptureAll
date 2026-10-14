import AppKit

@MainActor
enum ToastHUD {
    private static var panel: GlassPanelController?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, duration: TimeInterval = 2.0) {
        hideWork?.cancel()
        dismiss()

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center

        let controller = GlassPanelController(content: label, size: NSSize(width: 280, height: 48))
        // Keep toast out of the way of captures — near menu bar, not center.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            controller.window?.setFrameOrigin(NSPoint(
                x: frame.midX - 140,
                y: frame.maxY - 72
            ))
            controller.window?.sharingType = .none
            controller.window?.orderFrontRegardless()
        } else {
            controller.presentCentered()
        }
        panel = controller

        let work = DispatchWorkItem {
            dismiss()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    static func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        panel?.window?.sharingType = .none
        panel?.dismiss()
        panel = nil
    }
}
