import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var settings: AppSettings {
        didSet { persist() }
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("CaptureAll", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode(AppSettings.self, from: data) {
            settings = Self.migrating(decoded)
        } else {
            settings = AppSettings()
            persist()
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    private func persist() {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func migrating(_ settings: AppSettings) -> AppSettings {
        var s = settings
        if s.schemaVersion < 2 {
            s.schemaVersion = 2
        }
        if s.general.autoQuitIdleMinutes < 1 {
            s.general.autoQuitIdleMinutes = 15
        }
        if s.general.autoQuitIdleMinutes > 120 {
            s.general.autoQuitIdleMinutes = 120
        }
        return s
    }
}
