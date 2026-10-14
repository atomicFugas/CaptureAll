import AppKit

enum GlassContainerHosting {
    static let cornerRadius: CGFloat = 14
    static let rowCornerRadius: CGFloat = 10
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 6
    static let contentInset: CGFloat = 10
    static let panelWidth: CGFloat = 300

    /// Root chrome for floating panels. Always returns a view that fills its superview.
    static func makeGlassRoot(content: NSView, cornerRadius: CGFloat = cornerRadius) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false

        if MaterialFallback.prefersOpaqueBackground {
            return wrapFilling(content: content, background: opaqueBackground(cornerRadius: cornerRadius))
        }

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = content
            return glass
        }

        let effect = MaterialFallback.makeVisualEffect()
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        return effect
    }

    static func makeGlassContainer(content: NSView, spacing: CGFloat = 8) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false

        if MaterialFallback.prefersOpaqueBackground {
            return wrapFilling(content: content, background: opaqueBackground(cornerRadius: cornerRadius))
        }

        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = spacing
            container.translatesAutoresizingMaskIntoConstraints = false
            container.contentView = content
            return container
        }

        return makeGlassRoot(content: content)
    }

    static func makeGlassRow(content: NSView, selected: Bool = false) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false

        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: padded.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -8)
        ])

        if MaterialFallback.prefersOpaqueBackground {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = rowCornerRadius
            applySelection(to: box, selected: selected)
            return wrapFilling(content: padded, background: box)
        }

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = rowCornerRadius
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = padded
            applySelection(to: glass, selected: selected)
            return glass
        }

        let effect = MaterialFallback.makeVisualEffect(material: selected ? .selection : .menu)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = rowCornerRadius
        applySelection(to: effect, selected: selected)
        return wrapFilling(content: padded, background: effect)
    }

    /// Mutate an existing row chrome in place (no view tree rebuild).
    static func applySelection(to view: NSView, selected: Bool) {
        if MaterialFallback.prefersOpaqueBackground {
            view.wantsLayer = true
            view.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
                : NSColor.controlBackgroundColor.cgColor
            return
        }

        if #available(macOS 26.0, *) {
            if let glass = view as? NSGlassEffectView {
                glass.style = selected ? .clear : .regular
                glass.tintColor = selected
                    ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                    : nil
                return
            }
        }

        if let effect = view as? NSVisualEffectView {
            effect.material = selected ? .selection : .menu
        }
    }

    static func panelHeight(forRowCount count: Int) -> CGFloat {
        let rows = CGFloat(max(1, count))
        // Outer body inset (10+10) + palette inset (10+10) + rows + spacing between rows.
        let inner = (contentInset * 2) + (rows * rowHeight) + (max(0, rows - 1) * rowSpacing)
        return max(80, (contentInset * 2) + inner)
    }

    private static func opaqueBackground(cornerRadius: CGFloat) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = cornerRadius
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        return box
    }

    private static func wrapFilling(content: NSView, background: NSView) -> NSView {
        background.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        if content.superview !== background {
            background.addSubview(content)
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        return background
    }
}
