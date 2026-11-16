import AppKit
import AutoDuckingCore
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: NSObject, ObservableObject {
    static let shared = AppModel()

    let settings: SettingsStore
    let output: SystemOutputVolume
    let microphone: MicrophoneMonitor
    let conferenceAudio: SystemConferenceAudioDetector
    let engine: DuckingEngine

    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginError: String?

    private var started = false
    private var wakeObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    private override init() {
        let settings = SettingsStore()
        let output = SystemOutputVolume()
        let microphone = MicrophoneMonitor()
        let conferenceAudio = SystemConferenceAudioDetector()

        self.settings = settings
        self.output = output
        self.microphone = microphone
        self.conferenceAudio = conferenceAudio
        self.engine = DuckingEngine(
            settings: settings,
            output: output,
            scheduler: SystemDuckingScheduler(),
            microphone: microphone,
            conferenceAudio: conferenceAudio
        )
    }

    func start() {
        guard !started else { return }
        started = true
        engine.start()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.engine.systemDidWake()
            }
        }
    }

    func shutdown() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        engine.shutdown()
    }

    // MARK: - Windows

    func openSettings() {
        refreshLaunchAtLogin()

        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(settings: settings, engine: engine, app: self)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.setContentSize(SettingsWindowMetrics.contentSize)
            window.delegate = self
            settingsWindow = window
        }

        show(settingsWindow)
    }

    func openAbout() {
        if aboutWindow == nil {
            let hosting = NSHostingController(
                rootView: AboutView(onClose: { [weak self] in self?.aboutWindow?.close() })
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "关于 AutoDucking"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            let fittingSize = hosting.view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                window.setContentSize(fittingSize)
            }
            aboutWindow = window
        }

        show(aboutWindow)
    }

    private func show(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            launchAtLogin = Self.isLaunchAtLoginActive
            if SMAppService.mainApp.status == .requiresApproval {
                launchAtLoginError = "已加入登录项，需要在“系统设置 › 通用 › 登录项”中允许 AutoDucking。"
            } else {
                launchAtLoginError = nil
            }
        } catch {
            launchAtLogin = Self.isLaunchAtLoginActive
            launchAtLoginError = "无法更新登录项：\(error.localizedDescription)"
        }
    }

    private func refreshLaunchAtLogin() {
        let active = Self.isLaunchAtLoginActive
        if active != launchAtLogin {
            launchAtLogin = active
        }
    }

    private static var isLaunchAtLoginActive: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
}

extension AppModel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
        }
        if window === aboutWindow {
            aboutWindow = nil
        }
    }
}
