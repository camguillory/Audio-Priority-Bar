import AudioPriorityCore
import AudioToolbox
import CoreAudio

@MainActor
final class CoreAudioObserver {
    var onDevicesChanged: (() -> Void)?
    var onDefaultChanged: ((DeviceRole) -> Void)?
    var onMuteOrVolumeChanged: (() -> Void)?

    private var retryTask: Task<Void, Never>?
    private var shouldListen = false

    private lazy var callbackGate = CoreAudioCallbackGate { [weak self] event in
        Task { @MainActor [weak self] in
            self?.handle(event)
        }
    }

    private lazy var listeners = CoreAudioListenerLifecycle(
        addSystem: { [unowned self] in addSystemListener($0) },
        removeSystem: { [unowned self] in removeSystemListener($0) },
        deviceIDs: CoreAudioProperties.deviceIDs,
        deviceUID: CoreAudioProperties.deviceUID,
        processIDs: processInventory,
        addDevice: { [unowned self] in addDeviceListener($0) },
        removeDevice: { [unowned self] in removeDeviceListener($0) }
    )

    private var processInventory: (() -> [AudioObjectID])? {
        if #available(macOS 14.2, *) { return CoreAudioProperties.processIDs }
        return nil
    }

    @discardableResult
    func startListening() -> Bool {
        shouldListen = true
        callbackGate.setActive(true)
        let started = listeners.start()
        if started {
            retryTask?.cancel()
            retryTask = nil
        } else {
            scheduleRetry()
        }
        return started
    }

    func stopListening() {
        shouldListen = false
        retryTask?.cancel()
        retryTask = nil
        callbackGate.setActive(false)
        listeners.stop()
    }

    func rebindListeners() {
        guard shouldListen else { return }
        if listeners.restart() {
            retryTask?.cancel()
            retryTask = nil
            onDevicesChanged?()
        } else {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            for seconds in [1, 2, 4, 8, 16] {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self, shouldListen else { return }
                if listeners.start() {
                    retryTask = nil
                    onDevicesChanged?()
                    return
                }
            }
            self?.retryTask = nil
            DebugLog.shared.write("CoreAudio monitoring is unavailable after retrying")
        }
    }

    private func handle(_ event: CoreAudioEvent) {
        guard listeners.isListening else { return }
        switch event {
        case .devicesChanged:
            listeners.rebuildDeviceListeners()
            onDevicesChanged?()
        case .serviceRestarted:
            rebindListeners()
        case .processesChanged:
            listeners.rebuildProcessListeners()
            onMuteOrVolumeChanged?()
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
        guard AudioObjectHasProperty(id, &address) else { return false }
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
        case .serviceRestarted: kAudioHardwarePropertyServiceRestarted
        case .processList:
            if #available(macOS 14.2, *) { kAudioHardwarePropertyProcessObjectList } else { preconditionFailure() }
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
        case .serviceRestarted: Self.serviceRestartProc
        case .processList: Self.processListProc
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
        case let .inputVolume(id):
            return (
                id,
                kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                kAudioDevicePropertyScopeInput,
                kAudioObjectPropertyElementMain
            )
        case let .processInputRunning(id):
            if #available(macOS 14.2, *) {
                return (id, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain)
            }
            preconditionFailure()
        case let .processInputDevices(id):
            if #available(macOS 14.2, *) {
                return (id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput,
                        kAudioObjectPropertyElementMain)
            }
            preconditionFailure()
        case let .running(id):
            return (
                id,
                kAudioDevicePropertyDeviceIsRunningSomewhere,
                kAudioObjectPropertyScopeGlobal,
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

    private static let serviceRestartProc: AudioObjectPropertyListenerProc = {
        _, _, _, context in
        gate(context)?.send(.serviceRestarted)
        return noErr
    }

    private static let processListProc: AudioObjectPropertyListenerProc = {
        _, _, _, context in
        gate(context)?.send(.processesChanged)
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
