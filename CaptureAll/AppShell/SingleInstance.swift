import AppKit
import Foundation

enum SingleInstance {
    private static let notifyName = Notification.Name("app.captureall.CaptureAll.activate")

    /// Returns `false` if another CaptureAll is already running (and activates it).
    @MainActor
    static func claimOrActivateExisting() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.captureall.CaptureAll"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        if let existing = others.first {
            DistributedNotificationCenter.default().postNotificationName(
                notifyName,
                object: bundleID,
                userInfo: ["reason": "secondLaunch"],
                deliverImmediately: true
            )
            existing.activate(options: [.activateAllWindows])
            return false
        }
        return true
    }

    @MainActor
    static func observeActivation(_ handler: @escaping () -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: notifyName,
            object: Bundle.main.bundleIdentifier,
            queue: .main
        ) { _ in
            handler()
        }
    }
}
