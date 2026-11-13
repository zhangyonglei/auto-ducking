import CoreAudio
import Foundation

public final class MicrophoneMonitor: MicrophoneActivityProviding {
    public var onActivityChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.zyl.AutoDucking.microphone-monitor")
    private var running = false
    private var lastActive: Bool?
    private var inputDevices: [AudioObjectID] = []
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {}

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.installDevicesListener()
            self.refreshDevices()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.removeAllListeners()
            self.lastActive = nil
        }
    }

    public func refresh() {
        queue.async { [weak self] in
            self?.refreshDevices()
        }
    }

    private func installDevicesListener() {
        var address = AudioDevices.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        if AudioObjectAddPropertyListenerBlock(AudioDevices.systemObject, &address, queue, block) == noErr {
            devicesListenerBlock = block
        }
    }

    private func refreshDevices() {
        guard running else { return }

        let currentDevices = AudioDevices.inputDeviceIDs()
        let deviceSet = Set(currentDevices)

        let removedDevices = deviceListeners.keys.filter { !deviceSet.contains($0) }
        for deviceID in removedDevices {
            if let block = deviceListeners.removeValue(forKey: deviceID) {
                var address = AudioDevices.runningSomewhereAddress
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
            }
        }

        for deviceID in currentDevices where deviceListeners[deviceID] == nil {
            var address = AudioDevices.runningSomewhereAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.evaluate()
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr {
                deviceListeners[deviceID] = block
            }
        }

        inputDevices = currentDevices
        evaluate()
    }

    private func evaluate() {
        guard running else { return }

        let active = inputDevices.contains { AudioDevices.isRunningSomewhere($0) }
        guard active != lastActive else { return }
        lastActive = active

        let handler = onActivityChange
        DispatchQueue.main.async {
            handler?(active)
        }
    }

    private func removeAllListeners() {
        for (deviceID, block) in deviceListeners {
            var address = AudioDevices.runningSomewhereAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        }
        deviceListeners.removeAll()
        inputDevices.removeAll()

        if let block = devicesListenerBlock {
            var address = AudioDevices.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioDevices.systemObject, &address, queue, block)
            devicesListenerBlock = nil
        }
    }
}
