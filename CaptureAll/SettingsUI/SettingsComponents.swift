import AppKit
import SwiftUI

enum SettingsBinding {
    @MainActor
    static func bool(
        _ keyPath: WritableKeyPath<AppSettings, Bool>,
        store: SettingsStore = .shared
    ) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } }
        )
    }

    @MainActor
    static func value<T>(
        _ keyPath: WritableKeyPath<AppSettings, T>,
        store: SettingsStore = .shared
    ) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } }
        )
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var subtitle: String? = nil

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

struct SettingsPickerRow<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var content: () -> Content

    var body: some View {
        Picker(title, selection: $selection, content: content)
    }
}

struct SettingsFolderRow: View {
    let title: String
    let path: String
    var isEnabled: Bool = true
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                Button("Choose…", action: onChoose)
                    .disabled(!isEnabled)
            }
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

struct SettingsPermissionRow: View {
    let title: String
    let status: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(status)
                    .foregroundStyle(.secondary)
                Button(actionTitle, action: action)
            }
        }
    }
}

struct SettingsHotkeyRow: View {
    let title: String
    @Binding var storage: String
    var onChanged: (() -> Void)? = nil
    @State private var listening = false

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Text(KeyChord.parse(storage)?.displayString ?? storage)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(listening ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    listening = true
                    HotkeyCenter.shared.pauseDelivery(true)
                }
                .background(
                    KeyCaptureRepresentable(isListening: $listening) { chord in
                        storage = chord.storageString
                        listening = false
                        HotkeyCenter.shared.pauseDelivery(false)
                        onChanged?()
                    }
                )
        }
    }
}

struct KeyCaptureRepresentable: NSViewRepresentable {
    @Binding var isListening: Bool
    var onChord: (KeyChord) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onChord = onChord
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.isListening = isListening
        nsView.onChord = onChord
        if isListening {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

final class KeyCaptureView: NSView {
    var isListening = false
    var onChord: ((KeyChord) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isListening else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            isListening = false
            return
        }
        if let chord = KeyChord.from(event: event), chord.carbonModifiers != 0 {
            onChord?(chord)
        }
    }
}

enum SettingsFolderPicker {
    @MainActor
    static func chooseDirectory(onPick: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }
}
