import AudioPriorityCore
import AudioToolbox
import CoreAudio
import Foundation

enum CoreAudioProperties {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func devices() -> [AudioDevice] {
        deviceIDs().flatMap { id in
            DeviceRole.allCases.compactMap { role in
                makeDevice(id: id, role: role)
            }
        }
    }

    static func deviceIDs() -> [AudioObjectID] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            system, &address, 0, nil, &size
        ) == noErr else {
            return []
        }
        var ids = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            system, &address, 0, nil, &size, &ids
        ) == noErr else {
            return []
        }
        return Array(ids.prefix(
            Int(size) / MemoryLayout<AudioObjectID>.size
        ))
    }

    static func defaultDevice(_ role: DeviceRole) -> AudioObjectID? {
        let selector = role == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        var id = AudioObjectID(0)
        guard read(system, selector: selector, into: &id) == noErr,
              id != kAudioObjectUnknown else {
            return nil
        }
        return id
    }

    static func setDefault(_ id: AudioObjectID, role: DeviceRole) -> Bool {
        let selector = role == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        var id = id
        return write(system, selector: selector, value: &id) == noErr
    }

    static func outputVolume() -> Float? {
        guard let id = defaultDevice(.output) else { return nil }
        var volume: Float32 = 0
        let status = read(
            id,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            into: &volume
        )
        return status == noErr ? volume : nil
    }

    static func setOutputVolume(_ value: Float) -> Bool {
        guard let id = defaultDevice(.output) else { return false }
        var value = value
        return write(
            id,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            value: &value
        ) == noErr
    }

    static func deviceVolume(_ id: AudioObjectID) -> Float {
        var volume: Float32 = 0
        let status = read(
            id,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            into: &volume
        )
        return status == noErr ? volume : 1
    }

    static func isMuted(_ id: AudioObjectID, role: DeviceRole) -> Bool {
        let scope = role == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput
        var muted: UInt32 = 0
        if read(
            id,
            selector: kAudioDevicePropertyMute,
            scope: scope,
            element: kAudioObjectPropertyElementMain,
            into: &muted
        ) == noErr, muted != 0 {
            return true
        }
        muted = 0
        if read(
            id,
            selector: kAudioDevicePropertyMute,
            scope: scope,
            element: 1,
            into: &muted
        ) == noErr, muted != 0 {
            return true
        }
        return role == .output && deviceVolume(id) < 0.01
    }

    private static func makeDevice(
        id: AudioObjectID,
        role: DeviceRole
    ) -> AudioDevice? {
        let scope = role == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput
        guard hasStreams(id, scope: scope),
              let name = stringProperty(
                id,
                selector: kAudioDevicePropertyDeviceNameCFString
              ),
              let uid = stringProperty(
                id,
                selector: kAudioDevicePropertyDeviceUID
              ) else {
            return nil
        }
        return AudioDevice(
            platformID: id,
            uid: uid,
            name: name,
            role: role,
            isVirtual: isVirtual(id)
        )
    }

    /// CoreAudio reports software devices as virtual or aggregate transports,
    /// which separates Krisp and Multi-Output from real hardware without
    /// matching on names.
    private static func isVirtual(_ id: AudioObjectID) -> Bool {
        var transport = UInt32(0)
        guard read(
            id,
            selector: kAudioDevicePropertyTransportType,
            into: &transport
        ) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
    }

    private static func hasStreams(
        _ id: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = property(
            kAudioDevicePropertyStreams,
            scope: scope
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            id, &address, 0, nil, &size
        ) == noErr && size > 0
    }

    private static func stringProperty(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: Unmanaged<CFString>?
        var address = property(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &value
        )
        guard status == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func read<T: BitwiseCopyable>(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        into value: inout T
    ) -> OSStatus {
        var address = property(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &value
        )
    }

    private static func write<T: BitwiseCopyable>(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        value: inout T
    ) -> OSStatus {
        var address = property(selector, scope: scope, element: element)
        return AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value
        )
    }

    private static func property(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
}
