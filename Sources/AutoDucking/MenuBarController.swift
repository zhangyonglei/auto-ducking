import AppKit
import AutoDuckingCore
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("AutoDucking")
        updateIcon()

        model.engine.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
            .store(in: &cancellables)

        model.settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
            .store(in: &cancellables)
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func updateIcon() {
        let symbol: String
        if !model.settings.isEnabled {
            symbol = "mic.slash"
        } else if model.engine.isConferenceAudio {
            symbol = "person.wave.2"
        } else {
            symbol = model.engine.isDucked ? "mic.fill" : "mic"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuWillOpen(_ menu: NSMenu) {
        populate(menu)
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let engine = model.engine
        let settings = model.settings

        let status = NSMenuItem(title: engine.statusText, action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: engine.statusSymbol, accessibilityDescription: nil)
        status.isEnabled = false
        menu.addItem(status)

        let device = NSMenuItem(title: "输出：\(engine.outputDeviceName)", action: nil, keyEquivalent: "")
        device.isEnabled = false
        menu.addItem(device)

        if engine.microphoneActive, let appName = model.microphoneAppName {
            let microphone = NSMenuItem(title: "麦克风：\(appName)", action: nil, keyEquivalent: "")
            microphone.isEnabled = false
            menu.addItem(microphone)
        }

        let level = NSMenuItem(
            title: "闪避后为原音量的 \(Int((engine.effectiveParameters.duckLevel * 100).rounded()))%",
            action: nil,
            keyEquivalent: ""
        )
        level.isEnabled = false
        menu.addItem(level)

        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "启用自动闪避", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.isEnabled ? .on : .off
        menu.addItem(enabled)

        let presetRoot = NSMenuItem(title: "预设", action: nil, keyEquivalent: "")
        presetRoot.submenu = makePresetMenu(current: settings.activePreset)
        menu.addItem(presetRoot)

        let preview = NSMenuItem(title: "测试闪避效果", action: #selector(previewDucking), keyEquivalent: "")
        preview.target = self
        preview.isEnabled = settings.isEnabled && !engine.microphoneActive && !engine.isDucked
        menu.addItem(preview)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let about = NSMenuItem(title: "关于 AutoDucking", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 AutoDucking", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makePresetMenu(current: DuckingPreset?) -> NSMenu {
        let presetMenu = NSMenu()
        presetMenu.autoenablesItems = false

        for preset in DuckingPreset.all {
            let item = NSMenuItem(title: preset.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = current == preset ? .on : .off
            presetMenu.addItem(item)
        }

        return presetMenu
    }

    @objc private func toggleEnabled() {
        model.settings.isEnabled.toggle()
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let preset = DuckingPreset.all.first(where: { $0.id == id }) else {
            return
        }
        model.settings.apply(preset)
    }

    @objc private func previewDucking() {
        model.engine.preview()
    }

    @objc private func openSettings() {
        model.openSettings()
    }

    @objc private func openAbout() {
        model.openAbout()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
