import AudioPriorityCore
import CoreAudio
import Foundation

enum SystemListener: CaseIterable, Equatable {
    case devices
    case defaultInput
    case defaultOutput
}

enum DeviceListener: Hashable {
    case mute(
        id: AudioObjectID,
        role: DeviceRole,
        element: AudioObjectPropertyElement
    )
    case volume(id: AudioObjectID)
}

@MainActor
final class CoreAudioListenerLifecycle {
    typealias AddSystem = (SystemListener) -> Bool
    typealias RemoveSystem = (SystemListener) -> Void
    typealias DeviceIDs = () -> [AudioObjectID]
    typealias AddDevice = (DeviceListener) -> Bool
    typealias RemoveDevice = (DeviceListener) -> Void

    private let addSystem: AddSystem
    private let removeSystem: RemoveSystem
    private let deviceIDs: DeviceIDs
    private let addDevice: AddDevice
    private let removeDevice: RemoveDevice
    private var deviceListeners: Set<DeviceListener> = []

    private(set) var isListening = false

    init(
        addSystem: @escaping AddSystem,
        removeSystem: @escaping RemoveSystem,
        deviceIDs: @escaping DeviceIDs,
        addDevice: @escaping AddDevice,
        removeDevice: @escaping RemoveDevice
    ) {
        self.addSystem = addSystem
        self.removeSystem = removeSystem
        self.deviceIDs = deviceIDs
        self.addDevice = addDevice
        self.removeDevice = removeDevice
    }

    @discardableResult
    func start() -> Bool {
        guard !isListening else { return true }
        guard addSystem(.devices) else { return false }
        guard addSystem(.defaultInput) else {
            removeSystem(.devices)
            return false
        }
        guard addSystem(.defaultOutput) else {
            removeSystem(.defaultInput)
            removeSystem(.devices)
            return false
        }
        isListening = true
        rebuildDeviceListeners()
        return true
    }

    func rebuildDeviceListeners() {
        guard isListening else { return }
        clearDeviceListeners()
        let desired = Set(deviceIDs().flatMap { id in
            [
                DeviceListener.mute(
                    id: id,
                    role: .output,
                    element: kAudioObjectPropertyElementMain
                ),
                DeviceListener.mute(id: id, role: .output, element: 1),
                DeviceListener.mute(
                    id: id,
                    role: .input,
                    element: kAudioObjectPropertyElementMain
                ),
                DeviceListener.mute(id: id, role: .input, element: 1),
                DeviceListener.volume(id: id),
            ]
        })
        for listener in desired where addDevice(listener) {
            deviceListeners.insert(listener)
        }
    }

    func stop() {
        guard isListening else { return }
        clearDeviceListeners()
        for listener in SystemListener.allCases {
            removeSystem(listener)
        }
        isListening = false
    }

    private func clearDeviceListeners() {
        for listener in deviceListeners {
            removeDevice(listener)
        }
        deviceListeners.removeAll()
    }
}

enum CoreAudioEvent: Sendable {
    case devicesChanged
    case defaultChanged(DeviceRole)
    case muteOrVolumeChanged
}

final class CoreAudioCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = false
    private let handler: @Sendable (CoreAudioEvent) -> Void

    init(handler: @escaping @Sendable (CoreAudioEvent) -> Void) {
        self.handler = handler
    }

    func setActive(_ value: Bool) {
        lock.withLock { isActive = value }
    }

    func send(_ event: CoreAudioEvent) {
        let shouldSend = lock.withLock { isActive }
        if shouldSend { handler(event) }
    }
}
