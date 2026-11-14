import AppKit

guard SingleInstanceGuard.acquire() else {
    SingleInstanceGuard.activateRunningInstance()
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
