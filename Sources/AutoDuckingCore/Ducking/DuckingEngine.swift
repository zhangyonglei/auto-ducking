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
    case conference
}

public final class DuckingEngine: ObservableObject {
    @Published public private(set) var microphoneActive = false
    @Published public private(set) var isDucked = false
    @Published public private(set) var isConferenceAudio = false
    @Published public private(set) var microphoneApp: MicrophoneApp?
    @Published public private(set) var status: DuckingStatus = .idle
    @Published public private(set) var lastError: String?

    public let settings: SettingsStore
    private let output: OutputVolumeControlling
    private let scheduler: DuckingScheduling
    private let microphone: MicrophoneActivityProviding
    private let conferenceAudio: ConferenceAudioDetecting

    private var baseVolumes: [AudioObjectID: Float] = [:]
    private var activeDeviceID: AudioObjectID = 0
    private var restoreTask: DuckingCancellable?
    private var rampTask: DuckingCancellable?
    private var previewTask: DuckingCancellable?
    private var sessionParameters: DuckingParameters?
    private var ducked = false
    private var restoring = false
    private var started = false

    public init(
        settings: SettingsStore,
        output: OutputVolumeControlling,
        scheduler: DuckingScheduling,
        microphone: MicrophoneActivityProviding,
        conferenceAudio: ConferenceAudioDetecting
    ) {
        self.settings = settings
        self.output = output
        self.scheduler = scheduler
        self.microphone = microphone
        self.conferenceAudio = conferenceAudio
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

        conferenceAudio.onConferenceAudioChange = { [weak self] active in
            self?.conferenceAudioDidChange(active)
        }
        conferenceAudio.onMicrophoneOwnerChange = { [weak self] app in
            self?.microphoneAppDidChange(app)
        }

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
        conferenceAudio.stopMonitoring()
        conferenceAudio.onConferenceAudioChange = nil
        conferenceAudio.onMicrophoneOwnerChange = nil
        settings.onSettingsChange = nil
        output.onDeviceChange = nil
        restoreTask?.cancel()
        rampTask?.cancel()
        previewTask?.cancel()
        restoreTask = nil
        rampTask = nil
        previewTask = nil
        sessionParameters = nil

        for (deviceID, volume) in baseVolumes {
            output.writeVolume(volume, deviceID: deviceID)
        }
        baseVolumes.removeAll()
        ducked = false
        isDucked = false
        isConferenceAudio = false
        microphoneApp = nil
        restoring = false
    }

    // MARK: - User-facing state

    public var outputDeviceName: String {
        output.deviceName ?? "未知输出设备"
    }

    /// 当前生效的闪避参数：识别到麦克风占用方且配置了应用规则时，使用该应用的规则。
    public var effectiveParameters: DuckingParameters {
        settings.parameters(for: microphoneApp?.bundleIDs ?? [])
    }

    public var statusText: String {
        switch status {
        case .disabled:
            return "自动闪避已关闭"
        case .unavailable:
            return "当前输出设备无法调节音量"
        case .conference:
            return "会议通话中 · 保持原音量"
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
        case .conference:
            return "person.wave.2"
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
            isConferenceAudio = false
            microphoneApp = nil
            sessionParameters = nil
            refreshMonitoring()
            beginDucking()
        } else {
            conferenceAudio.stopMonitoring()
            isConferenceAudio = false
            microphoneApp = nil
            if ducked {
                scheduleRestore()
            } else {
                refreshIdleStatus()
            }
        }
    }

    private func refreshMonitoring() {
        guard settings.isEnabled, microphoneActive else {
            conferenceAudio.stopMonitoring()
            return
        }

        if isConferenceAudio {
            conferenceAudio.stopMonitoring()
            return
        }

        // 占用方尚未识别时先枚举一次；识别后只在需要判断会议通话（保持原音量）时继续轮询。
        if let app = microphoneApp, !settings.parameters(for: app.bundleIDs).bypassOriginalVolume {
            conferenceAudio.stopMonitoring()
            return
        }

        conferenceAudio.startMonitoring()
    }

    func microphoneAppDidChange(_ app: MicrophoneApp) {
        guard settings.isEnabled, microphoneActive else { return }
        guard app != microphoneApp else { return }
        microphoneApp = app

        if !settings.parameters(for: app.bundleIDs).bypassOriginalVolume {
            conferenceAudio.stopMonitoring()
            isConferenceAudio = false
        }

        beginDucking()
    }

    func conferenceAudioDidChange(_ active: Bool) {
        guard settings.isEnabled,
              microphoneActive,
              active != isConferenceAudio else {
            return
        }

        guard effectiveParameters.bypassOriginalVolume else {
            isConferenceAudio = false
            return
        }

        isConferenceAudio = active

        if active {
            conferenceAudio.stopMonitoring()
            if ducked {
                restore(animated: true)
            } else {
                refreshIdleStatus()
            }
        } else if settings.isEnabled {
            beginDucking()
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

        guard !isConferenceAudio else {
            refreshIdleStatus()
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

        let parameters = effectiveParameters
        sessionParameters = parameters

        let target = min(1, max(0, baseVolume * Float(parameters.duckLevel)))
        ducked = true
        isDucked = true
        restoring = false
        status = .ducking

        performRamp(
            from: currentVolume,
            to: target,
            duration: parameters.attackDuration,
            deviceID: deviceID
        )
    }

    private func scheduleRestore() {
        restoreTask?.cancel()
        restoreTask = nil

        let delay = max(0, sessionParameters?.releaseDelay ?? settings.releaseDelay)
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
        if !settings.isEnabled {
            status = .disabled
        } else if isConferenceAudio {
            status = .conference
        } else {
            status = .restoring
        }

        let start = output.readVolume(deviceID: activeDeviceID) ?? baseVolume
        let duration = animated ? (sessionParameters?.releaseDuration ?? settings.releaseDuration) : 0

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
        sessionParameters = nil
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
            conferenceAudio.stopMonitoring()
            isConferenceAudio = false
            microphoneApp = nil
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

        refreshMonitoring()

        if isConferenceAudio && !effectiveParameters.bypassOriginalVolume {
            isConferenceAudio = false
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
        sessionParameters = nil
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
        guard settings.isEnabled, !microphoneActive, !ducked, !isConferenceAudio else { return }
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
        if !settings.isEnabled {
            status = .disabled
        } else if isConferenceAudio {
            status = .conference
        } else {
            status = .idle
        }
    }
}
