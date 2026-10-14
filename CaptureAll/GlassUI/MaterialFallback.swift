import AppKit

enum MaterialFallback {
    static var prefersOpaqueBackground: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static func makeVisualEffect(material: NSVisualEffectView.Material = .hudWindow) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = prefersOpaqueBackground ? .contentBackground : material
        view.blendingMode = prefersOpaqueBackground ? .withinWindow : .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        return view
    }
}
