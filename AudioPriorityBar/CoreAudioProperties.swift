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

    /// Sets the mute property, trying the main element before channel 1.
    /// False when the device has no settable mute, so the caller can fall back
    /// to zero input volume.
    static func setMute(
        _ id: AudioObjectID,
        role: DeviceRole,
        _ muted: Bool
    ) -> Bool {
        let scope = role == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput
        var value: UInt32 = muted ? 1 : 0
        for element in [kAudioObjectPropertyElementMain, 1] {
            if write(
                id,
                selector: kAudioDevicePropertyMute,
                scope: scope,
                element: element,
                value: &value
            ) == noErr {
                return true
            }
        }
        return false
    }

    static func inputVolume(_ id: AudioObjectID) -> Float? {
        var volume: Float32 = 0
        let status = read(
            id,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeInput,
            into: &volume
        )
        return status == noErr ? volume : nil
    }

    static func setInputVolume(_ id: AudioObjectID, _ value: Float) -> Bool {
        var value = value
        return write(
            id,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeInput,
            value: &value
        ) == noErr
    }

    /// Whether any process is using the device, which for a microphone means
    /// some app is recording from it.
    static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        return read(
            id,
            selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            into: &running
        ) == noErr && running != 0
    }

    private static func makeDevice(
        id: AudioObjectID,
        role: DeviceRole
    ) -> AudioDevice? {
        let scope = role == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput
        let streams = streams(id, scope: scope)
        guard !streams.isEmpty,
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
        let transport = transport(id)
        return AudioDevice(
            platformID: id,
            uid: uid,
            name: name,
            role: role,
            isVirtual: isVirtualTransport(transport),
            // Input terminals describe a microphone, which says nothing about
            // where output should go.
            declaredCategory: role == .output
                ? declaredCategory(streams: streams)
                : nil,
            isDisplayOutput: role == .output && Self.isDisplayTransport(transport),
            transportType: transport
        )
    }

    /// The category a device claims for itself, or nil when it claims nothing
    /// usable. Aggregate devices report `Unknown` and HDMI reports its own
    /// terminal, so the caller still needs a fallback.
    private static func declaredCategory(
        streams: [AudioObjectID]
    ) -> OutputCategory? {
        category(forTerminals: streams.compactMap { stream in
            var terminal = UInt32(0)
            // AudioStream has only a global scope, which `read` defaults to.
            guard read(
                stream,
                selector: kAudioStreamPropertyTerminalType,
                into: &terminal
            ) == noErr else {
                return nil
            }
            return terminal
        })
    }

    /// Resolves what a device's streams collectively claim. Streams that
    /// disagree are no evidence at all, since preferring one by position would
    /// only make stream order look meaningful.
    static func category(forTerminals terminals: [UInt32]) -> OutputCategory? {
        let declared = Set(terminals.compactMap(category(forTerminal:)))
        return declared.count == 1 ? declared.first : nil
    }

    /// Maps an audio terminal to a category.
    ///
    /// Two value spaces appear in practice. USB and Bluetooth devices arrive
    /// translated into the CoreAudio constants, while built-in devices report
    /// the raw code from the USB Audio Terminal Types specification, so both
    /// are accepted. Anything unrecognised, including `Unknown`, line level and
    /// digital interfaces, declares nothing.
    static func category(
        forTerminal terminal: UInt32
    ) -> OutputCategory? {
        switch terminal {
        case UInt32(kAudioStreamTerminalTypeHeadphones),
             0x0302, // Headphones
             0x0303, // Head mounted display audio
             0x0401, // Handset
             0x0402: // Headset
            return .headphone
        case UInt32(kAudioStreamTerminalTypeSpeaker),
             UInt32(kAudioStreamTerminalTypeLFESpeaker),
             UInt32(kAudioStreamTerminalTypeReceiverSpeaker),
             0x0301, // Speaker
             0x0304, // Desktop speaker
             0x0305, // Room speaker
             0x0306, // Communication speaker
             0x0307, // Low frequency effects speaker
             0x0403, // Speakerphone, no echo reduction
             0x0404, // Echo suppressing speakerphone
             0x0405: // Echo cancelling speakerphone
            return .speaker
        default:
            return nil
        }
    }

    private static func transport(_ id: AudioObjectID) -> UInt32 {
        var transport = UInt32(0)
        guard read(
            id,
            selector: kAudioDevicePropertyTransportType,
            into: &transport
        ) == noErr else {
            return kAudioDeviceTransportTypeUnknown
        }
        return transport
    }

    /// CoreAudio reports software devices as virtual or aggregate transports,
    /// which separates Krisp and Multi-Output from real hardware without
    /// matching on names.
    private static func isVirtualTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
    }

    /// Sound reaching a monitor or TV over the video cable. The transport says
    /// so outright, which a product name cannot: both of the attached Dell
    /// panels report HDMI, including the one behind a USB-C hub.
    static func isDisplayTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeHDMI
            || transport == kAudioDeviceTransportTypeDisplayPort
    }

    private static func streams(
        _ id: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = property(
            kAudioDevicePropertyStreams,
            scope: scope
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            id, &address, 0, nil, &size
        ) == noErr, size > 0 else {
            return []
        }
        var streams = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &streams
        ) == noErr else {
            return []
        }
        return streams
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
