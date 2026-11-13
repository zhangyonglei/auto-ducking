import AppKit
import SwiftUI
import AutoDuckingCore

struct MenuBarLabel: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: DuckingEngine

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel("AutoDucking")
    }

    private var symbolName: String {
        guard settings.isEnabled else { return "mic.slash" }
        return engine.isDucked ? "mic.fill" : "mic"
    }
}

struct MenuBarView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: DuckingEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(engine.statusText, systemImage: engine.statusSymbol)

        Text("输出：\(engine.outputDeviceName)")
        Text("闪避后为原音量的 \(settings.duckLevelPercent)%")

        Divider()

        Toggle("启用自动闪避", isOn: $settings.isEnabled)

        Menu("预设") {
            ForEach(DuckingPreset.all) { preset in
                Button {
                    settings.apply(preset)
                } label: {
                    if settings.activePreset == preset {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
        }

        Button("测试闪避效果") {
            engine.preview()
        }
        .disabled(!settings.isEnabled || engine.microphoneActive || engine.isDucked)

        Divider()

        SettingsLink {
            Text("设置…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("关于 AutoDucking") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }

        Divider()

        Button("退出 AutoDucking") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
