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

    /// Quit and reopen this .app so TCC Screen Recording takes effect for the new process.
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("CaptureAll: relaunch failed: %@", error.localizedDescription)
                }
                NSApp.terminate(nil)
            }
        }
        // Fallback if openApplication never calls back promptly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    static func ensureScreenRecording(presenter: NSWindow? = nil) -> Bool {
        if hasScreenRecordingAccess() { return true }

        // Prompt (or refresh TCC). On modern macOS the *current* process often
        // still fails preflight until a full quit/relaunch, even when Settings shows ON.
        _ = requestScreenRecordingAccess()
        if hasScreenRecordingAccess() { return true }

        showScreenRecordingGuide(presenter: presenter)
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
                buttons: [
                    ("Open System Settings", openMicrophoneSettings),
                    ("Cancel", nil)
                ],
                presenter: nil
            )
            return false
        @unknown default:
            return false
        }
    }

    static func screenRecordingStatusLabel() -> String {
        if hasScreenRecordingAccess() { return "Granted" }
        return "Needs Quit & Relaunch"
    }

    private static func showScreenRecordingGuide(presenter: NSWindow?) {
        showGuide(
            title: "Screen Recording Required",
            message: """
            Turn on CaptureAll in System Settings → Privacy & Security → Screen Recording.

            After enabling (or if it already shows On), you must Quit CaptureAll and open it again — macOS does not apply Screen Recording to the running process.
            """,
            buttons: [
                ("Quit & Relaunch", relaunchApp),
                ("Open System Settings", openScreenRecordingSettings),
                ("Cancel", nil)
            ],
            presenter: presenter
        )
    }

    private static func showGuide(
        title: String,
        message: String,
        buttons: [(String, (() -> Void)?)],
        presenter: NSWindow?
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for (title, _) in buttons {
            alert.addButton(withTitle: title)
        }
        _ = presenter
        let result = alert.runModal()
        // NSAlertFirstButtonReturn = 1000, then 1001, 1002…
        let index = result.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < buttons.count else { return }
        buttons[index].1?()
    }
}
