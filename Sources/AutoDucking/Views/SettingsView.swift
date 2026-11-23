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

            AppRulesSettingsView(settings: settings, engine: engine, app: app)
                .tabItem { Label("应用", systemImage: "app.badge") }
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
                Text("检测到麦克风被占用时降低系统输出音量，结束后恢复。QQ、钉钉、微信等会议通话中若麦克风与播放来自同一个应用，会保持原音量，避免压低对方人声。可在「应用」页为单个应用单独指定预设与是否保持原音量。")
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

private struct AppRulesSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: DuckingEngine
    @ObservedObject var app: AppModel

    struct Entry: Identifiable {
        let bundleID: String
        let name: String

        var id: String { bundleID }
    }

    private var entries: [Entry] {
        var result = settings.appRules.map { Entry(bundleID: $0.bundleID, name: $0.name) }
        let configured = Set(settings.appRules.map(\.bundleID))
        for recent in app.recentMicrophoneApps where !configured.contains(recent.bundleID) {
            result.append(Entry(bundleID: recent.bundleID, name: recent.name))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("应用规则")
                        .font(.headline)
                    Text("为单个应用指定闪避预设，并决定通话时是否保持原音量。未设置的应用跟随「通用」页。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("添加应用…") {
                    app.promptForAppRule()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("还没有应用使用过麦克风")
                        .font(.callout)
                    Text("应用使用麦克风后会出现在这里，也可以点「添加应用…」手动选择。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    AppRuleRow(entry: entry, settings: settings, engine: engine, app: app)
                        .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AppRuleRow: View {
    let entry: AppRulesSettingsView.Entry
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: DuckingEngine
    let app: AppModel

    private var rule: AppDuckingRule? {
        settings.appRules.first { $0.bundleID == entry.bundleID }
    }

    private var isCurrentMicrophoneApp: Bool {
        guard let microphoneApp = engine.microphoneApp else { return false }
        return microphoneApp.bundleIDs.contains { candidate in
            candidate == entry.bundleID
                || candidate.hasPrefix(entry.bundleID + ".")
                || entry.bundleID.hasPrefix(candidate + ".")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if isCurrentMicrophoneApp && engine.microphoneActive {
                        Text("当前")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                HStack(spacing: 12) {
                    pickerGroup("闪避") {
                        Picker("闪避方案", selection: presetBinding) {
                            Text("跟随全局").tag(String?.none)
                            ForEach(DuckingPreset.all) { preset in
                                Text(preset.name).tag(String?.some(preset.id))
                            }
                        }
                        .frame(width: 106)
                    }

                    pickerGroup("原音量") {
                        Picker("通话原音量", selection: bypassBinding) {
                            Text("跟随全局").tag(Bool?.none)
                            Text("保持").tag(Bool?.some(true))
                            Text("闪避").tag(Bool?.some(false))
                        }
                        .frame(width: 96)
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                settings.removeRule(bundleID: entry.bundleID)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("移除规则，改为跟随全局设置")
            .opacity(rule == nil ? 0 : 1)
            .disabled(rule == nil)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = app.icon(forBundleID: entry.bundleID) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "app")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }

    private func pickerGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
        }
    }

    private var presetBinding: Binding<String?> {
        Binding(
            get: { rule?.presetID },
            set: { newValue in
                var updated = rule ?? AppDuckingRule(bundleID: entry.bundleID, name: entry.name)
                updated.presetID = newValue
                save(updated)
            }
        )
    }

    private var bypassBinding: Binding<Bool?> {
        Binding(
            get: { rule?.bypassOriginalVolume },
            set: { newValue in
                var updated = rule ?? AppDuckingRule(bundleID: entry.bundleID, name: entry.name)
                updated.bypassOriginalVolume = newValue
                save(updated)
            }
        )
    }

    private func save(_ updated: AppDuckingRule) {
        if updated.presetID == nil && updated.bypassOriginalVolume == nil {
            settings.removeRule(bundleID: entry.bundleID)
        } else {
            settings.setRule(updated)
        }
    }
}
