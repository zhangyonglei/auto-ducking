import AppKit
import AutoDuckingCore
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings: SettingsStore
    let output: SystemOutputVolume
    let microphone: MicrophoneMonitor
    let engine: DuckingEngine

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    private var started = false
    private var wakeObserver: NSObjectProtocol?

    private init() {
        let settings = SettingsStore()
        let output = SystemOutputVolume()
        let microphone = MicrophoneMonitor()

        self.settings = settings
        self.output = output
        self.microphone = microphone
        self.engine = DuckingEngine(
            settings: settings,
            output: output,
            scheduler: SystemDuckingScheduler(),
            microphone: microphone
        )
        self.launchAtLogin = Self.isLaunchAtLoginActive
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

    private static var isLaunchAtLoginActive: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
}
