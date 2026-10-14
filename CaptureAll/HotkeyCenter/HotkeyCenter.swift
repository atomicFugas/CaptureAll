import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

enum HotkeyAction: String, CaseIterable {
    case screenshot
    case recording
}

private let hotkeyLog = Logger(subsystem: "app.captureall.CaptureAll", category: "HotkeyCenter")

/// Carbon hotkey callback — must be `@convention(c)` (no Swift closure captures).
private func captureAllHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async {
        HotkeyCenter.shared.handleHotKeyFromCarbon(id: id)
    }
    return noErr
}

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onAction: ((HotkeyAction) -> Void)?
    private(set) var conflictWarning: String?
    private var registrations: [HotkeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var paused = false
    /// Fallback when Carbon registration fails: global NSEvent monitor (needs Accessibility on some OS versions).
    private var fallbackMonitor: Any?

    private init() {}

    func start() {
        installHandlerIfNeeded()
        reregisterFromSettings()
    }

    func pauseDelivery(_ pause: Bool) {
        paused = pause
    }

    func reregisterFromSettings() {
        let settings = SettingsStore.shared.settings.hotkeys
        unregisterAll()
        conflictWarning = nil

        var seen: [String: HotkeyAction] = [:]
        let pairs: [(HotkeyAction, String)] = [
            (.screenshot, settings.screenshot),
            (.recording, settings.recording)
        ]

        var carbonOK = true
        for (action, storage) in pairs {
            guard let chord = KeyChord.parse(storage) else {
                conflictWarning = "Invalid shortcut for \(action.rawValue)."
                carbonOK = false
                continue
            }
            if let other = seen[chord.storageString] {
                conflictWarning = "Shortcut \(chord.displayString) conflicts between \(other.rawValue) and \(action.rawValue)."
                carbonOK = false
                continue
            }
            seen[chord.storageString] = action
            if !register(action: action, chord: chord) {
                carbonOK = false
            }
        }

        let chordPairs: [(HotkeyAction, KeyChord)] = pairs.compactMap { action, storage in
            guard let chord = KeyChord.parse(storage) else { return nil }
            return (action, chord)
        }
        if !carbonOK || registrations.count < chordPairs.count {
            installFallbackMonitor(chords: chordPairs)
        }
    }

    private var lastFire: Date = .distantPast

    func handleHotKeyFromCarbon(id: UInt32) {
        guard !paused else { return }
        let now = Date()
        if now.timeIntervalSince(lastFire) < 0.25 { return }
        lastFire = now
        let action: HotkeyAction = id == 1 ? .screenshot : .recording
        hotkeyLog.info("Hotkey id=\(id, privacy: .public)")
        onAction?(action)
    }

    @discardableResult
    private func register(action: HotkeyAction, chord: KeyChord) -> Bool {
        var hotKeyRef: EventHotKeyRef?
        let id = EventHotKeyID(
            signature: OSType(0x43414C4C), // 'CALL'
            id: UInt32(action == .screenshot ? 1 : 2)
        )
        let status = RegisterEventHotKey(
            chord.keyCode,
            chord.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            registrations[action] = hotKeyRef
            hotkeyLog.info("Registered \(chord.displayString, privacy: .public) for \(action.rawValue, privacy: .public)")
            return true
        }
        conflictWarning = "Could not register \(chord.displayString). Choose a new shortcut if it conflicts with another."
        hotkeyLog.error("RegisterEventHotKey failed status=\(status) for \(chord.displayString, privacy: .public)")
        return false
    }

    private func unregisterAll() {
        for (_, ref) in registrations {
            UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            captureAllHotKeyHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        if status != noErr {
            hotkeyLog.error("InstallEventHandler failed \(status)")
            var retryType = eventType
            let retry = InstallEventHandler(
                GetEventDispatcherTarget(),
                captureAllHotKeyHandler,
                1,
                &retryType,
                nil,
                &handlerRef
            )
            if retry != noErr {
                hotkeyLog.error("InstallEventHandler dispatcher fallback failed \(retry)")
            }
        }
    }

    private func installFallbackMonitor(chords: [(HotkeyAction, KeyChord)]) {
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
        let map = Dictionary(uniqueKeysWithValues: chords.map { ($0.1, $0.0) })
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard let chord = KeyChord.from(event: event) else { return }
            guard let action = map.first(where: { $0.key.storageString == chord.storageString })?.value else {
                return
            }
            DispatchQueue.main.async {
                HotkeyCenter.shared.handleHotKeyFromCarbon(
                    id: UInt32(action == .screenshot ? 1 : 2)
                )
            }
        }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            conflictWarning = (conflictWarning.map { $0 + " " } ?? "")
                + "Grant Accessibility to CaptureAll so global hotkeys work while other apps are focused."
        }
    }
}
