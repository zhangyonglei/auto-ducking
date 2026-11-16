import SwiftUI
import AutoDuckingCore

enum SettingsWindowMetrics {
    static let contentSize = CGSize(width: 520, height: 530)
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: DuckingEngine
    @ObservedObject var app: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings, engine: engine, app: app)
                .tabItem { Label("通用", systemImage: "gearshape") }

            DuckingSettingsView(settings: settings, engine: engine)
                .tabItem { Label("闪避", systemImage: "waveform") }

            PresetSettingsView(settings: settings)
                .tabItem { Label("预设", systemImage: "slider.horizontal.3") }
        }
        .frame(width: SettingsWindowMetrics.contentSize.width, height: SettingsWindowMetrics.contentSize.height)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: DuckingEngine
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("启用自动闪避", isOn: $settings.isEnabled)
                Toggle("会议通话时保持原音量", isOn: $settings.bypassConferenceAudio)
                Toggle(
                    "登录时自动启动",
                    isOn: Binding(
                        get: { app.launchAtLogin },
                        set: { app.setLaunchAtLogin($0) }
                    )
                )
            } header: {
                Text("行为")
            } footer: {
                Text("检测到麦克风被占用时降低系统输出音量，结束后恢复。QQ、钉钉、微信等会议通话中若麦克风与播放来自同一个应用，会保持原音量，避免压低对方人声。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = app.launchAtLoginError {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("隐私与资源") {
                Label("只监测麦克风是否被占用，不录音、不读取音频内容", systemImage: "lock.shield")
                Label("不需要麦克风权限，空闲时不轮询，几乎不占用 CPU", systemImage: "leaf")
            }

            Section("当前状态") {
                LabeledContent("状态") {
                    Text(engine.statusText)
                }
                LabeledContent("输出设备") {
                    Text(engine.outputDeviceName)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DuckingSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: DuckingEngine

    var body: some View {
        Form {
            Section {
                LabeledContent("闪避后音量") {
                    HStack(spacing: 12) {
                        Slider(value: $settings.duckLevel, in: SettingsStore.duckLevelRange)
                        Text("\(settings.duckLevelPercent)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Text("背景音量会降到当前音量的 \(settings.duckLevelPercent)%。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("强度")
            }

            Section {
                LabeledContent("淡入时长") {
                    durationSlider(
                        value: $settings.attackDuration,
                        range: SettingsStore.attackRange,
                        step: 0.05
                    )
                }
                LabeledContent("淡出时长") {
                    durationSlider(
                        value: $settings.releaseDuration,
                        range: SettingsStore.releaseRange,
                        step: 0.05
                    )
                }
                LabeledContent("恢复延迟") {
                    durationSlider(
                        value: $settings.releaseDelay,
                        range: SettingsStore.releaseDelayRange,
                        step: 0.1
                    )
                }
                Text("恢复延迟可避免说话间歇时音量频繁起伏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("过渡")
            }

            Section("预览") {
                LabeledContent("状态") {
                    Text(engine.statusText)
                }
                Button("测试闪避（2.5 秒）") {
                    engine.preview()
                }
                .disabled(!settings.isEnabled || engine.microphoneActive || engine.isDucked)
            }
        }
        .formStyle(.grouped)
    }

    private func durationSlider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 12) {
            Slider(value: value, in: range, step: step)
            Text(String(format: "%.2f 秒", value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

private struct PresetSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(DuckingPreset.all) { preset in
                    PresetRow(preset: preset, isActive: settings.activePreset == preset) {
                        settings.apply(preset)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PresetRow: View {
    let preset: DuckingPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                        .font(.headline)
                    Text(preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        String(
                            format: "淡入 %.2fs · 淡出 %.2fs · 延迟 %.2fs",
                            preset.attackDuration,
                            preset.releaseDuration,
                            preset.releaseDelay
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Text("\(Int((preset.duckLevel * 100).rounded()))%")
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(0.12)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
