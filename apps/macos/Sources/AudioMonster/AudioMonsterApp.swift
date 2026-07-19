import SwiftUI

@main
struct AudioMonsterApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(settings)
        } label: {
            Group {
                if let image = MenuBarIcon.image {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .accessibilityLabel("Audio Monster")
                } else {
                    Label("Audio Monster", systemImage: model.menuBarSymbol)
                }
            }
            .task {
                // MenuBarExtra content is lazy; startup work belongs on its always-visible label.
                await model.startIfNeeded()
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(settings)
        }
    }
}
