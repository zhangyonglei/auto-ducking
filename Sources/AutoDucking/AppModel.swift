import AppKit
import AutoDuckingCore
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct RecentMicrophoneApp: Identifiable, Hashable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

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
    @Published private(set) var recentMicrophoneApps: [RecentMicrophoneApp] = []

    private var started = false
    private var wakeObserver: NSObjectProtocol?
    private var microphoneAppObserver: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    private static let recentAppLimit = 12

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

        super.init()

        microphoneAppObserver = engine.$microphoneApp
            .receive(on: RunLoop.main)
            .sink { [weak self] app in
                guard let app else { return }
                Task { @MainActor in
                    self?.recordMicrophoneApp(app)
                }
            }
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
        microphoneAppObserver?.cancel()
        microphoneAppObserver = nil
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

    // MARK: - Per-app rules

    var microphoneAppName: String? {
        guard let app = engine.microphoneApp else { return nil }
        if let bundleID = app.bundleID, let name = Self.displayName(forBundleID: bundleID) {
            return name
        }
        for bundleID in app.bundleIDs {
            if let name = Self.displayName(forBundleID: bundleID) {
                return name
            }
        }
        if let running = NSRunningApplication(processIdentifier: app.pid) {
            return running.localizedName
        }
        return nil
    }

    func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func promptForAppRule() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择要单独设置闪避规则的应用"
        panel.prompt = "添加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addAppRule(at: url)
    }

    func addAppRule(at url: URL) {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        settings.setRule(AppDuckingRule(bundleID: bundleID, name: name))
    }

    private func recordMicrophoneApp(_ app: MicrophoneApp) {
        guard let resolved = Self.resolve(app) else { return }
        recentMicrophoneApps.removeAll { $0.bundleID == resolved.bundleID }
        recentMicrophoneApps.insert(resolved, at: 0)
        if recentMicrophoneApps.count > Self.recentAppLimit {
            recentMicrophoneApps.removeLast(recentMicrophoneApps.count - Self.recentAppLimit)
        }
    }

    private static func resolve(_ app: MicrophoneApp) -> RecentMicrophoneApp? {
        for bundleID in app.bundleIDs {
            if let name = displayName(forBundleID: bundleID) {
                return RecentMicrophoneApp(bundleID: bundleID, name: name)
            }
        }
        guard let bundleID = app.bundleID, !bundleID.isEmpty else { return nil }
        if let running = NSRunningApplication(processIdentifier: app.pid),
           let name = running.localizedName {
            return RecentMicrophoneApp(bundleID: bundleID, name: name)
        }
        return RecentMicrophoneApp(bundleID: bundleID, name: bundleID)
    }

    private static func displayName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
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
