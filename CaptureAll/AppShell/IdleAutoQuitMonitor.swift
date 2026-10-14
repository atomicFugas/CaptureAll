import AppKit
import Combine

/// Quits the app after a configured idle period so it stops using resources.
@MainActor
final class IdleAutoQuitMonitor {
    static let shared = IdleAutoQuitMonitor()

    private var lastActivity = Date()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// True while selection overlay or settings should block auto-quit.
    var isBusy: (() -> Bool)?

    private init() {}

    func start() {
        SettingsStore.shared.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reschedule()
            }
            .store(in: &cancellables)
        noteActivity()
        reschedule()
    }

    func noteActivity() {
        lastActivity = Date()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil

        let general = SettingsStore.shared.settings.general
        guard general.autoQuitEnabled else { return }

        let minutes = max(1, min(120, general.autoQuitIdleMinutes))
        let interval = TimeInterval(minutes * 60)
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick(idleLimit: interval)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick(idleLimit: TimeInterval) {
        guard SettingsStore.shared.settings.general.autoQuitEnabled else { return }
        if isBusy?() == true { return }
        if CaptureCoordinator.shared.isRecording {
            noteActivity()
            return
        }
        if Date().timeIntervalSince(lastActivity) >= idleLimit {
            NSLog("CaptureAll: idle auto-quit after \(Int(idleLimit / 60))m")
            NSApp.terminate(nil)
        }
    }
}
