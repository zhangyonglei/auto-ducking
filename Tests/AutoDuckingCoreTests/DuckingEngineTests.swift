import CoreAudio
import XCTest
@testable import AutoDuckingCore

final class FakeOutputVolume: OutputVolumeControlling {
    var deviceID: AudioObjectID
    var deviceName: String?
    var onDeviceChange: (() -> Void)?
    var volumes: [AudioObjectID: Float]

    init(deviceID: AudioObjectID = 1, volume: Float) {
        self.deviceID = deviceID
        self.deviceName = "Fake Output"
        self.volumes = [deviceID: volume]
    }

    var isAvailable: Bool {
        volumes[deviceID] != nil
    }

    func readVolume() -> Float? {
        volumes[deviceID]
    }

    func writeVolume(_ value: Float) {
        volumes[deviceID] = value
    }

    func readVolume(deviceID: AudioObjectID) -> Float? {
        volumes[deviceID]
    }

    func writeVolume(_ value: Float, deviceID: AudioObjectID) {
        volumes[deviceID] = value
    }
}

final class FakeMicrophoneMonitor: MicrophoneActivityProviding {
    var onActivityChange: ((Bool) -> Void)?
    var isRunning = false

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

final class TestScheduler: DuckingScheduling {
    private final class Token: DuckingCancellable {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private struct TimedAction {
        let delay: TimeInterval
        let action: () -> Void
        let token: Token
    }

    struct Ramp {
        let start: Float
        let target: Float
        let duration: TimeInterval
    }

    private var timedActions: [TimedAction] = []
    private(set) var ramps: [Ramp] = []

    func after(_ delay: TimeInterval, _ action: @escaping () -> Void) -> DuckingCancellable {
        let token = Token()
        timedActions.append(TimedAction(delay: delay, action: action, token: token))
        return token
    }

    func ramp(
        from start: Float,
        to target: Float,
        duration: TimeInterval,
        update: @escaping (Float) -> Void,
        completion: @escaping () -> Void
    ) -> DuckingCancellable {
        ramps.append(Ramp(start: start, target: target, duration: duration))
        update(target)
        completion()
        return Token()
    }

    func fireScheduledActions() {
        let actions = timedActions
        timedActions.removeAll()
        for action in actions where !action.token.isCancelled {
            action.action()
        }
    }

    var pendingDelays: [TimeInterval] {
        timedActions.filter { !$0.token.isCancelled }.map(\.delay)
    }
}

final class DuckingEngineTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var output: FakeOutputVolume!
    private var scheduler: TestScheduler!
    private var monitor: FakeMicrophoneMonitor!
    private var engine: DuckingEngine!

    override func setUp() {
        super.setUp()

        suiteName = "AutoDuckingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
        settings.apply(.standard)
        settings.attackDuration = 0
        settings.releaseDuration = 0
        settings.releaseDelay = 0.8

        output = FakeOutputVolume(deviceID: 1, volume: 0.8)
        scheduler = TestScheduler()
        monitor = FakeMicrophoneMonitor()
        engine = DuckingEngine(
            settings: settings,
            output: output,
            scheduler: scheduler,
            microphone: monitor
        )
        engine.start()
    }

    override func tearDown() {
        engine.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMicrophoneActivationLowersVolumeToRelativeLevel() {
        engine.microphoneDidChange(true)

        XCTAssertEqual(output.volumes[1] ?? -1, 0.24, accuracy: 0.0001)
        XCTAssertTrue(engine.isDucked)
        XCTAssertEqual(engine.status, .ducking)
        XCTAssertTrue(engine.microphoneActive)
    }

    func testRestoreWaitsForReleaseDelay() {
        engine.microphoneDidChange(true)
        engine.microphoneDidChange(false)

        XCTAssertEqual(output.volumes[1] ?? -1, 0.24, accuracy: 0.0001)
        XCTAssertEqual(scheduler.pendingDelays, [0.8])
        XCTAssertTrue(engine.isDucked)

        scheduler.fireScheduledActions()

        XCTAssertEqual(output.volumes[1] ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertFalse(engine.isDucked)
        XCTAssertEqual(engine.status, .idle)
    }

    func testReactivationCancelsPendingRestore() {
        engine.microphoneDidChange(true)
        engine.microphoneDidChange(false)
        engine.microphoneDidChange(true)

        scheduler.fireScheduledActions()

        XCTAssertEqual(output.volumes[1] ?? -1, 0.24, accuracy: 0.0001)
        XCTAssertTrue(engine.isDucked)
        XCTAssertEqual(engine.status, .ducking)
    }

    func testZeroReleaseDelayRestoresImmediately() {
        settings.releaseDelay = 0

        engine.microphoneDidChange(true)
        engine.microphoneDidChange(false)

        XCTAssertEqual(output.volumes[1] ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertFalse(engine.isDucked)
    }

    func testDisabledEngineDoesNotDuck() {
        settings.isEnabled = false

        engine.microphoneDidChange(true)

        XCTAssertEqual(output.volumes[1] ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertFalse(engine.isDucked)
        XCTAssertEqual(engine.status, .disabled)
    }

    func testDisablingWhileDuckedRestoresImmediately() {
        engine.microphoneDidChange(true)
        XCTAssertTrue(engine.isDucked)

        settings.isEnabled = false

        XCTAssertEqual(output.volumes[1] ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertFalse(engine.isDucked)
        XCTAssertEqual(engine.status, .disabled)
    }

    func testFadeUsesConfiguredDurationAndTarget() {
        settings.attackDuration = 0.4

        engine.microphoneDidChange(true)

        XCTAssertEqual(scheduler.ramps.count, 1)
        XCTAssertEqual(scheduler.ramps[0].start, 0.8, accuracy: 0.0001)
        XCTAssertEqual(scheduler.ramps[0].target, 0.24, accuracy: 0.0001)
        XCTAssertEqual(scheduler.ramps[0].duration, 0.4, accuracy: 0.0001)
    }

    func testOutputDeviceChangeRestoresOldDeviceAndDucksNewDevice() {
        engine.microphoneDidChange(true)

        output.volumes[2] = 0.5
        output.deviceID = 2
        engine.outputDeviceDidChange()

        XCTAssertEqual(output.volumes[1] ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(output.volumes[2] ?? -1, 0.15, accuracy: 0.0001)
        XCTAssertTrue(engine.isDucked)

        engine.microphoneDidChange(false)
        scheduler.fireScheduledActions()

        XCTAssertEqual(output.volumes[2] ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertFalse(engine.isDucked)
    }

    func testDuckLevelChangeRetargetsWhileMicrophoneIsActive() {
        engine.microphoneDidChange(true)
        settings.duckLevel = 0.5

        XCTAssertEqual(output.volumes[1] ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertTrue(engine.isDucked)
    }

    func testUnavailableOutputDoesNotReportDucking() {
        output.volumes.removeAll()

        engine.microphoneDidChange(true)

        XCTAssertFalse(engine.isDucked)
        XCTAssertEqual(engine.status, .unavailable)
        XCTAssertNotNil(engine.lastError)
    }

    func testPreviewDucksAndRestores() {
        engine.preview()

        XCTAssertEqual(output.volumes[1] ?? -1, 0.24, accuracy: 0.0001)
        XCTAssertTrue(engine.isDucked)

        scheduler.fireScheduledActions()

        XCTAssertEqual(output.volumes[1] ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertFalse(engine.isDucked)
    }

    func testShutdownRestoresDuckedVolume() {
        engine.microphoneDidChange(true)
        engine.shutdown()

        XCTAssertEqual(output.volumes[1] ?? -1, 0.8, accuracy: 0.0001)
    }
}

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "AutoDuckingSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testApplyingPresetUpdatesAllValuesAndIsDetected() {
        store.apply(.voice)

        XCTAssertEqual(store.activePreset, .voice)
        XCTAssertEqual(store.duckLevel, DuckingPreset.voice.duckLevel, accuracy: 0.0001)
        XCTAssertEqual(store.attackDuration, DuckingPreset.voice.attackDuration, accuracy: 0.0001)
        XCTAssertEqual(store.releaseDuration, DuckingPreset.voice.releaseDuration, accuracy: 0.0001)
        XCTAssertEqual(store.releaseDelay, DuckingPreset.voice.releaseDelay, accuracy: 0.0001)
    }

    func testManualChangeProducesCustomPreset() {
        store.apply(.standard)
        store.duckLevel = 0.42

        XCTAssertNil(store.activePreset)
    }

    func testValuesPersistAcrossInstances() {
        store.duckLevel = 0.45
        store.releaseDelay = 2.5

        let reloaded = SettingsStore(defaults: defaults)

        XCTAssertEqual(reloaded.duckLevel, 0.45, accuracy: 0.0001)
        XCTAssertEqual(reloaded.releaseDelay, 2.5, accuracy: 0.0001)
        XCTAssertEqual(reloaded.activePreset, nil)
    }

    func testOutOfRangeStoredValueIsClamped() {
        defaults.set(12.0, forKey: "autoDucking.duckLevel")
        defaults.set(-3.0, forKey: "autoDucking.releaseDelay")

        let reloaded = SettingsStore(defaults: defaults)

        XCTAssertEqual(reloaded.duckLevel, SettingsStore.duckLevelRange.upperBound, accuracy: 0.0001)
        XCTAssertEqual(reloaded.releaseDelay, SettingsStore.releaseDelayRange.lowerBound, accuracy: 0.0001)
    }
}
