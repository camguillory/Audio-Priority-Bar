import AudioPriorityCore
import AudioToolbox
import CoreAudio

@MainActor
final class CoreAudioObserver {
    var onDevicesChanged: (() -> Void)?
    var onDefaultChanged: ((DeviceRole) -> Void)?
    var onMuteOrVolumeChanged: (() -> Void)?

    private lazy var callbackGate = CoreAudioCallbackGate { [weak self] event in
        Task { @MainActor [weak self] in
            self?.handle(event)
        }
    }

    private lazy var listeners = CoreAudioListenerLifecycle(
        addSystem: { [unowned self] in addSystemListener($0) },
        removeSystem: { [unowned self] in removeSystemListener($0) },
        deviceIDs: CoreAudioProperties.deviceIDs,
        addDevice: { [unowned self] in addDeviceListener($0) },
        removeDevice: { [unowned self] in removeDeviceListener($0) }
    )

    @discardableResult
    func startListening() -> Bool {
        callbackGate.setActive(true)
        let started = listeners.start()
        if !started { callbackGate.setActive(false) }
        return started
    }

    func stopListening() {
        listeners.stop()
        callbackGate.setActive(false)
    }

    private func handle(_ event: CoreAudioEvent) {
        guard listeners.isListening else { return }
        switch event {
        case .devicesChanged:
            onDevicesChanged?()
            listeners.rebuildDeviceListeners()
        case let .defaultChanged(role):
            onDefaultChanged?(role)
        case .muteOrVolumeChanged:
            onMuteOrVolumeChanged?()
        }
    }

    private func addSystemListener(_ listener: SystemListener) -> Bool {
        var address = systemAddress(for: listener)
        return AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            systemProc(for: listener), callbackContext
        ) == noErr
    }

    private func removeSystemListener(_ listener: SystemListener) {
        var address = systemAddress(for: listener)
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            systemProc(for: listener), callbackContext
        )
    }

    private func addDeviceListener(_ listener: DeviceListener) -> Bool {
        let (id, selector, scope, element) = deviceParts(listener)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        return AudioObjectAddPropertyListener(
            id, &address, Self.muteVolumeProc, callbackContext
        ) == noErr
    }

    private func removeDeviceListener(_ listener: DeviceListener) {
        let (id, selector, scope, element) = deviceParts(listener)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        AudioObjectRemovePropertyListener(
            id, &address, Self.muteVolumeProc, callbackContext
        )
    }

    // The observer owns the gate and removes every listener before either can
    // be released, so CoreAudio never outlives this unretained callback context.
    private var callbackContext: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(callbackGate).toOpaque()
    }

    private func systemAddress(
        for listener: SystemListener
    ) -> AudioObjectPropertyAddress {
        let selector: AudioObjectPropertySelector = switch listener {
        case .devices: kAudioHardwarePropertyDevices
        case .defaultInput: kAudioHardwarePropertyDefaultInputDevice
        case .defaultOutput: kAudioHardwarePropertyDefaultOutputDevice
        }
        return AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func systemProc(
        for listener: SystemListener
    ) -> AudioObjectPropertyListenerProc {
        switch listener {
        case .devices: Self.devicesProc
        case .defaultInput: Self.defaultInputProc
        case .defaultOutput: Self.defaultOutputProc
        }
    }

    private func deviceParts(
        _ listener: DeviceListener
    ) -> (
        AudioObjectID,
        AudioObjectPropertySelector,
        AudioObjectPropertyScope,
        AudioObjectPropertyElement
    ) {
        switch listener {
        case let .mute(id, role, element):
            let scope = role == .input
                ? kAudioDevicePropertyScopeInput
                : kAudioDevicePropertyScopeOutput
            return (id, kAudioDevicePropertyMute, scope, element)
        case let .volume(id):
            return (
                id,
                kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                kAudioDevicePropertyScopeOutput,
                kAudioObjectPropertyElementMain
            )
        }
    }

    nonisolated private static func gate(
        _ context: UnsafeMutableRawPointer?
    ) -> CoreAudioCallbackGate? {
        context.map {
            Unmanaged<CoreAudioCallbackGate>.fromOpaque($0).takeUnretainedValue()
        }
    }

    private static let devicesProc: AudioObjectPropertyListenerProc = {
        _, _, _, context in
        gate(context)?.send(.devicesChanged)
        return noErr
    }

    private static let defaultInputProc: AudioObjectPropertyListenerProc = {
        _, _, _, context in
        gate(context)?.send(.defaultChanged(.input))
        return noErr
    }

    private static let defaultOutputProc: AudioObjectPropertyListenerProc = {
        _, _, _, context in
        gate(context)?.send(.defaultChanged(.output))
        return noErr
    }

    private static let muteVolumeProc: AudioObjectPropertyListenerProc = {
        _, _, _, context in
        gate(context)?.send(.muteOrVolumeChanged)
        return noErr
    }
}
