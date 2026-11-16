import CoreAudio
import Foundation

struct AudioClientProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

/// CoreAudio 进程对象：用来判断「同一个应用既占用麦克风、又在播放音频」。
/// 这类场景下降音量会把会议里对方的人声一起压低，因此需要跳过闪避。
enum AudioProcesses {
    static func snapshot() -> [AudioClientProcess] {
        var address = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioDevices.systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioDevices.systemObject,
            &address,
            0,
            nil,
            &size,
            &objects
        ) == noErr else {
            return []
        }

        return objects.compactMap(clientProcess(objectID:))
    }

    static func isRunningOutput(objectID: AudioObjectID) -> Bool {
        flag(of: objectID, selector: kAudioProcessPropertyIsRunningOutput)
    }

    /// 与给定进程同属一个应用的所有进程：同进程、同一 bundle（含 helper 子进程）、或共享祖先进程。
    static func familyMembers(
        of owner: AudioClientProcess,
        in clients: [AudioClientProcess]
    ) -> [AudioClientProcess] {
        clients.filter { representsSameApplication(owner, $0) }
    }

    static func representsSameApplication(_ a: AudioClientProcess, _ b: AudioClientProcess) -> Bool {
        if a.objectID == b.objectID || a.pid == b.pid {
            return true
        }

        if let left = normalizedBundleID(a.bundleID), let right = normalizedBundleID(b.bundleID) {
            if left == right || left.hasPrefix(right + ".") || right.hasPrefix(left + ".") {
                return true
            }
        }

        return ProcessTree.shareAncestor(a.pid, b.pid)
    }

    private static func clientProcess(objectID: AudioObjectID) -> AudioClientProcess? {
        guard let pid = pid(of: objectID) else { return nil }

        return AudioClientProcess(
            objectID: objectID,
            pid: pid,
            bundleID: bundleID(of: objectID),
            isRunningInput: flag(of: objectID, selector: kAudioProcessPropertyIsRunningInput),
            isRunningOutput: flag(of: objectID, selector: kAudioProcessPropertyIsRunningOutput)
        )
    }

    private static func normalizedBundleID(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    private static func pid(of objectID: AudioObjectID) -> pid_t? {
        var address = AudioDevices.address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func bundleID(of objectID: AudioObjectID) -> String? {
        var address = AudioDevices.address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private static func flag(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = AudioDevices.address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}

/// 进程父子关系，用于识别由主程序派生的音频子进程（如 Zoom 的独立音频宿主）。
enum ProcessTree {
    private static let lock = NSLock()
    private static var parents: [pid_t: pid_t] = [:]

    static func resetCache() {
        lock.lock()
        parents.removeAll()
        lock.unlock()
    }

    static func shareAncestor(_ a: pid_t, _ b: pid_t) -> Bool {
        guard a > 1, b > 1 else { return false }
        return !Set(ancestors(of: a)).isDisjoint(with: Set(ancestors(of: b)))
    }

    static func ancestors(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var current = parent(of: pid)
        while current > 1, result.count < 8, !result.contains(current) {
            result.append(current)
            current = parent(of: current)
        }
        return result
    }

    private static func parent(of pid: pid_t) -> pid_t {
        lock.lock()
        let cached = parents[pid]
        lock.unlock()
        if let cached {
            return cached
        }

        let value = readParent(of: pid)

        lock.lock()
        parents[pid] = value
        lock.unlock()
        return value
    }

    private static func readParent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return 0
        }
        return info.kp_eproc.e_ppid
    }
}
