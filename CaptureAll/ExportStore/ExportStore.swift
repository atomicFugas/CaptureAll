import AppKit
import Foundation
import UniformTypeIdentifiers

struct StillExportResult {
    var fileURL: URL?
    var copiedToClipboard: Bool
}

@MainActor
final class ExportStore {
    static let shared = ExportStore()

    private init() {}

    func defaultStillsDirectory() -> URL {
        resolvedDirectory(bookmark: SettingsStore.shared.settings.export.stillsBookmark)
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("CaptureAll", isDirectory: true)
    }

    func defaultVideosDirectory() -> URL {
        resolvedDirectory(bookmark: SettingsStore.shared.settings.export.videosBookmark)
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("CaptureAll", isDirectory: true)
    }

    @discardableResult
    func saveStill(_ image: CGImage, copyToClipboard: Bool? = nil, saveToFolder: Bool? = nil) throws -> StillExportResult {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        var shouldSave = saveToFolder ?? SettingsStore.shared.settings.photo.saveToFolder
        var shouldCopy = copyToClipboard ?? SettingsStore.shared.settings.photo.copyToClipboard

        // If both are off, still put the image on the clipboard so the capture isn't lost.
        if !shouldSave && !shouldCopy {
            shouldCopy = true
        }

        var fileURL: URL?
        if shouldSave {
            let dir = defaultStillsDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = filename(
                pattern: SettingsStore.shared.settings.export.stillsNamePattern,
                ext: "png"
            )
            let url = uniqueURL(in: dir, preferredName: name)
            guard let tiff = nsImage.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw ExportError.writeFailed
            }
            try png.write(to: url)
            fileURL = url
        }

        if shouldCopy {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([nsImage])
        }

        return StillExportResult(fileURL: fileURL, copiedToClipboard: shouldCopy)
    }

    func preparedVideoURL() throws -> URL {
        let dir = defaultVideosDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = filename(
            pattern: SettingsStore.shared.settings.export.videosNamePattern,
            ext: "mp4"
        )
        return uniqueURL(in: dir, preferredName: name)
    }

    func setStillsFolder(_ url: URL) {
        let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        SettingsStore.shared.update { $0.export.stillsBookmark = data }
    }

    func setVideosFolder(_ url: URL) {
        let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        SettingsStore.shared.update { $0.export.videosBookmark = data }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func resolvedDirectory(bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private func filename(pattern: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var name = pattern.replacingOccurrences(of: "{timestamp}", with: stamp)
        if !name.lowercased().hasSuffix(".\(ext)") {
            name += ".\(ext)"
        }
        return name
    }

    private func uniqueURL(in directory: URL, preferredName: String) -> URL {
        var url = directory.appendingPathComponent(preferredName)
        var index = 2
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return url
    }
}

enum ExportError: LocalizedError {
    case writeFailed
    var errorDescription: String? { "Could not write the capture file." }
}
