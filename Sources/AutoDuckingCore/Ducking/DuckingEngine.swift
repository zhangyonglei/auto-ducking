import Combine
import CoreAudio
import Foundation

public protocol DuckingCancellable: AnyObject {
    func cancel()
}

public protocol OutputVolumeControlling: AnyObject {
    var deviceID: AudioObjectID { get }
    var deviceName: String? { get }
    var isAvailable: Bool { get }
    var onDeviceChange: (() -> Void)? { get set }

    func readVolume() -> Float?
    func writeVolume(_ value: Float)
    func readVolume(deviceID: AudioObjectID) -> Float?
    func writeVolume(_ value: Float, deviceID: AudioObjectID)
}

public protocol MicrophoneActivityProviding: AnyObject {
    var onActivityChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

public protocol DuckingScheduling: AnyObject {
    @discardableResult
    func after(_ delay: TimeInterval, _ action: @escaping () -> Void) -> DuckingCancellable

    @discardableResult
    func ramp(
        from start: Float,
        to target: Float,
        duration: TimeInterval,
        update: @escaping (Float) -> Void,
        completion: @escaping () -> Void
    ) -> DuckingCancellable
}

public enum DuckingStatus: Equatable {
    case disabled
    case idle
    case ducking
    case restoring
    case unavailable
}

public final class DuckingEngine: ObservableObject {
    @Published public private(set) var microphoneActive = false
    @Published public private(set) var isDucked = false
    @Published public private(set) var status: DuckingStatus = .idle
    @Published public private(set) var lastError: String?

    public let settings: SettingsStore
    private let output: OutputVolumeControlling
    private let scheduler: DuckingScheduling
    private let microphone: MicrophoneActivityProviding

    private var baseVolumes: [AudioObjectID: Float] = [:]
    private var activeDeviceID: AudioObjectID = 0
    private var restoreTask: DuckingCancellable?
    private var rampTask: DuckingCancellable?
    private var previewTask: DuckingCancellable?
    private var ducked = false
    private var restoring = false
    private var started = false

    public init(
        settings: SettingsStore,
        output: OutputVolumeControlling,
        scheduler: DuckingScheduling,
        microphone: MicrophoneActivityProviding
    ) {
        self.settings = settings
        self.output = output
        self.scheduler = scheduler
        self.microphone = microphone
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        activeDeviceID = output.deviceID

        microphone.onActivityChange = { [weak self] active in
            self?.microphoneDidChange(active)
        }
        microphone.start()

        output.onDeviceChange = { [weak self] in
            self?.outputDeviceDidChange()
        }

        settings.onSettingsChange = { [weak self] in
            self?.settingsDidChange()
        }

        refreshIdleStatus()
    }

    public func shutdown() {
        microphone.stop()
        microphone.onActivityChange = nil
        settings.onSettingsChange = nil
        output.onDeviceChange = nil
        restoreTask?.cancel()
        rampTask?.cancel()
        previewTask?.cancel()
        restoreTask = nil
        rampTask = nil
        previewTask = nil

        for (deviceID, volume) in baseVolumes {
            output.writeVolume(volume, deviceID: deviceID)
        }
        baseVolumes.removeAll()
        ducked = false
        isDucked = false
        restoring = false
    }

    // MARK: - User-facing state

    public var outputDeviceName: String {
        output.deviceName ?? "未知输出设备"
    }

    public var statusText: String {
        switch status {
        case .disabled:
            return "自动闪避已关闭"
        case .unavailable:
            return "当前输出设备无法调节音量"
        case .restoring:
            return "正在恢复背景音量"
        case .ducking:
            return microphoneActive ? "麦克风使用中 · 背景音量已降低" : "麦克风已停用 · 等待恢复"
        case .idle:
            return "待命 · 麦克风未使用"
        }
    }

    public var statusSymbol: String {
        switch status {
        case .disabled:
            return "pause.circle"
        case .unavailable:
            return "exclamationmark.triangle"
        case .restoring:
            return "speaker.wave.2"
        case .ducking:
            return microphoneActive ? "speaker.slash.fill" : "speaker.wave.1"
        case .idle:
            return "checkmark.circle"
        }
    }

    // MARK: - Microphone events

    func microphoneDidChange(_ active: Bool) {
        guard active != microphoneActive else { return }
        microphoneActive = active

        if active {
            beginDucking()
        } else if ducked {
            scheduleRestore()
        } else {
            refreshIdleStatus()
        }
    }

    // MARK: - Ducking

    private func beginDucking() {
        guard settings.isEnabled else {
            status = .disabled
            return
        }

        restoreTask?.cancel()
        restoreTask = nil
        previewTask?.cancel()
        previewTask = nil

        let deviceID = output.deviceID
        activeDeviceID = deviceID

        guard let currentVolume = output.readVolume(deviceID: deviceID) else {
            status = .unavailable
            lastError = "当前输出设备不支持音量调节"
            return
        }

        lastError = nil
        if baseVolumes[deviceID] == nil {
            baseVolumes[deviceID] = currentVolume
        }
        guard let baseVolume = baseVolumes[deviceID] else { return }

        let target = min(1, max(0, baseVolume * Float(settings.duckLevel)))
        ducked = true
        isDucked = true
        status = .ducking

        performRamp(
            from: currentVolume,
            to: target,
            duration: settings.attackDuration,
            deviceID: deviceID
        )
    }

    private func scheduleRestore() {
        restoreTask?.cancel()
        restoreTask = nil

        let delay = max(0, settings.releaseDelay)
        guard delay > 0.01 else {
            restore(animated: true)
            return
        }

        restoreTask = scheduler.after(delay) { [weak self] in
            guard let self else { return }
            self.restoreTask = nil
            guard !self.microphoneActive else { return }
            self.restore(animated: true)
        }
    }

    public func restore(animated: Bool = true) {
        restoreTask?.cancel()
        restoreTask = nil

        guard ducked else {
            refreshIdleStatus()
            return
        }

        guard let baseVolume = baseVolumes[activeDeviceID] else {
            finishRestore()
            return
        }

        restoring = true
        status = settings.isEnabled ? .restoring : .disabled

        let start = output.readVolume(deviceID: activeDeviceID) ?? baseVolume
        let duration = animated ? settings.releaseDuration : 0

        performRamp(
            from: start,
            to: baseVolume,
            duration: duration,
            deviceID: activeDeviceID
        ) { [weak self] in
            self?.finishRestore()
        }
    }

    private func finishRestore() {
        baseVolumes.removeValue(forKey: activeDeviceID)
        for (deviceID, volume) in baseVolumes {
            output.writeVolume(volume, deviceID: deviceID)
        }
        baseVolumes.removeAll()
        ducked = false
        isDucked = false
        restoring = false
        refreshIdleStatus()
    }

    private func performRamp(
        from start: Float,
        to target: Float,
        duration: TimeInterval,
        deviceID: AudioObjectID,
        completion: (() -> Void)? = nil
    ) {
        rampTask?.cancel()
        rampTask = nil

        if duration <= 0.01 || abs(target - start) < 0.005 {
            output.writeVolume(target, deviceID: deviceID)
            completion?()
            return
        }

        var finishedSynchronously = false
        let token = scheduler.ramp(
            from: start,
            to: target,
            duration: duration,
            update: { [weak self] value in
                self?.output.writeVolume(value, deviceID: deviceID)
            },
            completion: { [weak self] in
                finishedSynchronously = true
                self?.rampTask = nil
                completion?()
            }
        )
        if !finishedSynchronously {
            rampTask = token
        }
    }

    // MARK: - Settings and device changes

    func settingsDidChange() {
        guard started else { return }

        if !settings.isEnabled {
            restoreTask?.cancel()
            restoreTask = nil
            previewTask?.cancel()
            previewTask = nil
            if ducked {
                restore(animated: false)
            }
            status = .disabled
            return
        }

        if microphoneActive {
            beginDucking()
        } else if ducked && !restoring {
            scheduleRestore()
        } else if !ducked {
            refreshIdleStatus()
        }
    }

    func outputDeviceDidChange() {
        let newDeviceID = output.deviceID
        guard newDeviceID != activeDeviceID else { return }

        rampTask?.cancel()
        rampTask = nil
        restoreTask?.cancel()
        restoreTask = nil

        for (deviceID, volume) in baseVolumes {
            output.writeVolume(volume, deviceID: deviceID)
        }
        baseVolumes.removeAll()
        ducked = false
        isDucked = false
        restoring = false
        activeDeviceID = newDeviceID

        if settings.isEnabled && microphoneActive {
            beginDucking()
        } else {
            refreshIdleStatus()
        }
    }

    public func systemDidWake() {
        guard ducked else { return }
        if microphoneActive {
            beginDucking()
        } else {
            restore(animated: true)
        }
    }

    // MARK: - Preview

    public func preview() {
        guard settings.isEnabled, !microphoneActive, !ducked else { return }
        beginDucking()
        guard ducked else { return }

        previewTask?.cancel()
        previewTask = scheduler.after(2.5) { [weak self] in
            guard let self else { return }
            self.previewTask = nil
            guard !self.microphoneActive else { return }
            self.restore(animated: true)
        }
    }

    // MARK: - Helpers

    private func refreshIdleStatus() {
        status = settings.isEnabled ? .idle : .disabled
    }
}
