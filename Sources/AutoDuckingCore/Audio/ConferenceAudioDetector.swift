import CoreAudio
import Foundation

public struct MicrophoneApp: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public let bundleIDs: [String]

    public init(pid: pid_t, bundleID: String?, bundleIDs: [String]) {
        self.pid = pid
        self.bundleID = bundleID
        self.bundleIDs = bundleIDs
    }
}

public protocol ConferenceAudioDetecting: AnyObject {
    var onConferenceAudioChange: ((Bool) -> Void)? { get set }
    var onMicrophoneOwnerChange: ((MicrophoneApp) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
}

/// 会议通话检测：麦克风占用方同时在播放音频时回调 true。
///
/// 只在麦克风使用期间工作。启动时枚举一次进程列表，定位占用麦克风的进程并缓存其同族进程，
/// 之后仅轮询这些进程的输出状态（每次数百微秒）；确认连续两次采样都在放音后回调并停止，
/// 避免在会议里把对方人声压低。
public final class SystemConferenceAudioDetector: ConferenceAudioDetecting {
    public var onConferenceAudioChange: ((Bool) -> Void)?
    public var onMicrophoneOwnerChange: ((MicrophoneApp) -> Void)?

    private let queue = DispatchQueue(label: "com.zyl.AutoDucking.conference-detector")
    private var timer: DispatchSourceTimer?
    private var listListener: AudioObjectPropertyListenerBlock?
    private var monitoring = false
    private var familyObjectIDs: [AudioObjectID] = []
    private var matchedTicks = 0
    private var tickCount = 0
    private var reportedOwner: MicrophoneApp?

    private static let pollInterval: TimeInterval = 0.35
    private static let requiredMatches = 2
    private static let ownerRefreshTicks = 6

    public init() {}

    public func startMonitoring() {
        queue.async { [weak self] in
            guard let self, !self.monitoring else { return }
            self.monitoring = true
            self.matchedTicks = 0
            self.tickCount = 0
            self.familyObjectIDs = []
            self.reportedOwner = nil
            ProcessTree.resetCache()
            self.installProcessListListener()
            self.refreshFamily()
            self.startTimer()
        }
    }

    public func stopMonitoring() {
        queue.async { [weak self] in
            guard let self, self.monitoring else { return }
            self.stop()
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval,
            leeway: .milliseconds(120)
        )
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    private func stop() {
        monitoring = false
        timer?.cancel()
        timer = nil
        removeProcessListListener()
        familyObjectIDs = []
        matchedTicks = 0
        tickCount = 0
    }

    private func tick() {
        guard monitoring else { return }
        tickCount += 1

        guard !familyObjectIDs.isEmpty else {
            if tickCount % Self.ownerRefreshTicks == 0 {
                refreshFamily()
            }
            return
        }

        guard familyObjectIDs.contains(where: AudioProcesses.isRunningOutput(objectID:)) else {
            matchedTicks = 0
            return
        }

        matchedTicks += 1
        guard matchedTicks >= Self.requiredMatches else { return }

        stop()
        report()
    }

    private func refreshFamily() {
        guard monitoring else { return }

        let clients = AudioProcesses.snapshot()
        let owners = clients.filter(\.isRunningInput)
        guard let owner = owners.first else { return }

        var members: Set<AudioObjectID> = []
        for candidate in owners {
            for member in AudioProcesses.familyMembers(of: candidate, in: clients) {
                members.insert(member.objectID)
            }
        }
        familyObjectIDs = members.sorted()
        reportOwnerIfNeeded(owner, in: clients)
    }

    private func reportOwnerIfNeeded(_ owner: AudioClientProcess, in clients: [AudioClientProcess]) {
        let family = AudioProcesses.familyMembers(of: owner, in: clients)
        let bundleIDs = Set(family.compactMap(\.bundleID).filter { !$0.isEmpty }).sorted()
        let app = MicrophoneApp(pid: owner.pid, bundleID: owner.bundleID, bundleIDs: bundleIDs)
        guard app != reportedOwner else { return }
        reportedOwner = app

        DispatchQueue.main.async { [weak self] in
            self?.onMicrophoneOwnerChange?(app)
        }
    }

    private func report() {
        DispatchQueue.main.async { [weak self] in
            self?.onConferenceAudioChange?(true)
        }
    }

    private func installProcessListListener() {
        guard listListener == nil else { return }

        var address = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshFamily()
        }
        if AudioObjectAddPropertyListenerBlock(AudioDevices.systemObject, &address, queue, block) == noErr {
            listListener = block
        }
    }

    private func removeProcessListListener() {
        guard let block = listListener else { return }
        var address = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(AudioDevices.systemObject, &address, queue, block)
        listListener = nil
    }
}
