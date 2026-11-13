import CoreAudio
import Foundation

enum AudioDevices {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static var devicesAddress: AudioObjectPropertyAddress {
        address(kAudioHardwarePropertyDevices)
    }

    static var runningSomewhereAddress: AudioObjectPropertyAddress {
        address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    }

    static var defaultOutputAddress: AudioObjectPropertyAddress {
        address(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var propertyAddress = defaultOutputAddress
        let status = AudioObjectGetPropertyData(
            systemObject,
            &propertyAddress,
            0,
            nil,
            &size,
            &objectID
        )
        return status == noErr ? objectID : 0
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var propertyAddress = devicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &propertyAddress, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &propertyAddress, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    static func inputChannelCount(of deviceID: AudioObjectID) -> Int {
        var propertyAddress = address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size) == noErr,
              size > 0 else {
            return 0
        }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, bufferList) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func inputDeviceIDs() -> [AudioObjectID] {
        allDeviceIDs().filter { inputChannelCount(of: $0) > 0 }
    }

    static func isRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var propertyAddress = runningSomewhereAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    static func name(of deviceID: AudioObjectID) -> String? {
        var propertyAddress = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
