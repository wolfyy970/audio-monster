import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var folderError: String?
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Audio") {
                VoiceSelectionControl(
                    voices: model.voices,
                    selectedVoiceID: $settings.voiceID,
                    model: model
                )

                if let message = model.voicePreviewErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                PlaybackRateControl(value: $model.playbackRate, presentation: .settings)

                Toggle("Play automatically when ready", isOn: $settings.autoPlay)
            }

            Section("App behavior") {
                Toggle(
                    "Open Audio Monster at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { enabled in
                            do {
                                try settings.setLaunchAtLogin(enabled)
                                launchAtLoginError = nil
                            } catch {
                                launchAtLoginError = error.localizedDescription
                            }
                        }
                    )
                )

                if settings.launchAtLoginStatus == .requiresApproval {
                    Text("Audio Monster is registered, but macOS needs your approval before it can open at login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Login Items Settings") {
                        settings.openLoginItemsSettings()
                    }
                } else if settings.launchAtLoginStatus == .unavailable {
                    Text("Login-item registration is unavailable for this app build. Install Audio Monster in Applications and try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Show icon in Dock", isOn: $settings.showInDock)

                Text("The menu bar icon remains available when the Dock icon is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Save location") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.saveLocationKind.label)
                        Text(settings.saveFolderURL.path(percentEncoded: false))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                        .disabled(model.isSavingFile)
                }
                if settings.saveLocationKind == .localFallback {
                    Text(
                        "Audio Monster will use iCloud Drive automatically in a signed build with iCloud Documents enabled. This app-owned folder is the reliable fallback for local development builds."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if settings.saveLocationKind == .custom {
                    Button("Use Recommended Location") {
                        Task {
                            await settings.resetToRecommendedSaveFolder()
                            await model.refreshLibrary()
                        }
                    }
                    .disabled(model.isSavingFile)
                }
                if let folderError {
                    Text(folderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

        }
        .formStyle(.grouped)
        .frame(width: 620, height: 470)
        .background(SettingsWindowActivationView())
        .task {
            await settings.resolveRecommendedSaveFolder()
            if model.engineState != .ready {
                await model.refreshEngine()
            }
            await model.refreshVoicePreviews()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLoginStatus()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where Audio Monster saves audio"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolderURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.setSaveFolder(url)
            folderError = nil
            Task { await model.refreshLibrary() }
        } catch {
            folderError = error.localizedDescription
        }
    }
}
