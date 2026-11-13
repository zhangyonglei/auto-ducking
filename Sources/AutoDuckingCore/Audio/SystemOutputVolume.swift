import CoreAudio
import Foundation

public final class SystemOutputVolume: OutputVolumeControlling {
    public private(set) var deviceID: AudioObjectID = 0
    public private(set) var deviceName: String?
    public var onDeviceChange: (() -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    public init() {
        refreshDevice()
        installListener()
    }

    deinit {
        removeListener()
    }

    public var isAvailable: Bool {
        readVolume() != nil
    }

    public func readVolume() -> Float? {
        readVolume(deviceID: deviceID)
    }

    public func writeVolume(_ value: Float) {
        writeVolume(value, deviceID: deviceID)
    }

    public func readVolume(deviceID: AudioObjectID) -> Float? {
        guard deviceID != 0 else { return nil }

        if let volume = scalarVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return volume
        }

        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .compactMap { scalarVolume(deviceID: deviceID, element: $0) }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float(channels.count)
    }

    public func writeVolume(_ value: Float, deviceID: AudioObjectID) {
        guard deviceID != 0 else { return }

        let clamped = min(1, max(0, value))
        if setScalarVolume(clamped, deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return
        }
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            _ = setScalarVolume(clamped, deviceID: deviceID, element: element)
        }
    }

    private func scalarVolume(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var address = AudioDevices.address(
            kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return min(1, max(0, value))
    }

    @discardableResult
    private func setScalarVolume(
        _ value: Float,
        deviceID: AudioObjectID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioDevices.address(
            kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var newValue = value
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newValue) == noErr
    }

    private func refreshDevice() {
        let newDeviceID = AudioDevices.defaultOutputDevice()
        deviceID = newDeviceID
        deviceName = newDeviceID != 0 ? AudioDevices.name(of: newDeviceID) : nil
    }

    private func installListener() {
        var address = AudioDevices.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshDevice()
            self.onDeviceChange?()
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioDevices.systemObject,
            &address,
            DispatchQueue.main,
            block
        ) == noErr {
            listenerBlock = block
        }
    }

    private func removeListener() {
        guard let block = listenerBlock else { return }
        var address = AudioDevices.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioDevices.systemObject, &address, DispatchQueue.main, block)
        listenerBlock = nil
    }
}
