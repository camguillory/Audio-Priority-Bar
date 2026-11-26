import AppKit
import AudioPriorityCore
import AudioToolbox
import CoreAudio
import Foundation
import IOKit

enum CoreAudioProperties {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func devices() -> [AudioDevice] {
        let defaults: [DeviceRole: AudioObjectID] = [
            .input: defaultDevice(.input),
            .output: defaultDevice(.output),
        ].compactMapValues { $0 }
        return deviceIDs().flatMap { id in
            DeviceRole.allCases.compactMap { role in
                makeDevice(id: id, role: role, isCurrentDefault: defaults[role] == id)
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
        let muted = wholeDeviceMute(hasSingleChannel: { hasSingleChannel(id, scope: scope) }) { element in
            var value: UInt32 = 0
            return read(id, selector: kAudioDevicePropertyMute, scope: scope,
                        element: element, into: &value) == noErr && value != 0
        }
        if muted { return true }
        return role == .output && deviceVolume(id) < 0.01
    }

    /// Sets the mute property, trying channel 1 only on a mono device.
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
        return wholeDeviceMute(hasSingleChannel: { hasSingleChannel(id, scope: scope) }) { element in
            write(id, selector: kAudioDevicePropertyMute, scope: scope,
                  element: element, value: &value) == noErr
        }
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

    /// Whether the mute property can be set, on the main element or channel 1,
    /// matching where `setMute` writes it.
    static func canSetMute(_ id: AudioObjectID, role: DeviceRole) -> Bool {
        let scope = role == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput
        return wholeDeviceMute(hasSingleChannel: { hasSingleChannel(id, scope: scope) }) { element in
            var address = property(
                kAudioDevicePropertyMute, scope: scope, element: element
            )
            var settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(id, &address, &settable) == noErr
                && settable.boolValue
        }
    }

    /// A successful operation on channel 1 covers the device only when the
    /// role has exactly one channel. Read the topology only if the master fails.
    static func wholeDeviceMute(
        hasSingleChannel: () -> Bool,
        operation: (AudioObjectPropertyElement) -> Bool
    ) -> Bool {
        operation(kAudioObjectPropertyElementMain) || (hasSingleChannel() && operation(1))
    }

    private static func hasSingleChannel(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        let ids = streams(id, scope: scope)
        guard ids.count == 1, let stream = ids.first else { return false }
        var format = AudioStreamBasicDescription()
        return read(stream, selector: kAudioStreamPropertyVirtualFormat, into: &format) == noErr
            && format.mChannelsPerFrame == 1
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

    /// The name of an app recording from the device, from the audio process
    /// objects macOS 14.2 added. Nil before that, or when no app is found.
    static func appRecording(from device: AudioObjectID) -> String? {
        guard #available(macOS 14.2, *) else { return nil }
        for process in objectIDs(system, selector: kAudioHardwarePropertyProcessObjectList) {
            var running: UInt32 = 0
            var pid: pid_t = 0
            guard read(process, selector: kAudioProcessPropertyIsRunningInput, into: &running) == noErr,
                  running != 0,
                  objectIDs(
                      process,
                      selector: kAudioProcessPropertyDevices,
                      scope: kAudioObjectPropertyScopeInput
                  ).contains(device),
                  read(process, selector: kAudioProcessPropertyPID, into: &pid) == noErr,
                  let app = NSRunningApplication(processIdentifier: pid)?.localizedName else {
                continue
            }
            return app
        }
        return nil
    }

    private static func objectIDs(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = property(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func makeDevice(
        id: AudioObjectID,
        role: DeviceRole,
        isCurrentDefault: Bool
    ) -> AudioDevice? {
        let scope = role == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput
        let streams = streams(id, scope: scope)
        guard !streams.isEmpty,
              canBeDefaultDevice(id, scope: scope, isCurrentDefault: isCurrentDefault),
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
        var device = AudioDevice(
            platformID: id,
            uid: uid,
            name: name,
            role: role,
            isVirtual: isVirtualTransport(transport),
            // Input terminals describe a microphone, which says nothing about
            // where output should go.
            declaredCategory: role == .output
                ? declaredCategory(streams: streams, transport: transport)
                : nil,
            isDisplayOutput: role == .output && Self.isDisplayTransport(transport),
            transportType: transport
        )
        if transport == kAudioDeviceTransportTypeUSB, let location = device.possibleUSBLocation {
            device.usesUSBLocation = isSeriallessUSBDevice(uid: uid, at: location)
        }
        return device
    }

    /// The registry can lag behind the audio driver. An absent descriptor
    /// leaves identity unresolved until a later enumeration.
    static func isSeriallessUSBDevice(
        uid: String, at location: UInt32,
        hasSerial: (String) -> Bool = usbSerialExists,
        descriptorAt: (UInt32) -> (index: Int?, serial: String?)? = usbSerialDescriptor
    ) -> Bool? {
        let parts = uid.components(separatedBy: ":")
        guard parts.count == 5 else { return nil }
        // A hexadecimal serial can coincide with an unrelated occupied port.
        if hasSerial(parts[3]) { return false }
        guard let descriptor = descriptorAt(location) else { return nil }
        if let serial = descriptor.serial, !serial.isEmpty { return false }
        return descriptor.index.map { $0 == 0 }
    }

    private static func usbService(matching key: String, value: Any) -> io_service_t {
        guard let request = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else {
            return IO_OBJECT_NULL
        }
        request[kIOPropertyMatchKey] = [key: value]
        return IOServiceGetMatchingService(kIOMainPortDefault, request)
    }

    private static func usbSerialExists(_ serial: String) -> Bool {
        let service = usbService(matching: "USB Serial Number", value: serial)
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }

    private static func usbSerialDescriptor(at location: UInt32) -> (index: Int?, serial: String?)? {
        let service = usbService(matching: "locationID", value: location)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        return (property("iSerialNumber") as? Int, property("USB Serial Number") as? String)
    }

    /// The category a device claims for itself, or nil when it claims nothing
    /// usable. Aggregate devices report `Unknown` and HDMI reports its own
    /// terminal, so the caller still needs a fallback.
    private static func declaredCategory(
        streams: [AudioObjectID],
        transport: UInt32
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
        }, transport: transport)
    }

    /// macOS gives a Bluetooth output a headphones terminal even when it is a
    /// speaker, such as an Echo, so from Bluetooth that claim is no evidence.
    static func category(
        forTerminals terminals: [UInt32],
        transport: UInt32
    ) -> OutputCategory? {
        let declared = category(forTerminals: terminals)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
        return isBluetooth && declared == .headphone ? nil : declared
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

    /// Excludes internal streams that CoreAudio says cannot be chosen as the
    /// default input or output, such as per-app conduits, while keeping a
    /// transient route macOS already made current and failing open when a
    /// driver omits the property.
    static func allowsDefaultSelection(
        _ canBeDefault: UInt32?,
        isCurrentDefault: Bool = false
    ) -> Bool {
        isCurrentDefault || canBeDefault != 0
    }

    private static func canBeDefaultDevice(
        _ id: AudioObjectID,
        scope: AudioObjectPropertyScope,
        isCurrentDefault: Bool
    ) -> Bool {
        if isCurrentDefault { return true }
        var value: UInt32 = 1
        let status = read(
            id,
            selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            scope: scope,
            into: &value
        )
        return allowsDefaultSelection(status == noErr ? value : nil)
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
