import AppKit
import AVFoundation
import CoreGraphics

@MainActor
enum PermissionGate {
    static func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func microphoneAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    static func ensureScreenRecording(presenter: NSWindow? = nil) -> Bool {
        if hasScreenRecordingAccess() { return true }
        _ = requestScreenRecordingAccess()
        if hasScreenRecordingAccess() { return true }
        showGuide(
            title: "Screen Recording Required",
            message: "CaptureAll needs Screen Recording access to capture photos and video. Grant access in System Settings, then try again.",
            open: openScreenRecordingSettings,
            presenter: presenter
        )
        return false
    }

    static func ensureMicrophoneIfNeeded(enabled: Bool) async -> Bool {
        guard enabled else { return true }
        switch microphoneAuthorization() {
        case .authorized:
            return true
        case .notDetermined:
            return await requestMicrophoneAccess()
        case .denied, .restricted:
            showGuide(
                title: "Microphone Access Required",
                message: "Enable microphone access in System Settings to include your voice in recordings.",
                open: openMicrophoneSettings,
                presenter: nil
            )
            return false
        @unknown default:
            return false
        }
    }

    private static func showGuide(title: String, message: String, open: @escaping () -> Void, presenter: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        _ = presenter
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            open()
        }
    }
}
