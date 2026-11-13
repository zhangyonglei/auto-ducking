import SwiftUI
import AutoDuckingCore

@main
struct AutoDuckingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(settings: model.settings, engine: model.engine)
        } label: {
            MenuBarLabel(settings: model.settings, engine: model.engine)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: model.settings, engine: model.engine, app: model)
        }

        Window("关于 AutoDucking", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
