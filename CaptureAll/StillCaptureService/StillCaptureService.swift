import AppKit
import ScreenCaptureKit

enum StillTarget {
    case display(SCDisplay)
    case window(SCWindow)
    case area(display: SCDisplay, rectInDisplay: CGRect)
}

protocol StillCaptureServiceProtocol {
    func capture(_ target: StillTarget, showsCursor: Bool) async throws -> CGImage
}

enum StillCaptureError: LocalizedError {
    case unsupported
    case emptyImage
    case contentUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Still capture is not supported on this macOS version."
        case .emptyImage: return "Capture returned an empty image."
        case .contentUnavailable: return "Could not enumerate shareable screen content."
        }
    }
}

final class StillCaptureService: StillCaptureServiceProtocol {
    func capture(_ target: StillTarget, showsCursor: Bool) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await captureWithScreenshotManager(target, showsCursor: showsCursor)
        }
        throw StillCaptureError.unsupported
    }

    @available(macOS 14.0, *)
    private func captureWithScreenshotManager(_ target: StillTarget, showsCursor: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == ownPID }

        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        config.showsCursor = showsCursor
        config.capturesAudio = false

        switch target {
        case .display(let display):
            // Exclude CaptureAll so menu-bar / toasts never appear. UI must already be hidden
            // or excluded regions show empty; coordinator waits before calling us.
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let scale = scaleFactor(for: display)
            // SCDisplay width/height are already in pixels.
            config.width = max(2, display.width - display.width % 2)
            config.height = max(2, display.height - display.height % 2)
            // If API reports points on some OS builds, scale up when obviously too small vs screen.
            if let screen = screen(for: display),
               CGFloat(config.width) < screen.frame.width * scale * 0.9 {
                config.width = max(2, Int(screen.frame.width * scale) & ~1)
                config.height = max(2, Int(screen.frame.height * scale) & ~1)
            }

        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = scaleFactor(for: window.displayID.flatMap { id in content.displays.first { $0.displayID == id } })
            let frame = window.frame
            config.width = max(2, Int(frame.width * scale) & ~1)
            config.height = max(2, Int(frame.height * scale) & ~1)

        case .area(let display, let cocoaRect):
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let scale = scaleFactor(for: display)
            // Overlay uses Cocoa bottom-left; SCK sourceRect is top-left of the display.
            let displayHeight = screen(for: display)?.frame.height ?? CGFloat(display.height) / scale
            config.sourceRect = CGRect(
                x: cocoaRect.origin.x,
                y: displayHeight - cocoaRect.origin.y - cocoaRect.height,
                width: cocoaRect.width,
                height: cocoaRect.height
            )
            config.width = max(2, Int(cocoaRect.width * scale) & ~1)
            config.height = max(2, Int(cocoaRect.height * scale) & ~1)
        }

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: StillCaptureError.emptyImage)
                    return
                }
                continuation.resume(returning: image)
            }
        }
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
}

extension SCDisplay {
    var scale: CGFloat? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }?.backingScaleFactor
    }
}

extension SCWindow {
    var displayID: CGDirectDisplayID? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for screen in NSScreen.screens {
            if screen.frame.contains(center),
               let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return num
            }
        }
        return nil
    }
}
