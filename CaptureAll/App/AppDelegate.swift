import AppKit

@main
@MainActor
enum CaptureAllEntry {
    static func main() {
        let app = NSApplication.shared
        guard SingleInstance.claimOrActivateExisting() else {
            exit(0)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = NSMenu()

        NSLog(
            "CaptureAll: launched bundleID=%@ path=%@",
            Bundle.main.bundleIdentifier ?? "?",
            Bundle.main.bundlePath
        )

        MenuBarFallbackPill.shared.hide()

        statusItem.isRecording = { CaptureCoordinator.shared.isRecording }
        statusItem.onScreenshot = {
            IdleAutoQuitMonitor.shared.noteActivity()
            CaptureCoordinator.shared.beginScreenshot()
        }
        statusItem.onRecording = {
            IdleAutoQuitMonitor.shared.noteActivity()
            CaptureCoordinator.shared.beginRecording()
        }
        statusItem.onStopRecording = {
            IdleAutoQuitMonitor.shared.noteActivity()
            CaptureCoordinator.shared.stopRecordingIfNeeded()
        }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onQuit = { NSApp.terminate(nil) }
        statusItem.onMenuWillOpen = { IdleAutoQuitMonitor.shared.noteActivity() }

        statusItem.install()
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.ensureVisible()
        }

        HotkeyCenter.shared.onAction = { action in
            IdleAutoQuitMonitor.shared.noteActivity()
            switch action {
            case .screenshot:
                CaptureCoordinator.shared.beginScreenshot()
            case .recording:
                CaptureCoordinator.shared.beginRecording()
            }
        }
        HotkeyCenter.shared.start()

        IdleAutoQuitMonitor.shared.isBusy = {
            CaptureCoordinator.shared.isSelecting
                || CaptureCoordinator.shared.isRecording
                || (NSApp.windows.contains { $0.isVisible && $0.title.contains("Settings") })
        }
        IdleAutoQuitMonitor.shared.start()

        SingleInstance.observeActivation { [weak self] in
            IdleAutoQuitMonitor.shared.noteActivity()
            self?.statusItem.popControlMenu()
        }

        try? FileManager.default.createDirectory(
            at: ExportStore.shared.defaultStillsDirectory(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: ExportStore.shared.defaultVideosDirectory(),
            withIntermediateDirectories: true
        )

        if CommandLine.arguments.contains("--record-full") {
            let stopAfter: TimeInterval = {
                if let idx = CommandLine.arguments.firstIndex(of: "--stop-after"),
                   CommandLine.arguments.indices.contains(idx + 1),
                   let secs = TimeInterval(CommandLine.arguments[idx + 1]) {
                    return max(1, secs)
                }
                return 4
            }()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let audio = SettingsStore.shared.settings.audioDefaults
                CaptureCoordinator.shared.startFullRecordingForCLI(
                    mic: audio.microphone.enabled,
                    system: audio.systemAudio.enabled
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) {
                    CaptureCoordinator.shared.stopRecordingIfNeeded()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        IdleAutoQuitMonitor.shared.noteActivity()
        statusItem.popControlMenu()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if CaptureCoordinator.shared.isRecording {
            CaptureCoordinator.shared.stopRecordingIfNeeded()
        }
    }

    private func openSettings() {
        IdleAutoQuitMonitor.shared.noteActivity()
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        NSLog("CaptureAll: openSettings()")
        settingsWindow?.show()
    }
}
