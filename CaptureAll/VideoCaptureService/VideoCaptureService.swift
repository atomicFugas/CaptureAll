import AVFoundation
import AppKit
import CoreMedia
import IOKit.pwr_mgt
import ScreenCaptureKit

enum VideoTarget {
    case display(SCDisplay)
    case window(SCWindow)
    case area(display: SCDisplay, rectInDisplay: CGRect)
}

struct RecordingAudioOptions {
    var microphoneEnabled: Bool
    var microphoneDeviceID: String?
    var systemAudioEnabled: Bool
}

struct RecordingRequest {
    var target: VideoTarget
    var audio: RecordingAudioOptions
    var fps: Int
    var showsCursor: Bool
    var resolutionCap: AppSettings.ResolutionCap
}

enum VideoCaptureError: LocalizedError {
    case alreadyRecording
    case notRecording
    case writerFailed
    case streamFailed(String)
    case windowGone

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "No active recording."
        case .writerFailed: return "Could not create the movie writer."
        case .streamFailed(let m): return m
        case .windowGone: return "That window is no longer available."
        }
    }
}

/// Owns AVAssetWriter. Append methods run on `queue`.
private final class WriterSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.captureall.writer", qos: .userInitiated)
    var writer: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var systemAudioInput: AVAssetWriterInput?
    var micAudioInput: AVAssetWriterInput?
    var sessionStarted = false
    var accepting = false
    var videoFrames = 0
    var audioFrames = 0
    var droppedVideo = 0

    private func isWriting(_ writer: AVAssetWriter) -> Bool {
        writer.status == .writing
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard accepting, let writer, let videoInput, isWriting(writer) else {
            droppedVideo += 1
            return
        }
        guard Self.isCompleteFrame(sampleBuffer) else { return }
        guard videoInput.isReadyForMoreMediaData else {
            droppedVideo += 1
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        if videoInput.append(sampleBuffer) {
            videoFrames += 1
            if videoFrames == 1 || videoFrames % 120 == 0 {
                NSLog("CaptureAll: video frames=\(videoFrames) dropped=\(droppedVideo)")
            }
        } else {
            droppedVideo += 1
            if droppedVideo <= 5 || droppedVideo % 60 == 0 {
                NSLog(
                    "CaptureAll: video append failed status=\(writer.status.rawValue) err=\(String(describing: writer.error))"
                )
            }
        }
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        appendAudio(sampleBuffer, to: systemAudioInput)
    }

    func appendMicAudio(_ sampleBuffer: CMSampleBuffer) {
        appendAudio(sampleBuffer, to: micAudioInput)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard accepting, sessionStarted, let writer, isWriting(writer),
              let input, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            audioFrames += 1
        }
    }

    func finish() async -> (AVAssetWriter.Status?, Error?) {
        accepting = false
        return await withCheckedContinuation { cont in
            queue.async {
                NSLog(
                    "CaptureAll: finishing writer video=\(self.videoFrames) audio=\(self.audioFrames) dropped=\(self.droppedVideo)"
                )
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.micAudioInput?.markAsFinished()
                guard let writer = self.writer else {
                    cont.resume(returning: (nil, nil))
                    return
                }
                writer.finishWriting {
                    cont.resume(returning: (writer.status, writer.error))
                }
            }
        }
    }

    func cancel() {
        accepting = false
        queue.sync {
            writer?.cancelWriting()
            writer = nil
            videoInput = nil
            systemAudioInput = nil
            micAudioInput = nil
            sessionStarted = false
            videoFrames = 0
            audioFrames = 0
            droppedVideo = 0
        }
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else {
            // If attachments are missing, still try the buffer.
            return true
        }
        return status == .complete
    }
}

/// Not MainActor-isolated — `AVCaptureSession.startRunning` and `SCStream.startCapture`
/// must not run under the main actor or the app freezes (looks like a crash).
final class VideoCaptureService: NSObject {
    private(set) var isRecording = false

    private var stream: SCStream?
    private var outputURL: URL?
    private var micMixer: AudioMixer?
    private var sleepAssertionID: IOPMAssertionID = 0

    /// Stable for the process lifetime; sample callbacks use this without hopping threads.
    private nonisolated(unsafe) let writerSession = WriterSession()

    func start(_ request: RecordingRequest, outputURL: URL) async throws {
        guard !isRecording else { throw VideoCaptureError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter { $0.processID == ownPID }

        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        var wantSystemAudio = request.audio.systemAudioEnabled
        config.capturesAudio = wantSystemAudio
        config.showsCursor = request.showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, request.fps)))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        switch request.target {
        case .display(let display):
            let fresh = content.displays.first { $0.displayID == display.displayID } ?? display
            filter = SCContentFilter(display: fresh, excludingApplications: excludedApps, exceptingWindows: [])
            let scale = scaleFactor(for: fresh)
            var w = fresh.width
            var h = fresh.height
            // Some OS builds report SCDisplay size in points — scale up when too small.
            if let screen = screen(for: fresh),
               CGFloat(w) < screen.frame.width * scale * 0.9 {
                w = Int(screen.frame.width * scale)
                h = Int(screen.frame.height * scale)
            }
            applyPixelSize(
                config: config,
                pointWidth: CGFloat(w),
                pointHeight: CGFloat(h),
                scale: 1,
                cap: request.resolutionCap,
                alreadyPixels: true
            )

        case .window(let window):
            guard let fresh = content.windows.first(where: { $0.windowID == window.windowID }) else {
                throw VideoCaptureError.windowGone
            }
            filter = SCContentFilter(desktopIndependentWindow: fresh)
            let scale = scaleFactor(for: fresh.displayID.flatMap { id in content.displays.first { $0.displayID == id } })
            applyPixelSize(
                config: config,
                pointWidth: fresh.frame.width,
                pointHeight: fresh.frame.height,
                scale: scale,
                cap: request.resolutionCap,
                alreadyPixels: false
            )

        case .area(let display, let cocoaRect):
            let fresh = content.displays.first { $0.displayID == display.displayID } ?? display
            filter = SCContentFilter(display: fresh, excludingApplications: excludedApps, exceptingWindows: [])
            let scale = scaleFactor(for: fresh)
            let displayHeight = screen(for: fresh)?.frame.height ?? CGFloat(fresh.height) / max(scale, 1)
            config.sourceRect = CGRect(
                x: cocoaRect.origin.x,
                y: displayHeight - cocoaRect.origin.y - cocoaRect.height,
                width: max(2, cocoaRect.width),
                height: max(2, cocoaRect.height)
            )
            applyPixelSize(
                config: config,
                pointWidth: cocoaRect.width,
                pointHeight: cocoaRect.height,
                scale: scale,
                cap: request.resolutionCap,
                alreadyPixels: false
            )
        }

        guard config.width >= 2, config.height >= 2 else {
            throw VideoCaptureError.streamFailed("Capture region is too small.")
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw VideoCaptureError.writerFailed }
        writer.add(videoInput)

        func makeAudioInput() -> AVAssetWriterInput? {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            return input
        }

        // Separate tracks — mic and system audio use different clocks; one shared track fails the writer.
        let systemAudioInput = wantSystemAudio ? makeAudioInput() : nil
        let micAudioInput = request.audio.microphoneEnabled ? makeAudioInput() : nil

        guard writer.startWriting() else {
            throw writer.error ?? VideoCaptureError.writerFailed
        }

        writerSession.queue.sync {
            writerSession.writer = writer
            writerSession.videoInput = videoInput
            writerSession.systemAudioInput = systemAudioInput
            writerSession.micAudioInput = micAudioInput
            writerSession.sessionStarted = false
            writerSession.accepting = true
            writerSession.videoFrames = 0
            writerSession.audioFrames = 0
            writerSession.droppedVideo = 0
        }

        self.outputURL = outputURL
        NSLog("CaptureAll: starting stream \(config.width)x\(config.height) sysAudio=\(wantSystemAudio)")

        // Try with system audio; on failure rebuild stream without it.
        var started = false
        var lastError: Error?
        for attempt in 0..<2 {
            if attempt == 1 {
                wantSystemAudio = false
                config.capturesAudio = false
                writerSession.queue.sync { writerSession.systemAudioInput = nil }
            }
            do {
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerSession.queue)
                if wantSystemAudio {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerSession.queue)
                }
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    stream.startCapture { error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }
                self.stream = stream
                started = true
                break
            } catch {
                lastError = error
                NSLog("CaptureAll: startCapture attempt \(attempt) failed — \(error)")
                self.stream = nil
            }
        }
        guard started else {
            cleanupFailedStart()
            throw VideoCaptureError.streamFailed(lastError?.localizedDescription ?? "Stream failed")
        }

        if request.audio.microphoneEnabled {
            let sink = writerSession
            let deviceID = request.audio.microphoneDeviceID
            do {
                let mixer = try await Task.detached(priority: .userInitiated) {
                    let mixer = AudioMixer()
                    try mixer.start(deviceID: deviceID) { sample in
                        sink.queue.async { sink.appendMicAudio(sample) }
                    }
                    return mixer
                }.value
                micMixer = mixer
            } catch {
                NSLog("CaptureAll: mic start failed — \(error)")
            }
        }

        isRecording = true
        preventSleep(true)
        NSLog("CaptureAll: recording started \(config.width)x\(config.height) sysAudio=\(wantSystemAudio)")
    }

    func stop() async throws -> URL {
        guard isRecording, let stream, let url = outputURL else {
            throw VideoCaptureError.notRecording
        }

        isRecording = false
        preventSleep(false)
        micMixer?.stop()
        micMixer = nil

        try await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
        try? stream.removeStreamOutput(self, type: .audio)
        self.stream = nil

        let (status, error) = await writerSession.finish()
        writerSession.queue.sync {
            writerSession.writer = nil
            writerSession.videoInput = nil
            writerSession.systemAudioInput = nil
            writerSession.micAudioInput = nil
        }
        outputURL = nil

        if status == .failed {
            throw error ?? VideoCaptureError.writerFailed
        }
        return url
    }

    private func cleanupFailedStart() {
        micMixer?.stop()
        micMixer = nil
        stream = nil
        writerSession.cancel()
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        isRecording = false
    }

    private func applyPixelSize(
        config: SCStreamConfiguration,
        pointWidth: CGFloat,
        pointHeight: CGFloat,
        scale: CGFloat,
        cap: AppSettings.ResolutionCap,
        alreadyPixels: Bool
    ) {
        var w = alreadyPixels ? Int(pointWidth) : Int(pointWidth * scale)
        var h = alreadyPixels ? Int(pointHeight) : Int(pointHeight * scale)
        w = max(2, w)
        h = max(2, h)
        if cap == .hd1080p, h > 1080 {
            let ratio = CGFloat(1080) / CGFloat(h)
            h = 1080
            w = max(2, Int(CGFloat(w) * ratio))
        }
        // H.264 hardware encoders need even dims; prefer multiples of 16.
        w = max(16, w - (w % 16))
        h = max(16, h - (h % 16))
        config.width = w
        config.height = h
    }

    private func scaleFactor(for display: SCDisplay?) -> CGFloat {
        screen(for: display)?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func screen(for display: SCDisplay?) -> NSScreen? {
        guard let display else { return NSScreen.main }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
    }

    private func preventSleep(_ enable: Bool) {
        if enable {
            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "CaptureAll recording" as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                sleepAssertionID = assertionID
            }
        } else if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }
}

extension VideoCaptureService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("CaptureAll: SCStream stopped — \(error)")
    }
}

extension VideoCaptureService: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        // Invoked on writerSession.queue — append before returning (SCK requirement).
        switch type {
        case .screen:
            writerSession.appendVideo(sampleBuffer)
        case .audio:
            writerSession.appendSystemAudio(sampleBuffer)
        case .microphone:
            writerSession.appendMicAudio(sampleBuffer)
        @unknown default:
            break
        }
    }
}
