import AppKit
import Darwin

enum SingleInstanceGuard {
    private static var lockDescriptor: Int32 = -1

    /// 获取进程级排他锁；已有实例持锁时返回 false。
    static func acquire() -> Bool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.zyl.AutoDucking.lock").path
        let descriptor = path.withCString { open($0, O_CREAT | O_RDWR, mode_t(0o644)) }
        guard descriptor >= 0 else { return true }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        lockDescriptor = descriptor
        return true
    }

    /// 把已运行的同一应用带到前台；找不到时静默返回。
    static func activateRunningInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != currentPID }
        _ = existing?.activate()
    }
}
