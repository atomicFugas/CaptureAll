import Foundation

struct AppSettings: Codable, Equatable {
    var schemaVersion: Int = 2
    var hotkeys: HotkeySettings = .init()
    var audioDefaults: AudioDefaults = .init()
    var video: VideoSettings = .init()
    var photo: PhotoSettings = .init()
    var export: ExportSettings = .init()
    var general: GeneralSettings = .init()

    struct HotkeySettings: Codable, Equatable {
        var screenshot: String = "cmd+shift+a"
        var recording: String = "cmd+shift+s"

        enum CodingKeys: String, CodingKey {
            case screenshot, recording
            case palette, stopRecording // legacy
        }

        init(screenshot: String = "cmd+shift+a", recording: String = "cmd+shift+s") {
            self.screenshot = screenshot
            self.recording = recording
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let shot = try c.decodeIfPresent(String.self, forKey: .screenshot) {
                screenshot = shot
            } else if let legacy = try c.decodeIfPresent(String.self, forKey: .palette) {
                screenshot = legacy
            } else {
                screenshot = "cmd+shift+a"
            }
            if let rec = try c.decodeIfPresent(String.self, forKey: .recording) {
                recording = rec
            } else if let legacy = try c.decodeIfPresent(String.self, forKey: .stopRecording) {
                recording = legacy
            } else {
                recording = "cmd+shift+s"
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(screenshot, forKey: .screenshot)
            try c.encode(recording, forKey: .recording)
        }
    }

    struct AudioDefaults: Codable, Equatable {
        var microphone: MicDefaults = .init()
        var systemAudio: SystemAudioDefaults = .init()
    }

    struct MicDefaults: Codable, Equatable {
        var enabled: Bool = true
        var deviceID: String? = nil
    }

    struct SystemAudioDefaults: Codable, Equatable {
        var enabled: Bool = true
    }

    enum ResolutionCap: String, Codable, Equatable {
        case displayNative
        case hd1080p
    }

    struct VideoSettings: Codable, Equatable {
        var fps: Int = 30
        var resolutionCap: ResolutionCap = .displayNative
        var showCursor: Bool = true
        var countdownSeconds: Int = 0
        var defaultMode: PhotoMode = .window

        enum CodingKeys: String, CodingKey {
            case fps, resolutionCap, showCursor, countdownSeconds, defaultMode
        }

        init(
            fps: Int = 30,
            resolutionCap: ResolutionCap = .displayNative,
            showCursor: Bool = true,
            countdownSeconds: Int = 0,
            defaultMode: PhotoMode = .window
        ) {
            self.fps = fps
            self.resolutionCap = resolutionCap
            self.showCursor = showCursor
            self.countdownSeconds = countdownSeconds
            self.defaultMode = defaultMode
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
            resolutionCap = try c.decodeIfPresent(ResolutionCap.self, forKey: .resolutionCap) ?? .displayNative
            showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? true
            countdownSeconds = try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? 0
            defaultMode = try c.decodeIfPresent(PhotoMode.self, forKey: .defaultMode) ?? .window
        }
    }

    enum PhotoMode: String, Codable, Equatable {
        case full
        case window
        case area
    }

    struct PhotoSettings: Codable, Equatable {
        var defaultMode: PhotoMode = .window
        var copyToClipboard: Bool = true
        /// When false (default), stills are not written to disk — clipboard only if enabled.
        var saveToFolder: Bool = false
        var showCursor: Bool = false

        enum CodingKeys: String, CodingKey {
            case defaultMode, copyToClipboard, saveToFolder, showCursor
        }

        init(
            defaultMode: PhotoMode = .window,
            copyToClipboard: Bool = true,
            saveToFolder: Bool = false,
            showCursor: Bool = false
        ) {
            self.defaultMode = defaultMode
            self.copyToClipboard = copyToClipboard
            self.saveToFolder = saveToFolder
            self.showCursor = showCursor
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultMode = try c.decodeIfPresent(PhotoMode.self, forKey: .defaultMode) ?? .window
            copyToClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? true
            saveToFolder = try c.decodeIfPresent(Bool.self, forKey: .saveToFolder) ?? false
            showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? false
        }
    }

    struct ExportSettings: Codable, Equatable {
        var stillsBookmark: Data? = nil
        var videosBookmark: Data? = nil
        var stillsNamePattern: String = "CaptureAll - {timestamp}.png"
        var videosNamePattern: String = "CaptureAll - {timestamp}.mp4"
    }

    struct GeneralSettings: Codable, Equatable {
        var launchAtLogin: Bool = false
        var autoQuitEnabled: Bool = false
        var autoQuitIdleMinutes: Int = 15

        enum CodingKeys: String, CodingKey {
            case launchAtLogin, autoQuitEnabled, autoQuitIdleMinutes
        }

        init(
            launchAtLogin: Bool = false,
            autoQuitEnabled: Bool = false,
            autoQuitIdleMinutes: Int = 15
        ) {
            self.launchAtLogin = launchAtLogin
            self.autoQuitEnabled = autoQuitEnabled
            self.autoQuitIdleMinutes = autoQuitIdleMinutes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
            autoQuitEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoQuitEnabled) ?? false
            autoQuitIdleMinutes = try c.decodeIfPresent(Int.self, forKey: .autoQuitIdleMinutes) ?? 15
        }
    }
}
