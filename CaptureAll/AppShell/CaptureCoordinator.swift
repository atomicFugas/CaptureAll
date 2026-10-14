import AppKit
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    let stillService = StillCaptureService()
    let videoService = VideoCaptureService()
    let selection = SelectionOverlayController()

    private init() {}

    var isRecording: Bool { videoService.isRecording }
    var isSelecting: Bool { selection.isActive }

    func beginScreenshot() {
        IdleAutoQuitMonitor.shared.noteActivity()
        Task {
            ToastHUD.dismiss()
            let start = SelectionMode.from(photoMode: SettingsStore.shared.settings.photo.defaultMode)
            let result = await selection.pickCycling(purpose: .photo, startingMode: start)
            switch result {
            case .display:
                SettingsStore.shared.update { $0.photo.defaultMode = .full }
                await captureFull()
            case .window(let window):
                SettingsStore.shared.update { $0.photo.defaultMode = .window }
                await settleUIBeforeCapture()
                do {
                    let image = try await stillService.capture(
                        .window(window),
                        showsCursor: SettingsStore.shared.settings.photo.showCursor
                    )
                    try exportStill(image)
                } catch {
                    ToastHUD.show(error.localizedDescription)
                }
            case .area(let display, let rect):
                SettingsStore.shared.update { $0.photo.defaultMode = .area }
                await settleUIBeforeCapture()
                do {
                    let image = try await stillService.capture(
                        .area(display: display, rectInDisplay: rect),
                        showsCursor: SettingsStore.shared.settings.photo.showCursor
                    )
                    try exportStill(image)
                } catch {
                    ToastHUD.show(error.localizedDescription)
                }
            case .cancelled:
                break
            }
            IdleAutoQuitMonitor.shared.noteActivity()
        }
    }

    func beginRecording() {
        IdleAutoQuitMonitor.shared.noteActivity()
        if videoService.isRecording {
            stopRecordingIfNeeded()
            return
        }
        Task {
            ToastHUD.dismiss()
            let audio = SettingsStore.shared.settings.audioDefaults
            let start = SelectionMode.from(photoMode: SettingsStore.shared.settings.video.defaultMode)
            let result = await selection.pickCycling(purpose: .record, startingMode: start)
            switch result {
            case .display:
                SettingsStore.shared.update { $0.video.defaultMode = .full }
                await startRecording(
                    target: .displayResolved,
                    mic: audio.microphone.enabled,
                    system: audio.systemAudio.enabled
                )
            case .window(let window):
                SettingsStore.shared.update { $0.video.defaultMode = .window }
                await startRecording(
                    target: .window(window),
                    mic: audio.microphone.enabled,
                    system: audio.systemAudio.enabled
                )
            case .area(let display, let rect):
                SettingsStore.shared.update { $0.video.defaultMode = .area }
                await startRecording(
                    target: .area(display: display, rectInDisplay: rect),
                    mic: audio.microphone.enabled,
                    system: audio.systemAudio.enabled
                )
            case .cancelled:
                break
            }
            IdleAutoQuitMonitor.shared.noteActivity()
        }
    }

    func stopRecordingIfNeeded() {
        IdleAutoQuitMonitor.shared.noteActivity()
        Task {
            guard videoService.isRecording else { return }
            do {
                let url = try await videoService.stop()
                ToastHUD.show("Saved recording")
                ExportStore.shared.reveal(url)
            } catch {
                ToastHUD.show(error.localizedDescription)
            }
            IdleAutoQuitMonitor.shared.noteActivity()
        }
    }

    /// Used by `--record-full` CLI smoke test.
    func startFullRecordingForCLI(mic: Bool, system: Bool) {
        Task {
            await startRecording(target: .displayResolved, mic: mic, system: system)
        }
    }

    private func captureFull() async {
        guard PermissionGate.ensureScreenRecording() else { return }
        await settleUIBeforeCapture()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = preferredDisplay(from: content) else { return }
            let image = try await stillService.capture(
                .display(display),
                showsCursor: SettingsStore.shared.settings.photo.showCursor
            )
            try exportStill(image)
        } catch {
            ToastHUD.show(error.localizedDescription)
        }
    }

    private func exportStill(_ image: CGImage) throws {
        let result = try ExportStore.shared.saveStill(image)
        switch (result.fileURL != nil, result.copiedToClipboard) {
        case (true, true):
            ToastHUD.show("Saved + copied")
        case (true, false):
            ToastHUD.show("Screenshot saved")
        case (false, true):
            ToastHUD.show("Copied to clipboard")
        case (false, false):
            ToastHUD.show("Capture complete")
        }
    }

    private func settleUIBeforeCapture() async {
        ToastHUD.dismiss()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 120_000_000)
        await Task.yield()
    }

    private enum PreparedTarget {
        case displayResolved
        case window(SCWindow)
        case area(display: SCDisplay, rectInDisplay: CGRect)
    }

    private func startRecording(target: PreparedTarget, mic: Bool, system: Bool) async {
        guard PermissionGate.ensureScreenRecording() else { return }
        guard !videoService.isRecording else {
            ToastHUD.show("Already recording")
            return
        }

        var useMic = mic
        if mic {
            let micOK = await PermissionGate.ensureMicrophoneIfNeeded(enabled: true)
            if !micOK {
                useMic = false
                ToastHUD.show("Recording without microphone")
                try? await Task.sleep(nanoseconds: 600_000_000)
                ToastHUD.dismiss()
            }
        }

        let videoTarget: VideoTarget
        switch target {
        case .displayResolved:
            await settleUIBeforeCapture()
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = preferredDisplay(from: content) else {
                    ToastHUD.show("No display available")
                    return
                }
                videoTarget = .display(display)
            } catch {
                ToastHUD.show(error.localizedDescription)
                return
            }
        case .window(let window):
            videoTarget = .window(window)
        case .area(let display, let rect):
            videoTarget = .area(display: display, rectInDisplay: rect)
        }

        await settleUIBeforeCapture()

        let countdown = SettingsStore.shared.settings.video.countdownSeconds
        if countdown > 0 {
            await runCountdown(countdown)
            await settleUIBeforeCapture()
        }

        do {
            let url = try ExportStore.shared.preparedVideoURL()
            let stableTarget = videoTarget
            let request = RecordingRequest(
                target: stableTarget,
                audio: RecordingAudioOptions(
                    microphoneEnabled: useMic,
                    microphoneDeviceID: SettingsStore.shared.settings.audioDefaults.microphone.deviceID,
                    systemAudioEnabled: system
                ),
                fps: SettingsStore.shared.settings.video.fps,
                showsCursor: SettingsStore.shared.settings.video.showCursor,
                resolutionCap: SettingsStore.shared.settings.video.resolutionCap
            )
            try await Task.detached(priority: .userInitiated) { [videoService] in
                try await videoService.start(request, outputURL: url)
            }.value
            NSLog("CaptureAll: recording started (no badge)")
            IdleAutoQuitMonitor.shared.noteActivity()
        } catch {
            NSLog("CaptureAll: start recording failed — \(error)")
            ToastHUD.show(error.localizedDescription)
        }
    }

    private func runCountdown(_ seconds: Int) async {
        for value in stride(from: seconds, through: 1, by: -1) {
            ToastHUD.show("\(value)", duration: 0.85)
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        ToastHUD.dismiss()
    }

    private func preferredDisplay(from content: SCShareableContent) -> SCDisplay? {
        if let main = NSScreen.main,
           let number = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return content.displays.first { $0.displayID == number } ?? content.displays.first
        }
        return content.displays.first
    }
}
