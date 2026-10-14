import ServiceManagement
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var selected: SidebarItem = .general
    @State private var conflict: String? = HotkeyCenter.shared.conflictWarning
    @State private var stillsPathRefresh = 0
    @State private var videosPathRefresh = 0

    enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case shortcuts = "Shortcuts"
        case audio = "Audio"
        case capture = "Capture"
        case save = "Save"
        case permissions = "Permissions"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SidebarItem.allCases, selection: $selected) { item in
                Text(item.rawValue)
                    .tag(item)
                    .foregroundStyle(.primary)
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            Divider()

            Form {
                switch selected {
                case .general: generalSection
                case .shortcuts: shortcutsSection
                case .audio: audioSection
                case .capture: captureSection
                case .save: saveSection
                case .permissions: permissionsSection
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
    }

    @ViewBuilder private var generalSection: some View {
        Section {
            SettingsToggleRow(
                title: "Launch at login",
                isOn: Binding(
                    get: { store.settings.general.launchAtLogin },
                    set: { newValue in
                        store.update { $0.general.launchAtLogin = newValue }
                        updateLoginItem(newValue)
                    }
                )
            )
            Stepper(
                "Countdown: \(store.settings.video.countdownSeconds)s",
                value: SettingsBinding.value(\.video.countdownSeconds),
                in: 0...10
            )
            SettingsToggleRow(
                title: "Show cursor in video",
                isOn: SettingsBinding.bool(\.video.showCursor)
            )
            SettingsToggleRow(
                title: "Auto-quit when idle",
                isOn: SettingsBinding.bool(\.general.autoQuitEnabled),
                subtitle: "Quit CaptureAll after inactivity to free resources"
            )
            if store.settings.general.autoQuitEnabled {
                Stepper(
                    "Idle for \(store.settings.general.autoQuitIdleMinutes) min",
                    value: SettingsBinding.value(\.general.autoQuitIdleMinutes),
                    in: 1...120
                )
            }
        } header: {
            Text("General").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var shortcutsSection: some View {
        Section {
            if let conflict, !conflict.isEmpty {
                Text(conflict)
                    .foregroundStyle(.orange)
            }
            SettingsHotkeyRow(
                title: "Screenshot",
                storage: Binding(
                    get: { store.settings.hotkeys.screenshot },
                    set: { newValue in
                        store.update { $0.hotkeys.screenshot = newValue }
                        HotkeyCenter.shared.reregisterFromSettings()
                        conflict = HotkeyCenter.shared.conflictWarning
                    }
                )
            )
            VStack(alignment: .leading, spacing: 4) {
                SettingsHotkeyRow(
                    title: "Recording",
                    storage: Binding(
                        get: { store.settings.hotkeys.recording },
                        set: { newValue in
                            store.update { $0.hotkeys.recording = newValue }
                            HotkeyCenter.shared.reregisterFromSettings()
                            conflict = HotkeyCenter.shared.conflictWarning
                        }
                    )
                )
                Text("Stops the session when already recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("While selecting: ⌘⇧X previous mode · ⌘⇧C next mode · Space/Enter confirm")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Shortcuts").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var audioSection: some View {
        Section {
            SettingsToggleRow(
                title: "Microphone by default",
                isOn: SettingsBinding.bool(\.audioDefaults.microphone.enabled)
            )
            SettingsToggleRow(
                title: "System audio by default",
                isOn: SettingsBinding.bool(\.audioDefaults.systemAudio.enabled)
            )
            SettingsPickerRow(
                title: "Microphone",
                selection: Binding(
                    get: { store.settings.audioDefaults.microphone.deviceID ?? "" },
                    set: { value in
                        store.update { $0.audioDefaults.microphone.deviceID = value.isEmpty ? nil : value }
                    }
                )
            ) {
                Text("System Default").tag("")
                ForEach(AudioMixer.availableMicrophones(), id: \.id) { mic in
                    Text(mic.name).tag(mic.id)
                }
            }
        } header: {
            Text("Audio").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var captureSection: some View {
        Section {
            SettingsPickerRow(
                title: "Default photo mode",
                selection: SettingsBinding.value(\.photo.defaultMode)
            ) {
                Text("Full").tag(AppSettings.PhotoMode.full)
                Text("Window").tag(AppSettings.PhotoMode.window)
                Text("Area").tag(AppSettings.PhotoMode.area)
            }
            SettingsPickerRow(
                title: "FPS",
                selection: SettingsBinding.value(\.video.fps)
            ) {
                Text("30").tag(30)
                Text("60").tag(60)
            }
            SettingsPickerRow(
                title: "Resolution",
                selection: SettingsBinding.value(\.video.resolutionCap)
            ) {
                Text("Display native").tag(AppSettings.ResolutionCap.displayNative)
                Text("1080p max").tag(AppSettings.ResolutionCap.hd1080p)
            }
            SettingsToggleRow(
                title: "Show cursor in stills",
                isOn: SettingsBinding.bool(\.photo.showCursor)
            )
        } header: {
            Text("Capture").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var saveSection: some View {
        Section {
            SettingsToggleRow(
                title: "Save stills to folder",
                isOn: SettingsBinding.bool(\.photo.saveToFolder)
            )
            SettingsToggleRow(
                title: "Copy stills to clipboard",
                isOn: SettingsBinding.bool(\.photo.copyToClipboard)
            )
            SettingsFolderRow(
                title: "Stills folder",
                path: ExportStore.shared.defaultStillsDirectory().path,
                isEnabled: store.settings.photo.saveToFolder
            ) {
                SettingsFolderPicker.chooseDirectory { url in
                    ExportStore.shared.setStillsFolder(url)
                    stillsPathRefresh += 1
                }
            }
            .id(stillsPathRefresh)
            SettingsFolderRow(
                title: "Videos folder",
                path: ExportStore.shared.defaultVideosDirectory().path
            ) {
                SettingsFolderPicker.chooseDirectory { url in
                    ExportStore.shared.setVideosFolder(url)
                    videosPathRefresh += 1
                }
            }
            .id(videosPathRefresh)
        } header: {
            Text("Save").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var permissionsSection: some View {
        Section {
            SettingsPermissionRow(
                title: "Screen Recording",
                status: PermissionGate.hasScreenRecordingAccess() ? "Granted" : "Not granted",
                actionTitle: "Open Settings",
                action: { PermissionGate.openScreenRecordingSettings() }
            )
            SettingsPermissionRow(
                title: "Microphone",
                status: micStatusText(),
                actionTitle: "Open Settings",
                action: { PermissionGate.openMicrophoneSettings() }
            )
        } header: {
            Text("Permissions").foregroundStyle(.secondary)
        }
    }

    private func micStatusText() -> String {
        switch PermissionGate.microphoneAuthorization() {
        case .authorized: return "Granted"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not determined"
        @unknown default: return "Unknown"
        }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            ToastHUD.show("Login item update failed")
        }
    }
}
