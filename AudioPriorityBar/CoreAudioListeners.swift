import AudioPriorityCore
import CoreAudio
import Foundation

enum SystemListener: CaseIterable, Equatable {
    case devices
    case defaultInput
    case defaultOutput
    case serviceRestarted
    case processList
}

enum DeviceListener: Hashable {
    case mute(
        id: AudioObjectID,
        role: DeviceRole,
        element: AudioObjectPropertyElement
    )
    case volume(id: AudioObjectID)
    case inputVolume(id: AudioObjectID)
    case running(id: AudioObjectID)
    case processInputRunning(id: AudioObjectID)
    case processInputDevices(id: AudioObjectID)
}

@MainActor
final class CoreAudioListenerLifecycle {
    typealias AddSystem = (SystemListener) -> Bool
    typealias RemoveSystem = (SystemListener) -> Void
    typealias DeviceIDs = () -> [AudioObjectID]?
    typealias AddDevice = (DeviceListener) -> Bool
    typealias RemoveDevice = (DeviceListener) -> Void

    private let addSystem: AddSystem
    private let removeSystem: RemoveSystem
    private let deviceIDs: DeviceIDs
    private let addDevice: AddDevice
    private let removeDevice: RemoveDevice
    private let deviceUID: (AudioObjectID) -> String?
    private let processIDs: (() -> [AudioObjectID])?
    private var systemListeners: [SystemListener] = []
    private var deviceListeners: [AudioObjectID: [DeviceListener]] = [:]
    private var knownUIDs: [AudioObjectID: String] = [:]
    private var processListeners: [AudioObjectID: [DeviceListener]] = [:]

    private(set) var isListening = false

    init(
        addSystem: @escaping AddSystem,
        removeSystem: @escaping RemoveSystem,
        deviceIDs: @escaping DeviceIDs,
        deviceUID: @escaping (AudioObjectID) -> String?,
        processIDs: (() -> [AudioObjectID])? = nil,
        addDevice: @escaping AddDevice,
        removeDevice: @escaping RemoveDevice
    ) {
        self.addSystem = addSystem
        self.removeSystem = removeSystem
        self.deviceIDs = deviceIDs
        self.deviceUID = deviceUID
        self.processIDs = processIDs
        self.addDevice = addDevice
        self.removeDevice = removeDevice
    }

    @discardableResult
    func start() -> Bool {
        guard !isListening else { return true }
        for listener in [SystemListener.devices, .defaultInput, .defaultOutput, .serviceRestarted] {
            guard addSystem(listener) else {
                systemListeners.reversed().forEach(removeSystem)
                systemListeners = []
                return false
            }
            systemListeners.append(listener)
        }
        if processIDs != nil, addSystem(.processList) { systemListeners.append(.processList) }
        isListening = true
        rebuildDeviceListeners()
        rebuildProcessListeners()
        return true
    }

    func rebuildDeviceListeners() {
        guard isListening, let ids = deviceIDs() else { return }
        let connected = Set(ids)
        for id in deviceListeners.keys where !connected.contains(id) {
            deviceListeners.removeValue(forKey: id)?.forEach(removeDevice)
            knownUIDs[id] = nil
        }
        for id in connected {
            let uid = deviceUID(id)
            // A recycled AudioObjectID belongs to different hardware. When
            // its identity is unavailable, conservatively bind it again.
            if uid == nil || uid != knownUIDs[id] {
                deviceListeners.removeValue(forKey: id)?.forEach(removeDevice)
                knownUIDs[id] = uid
            }
            let desired: [DeviceListener] = [
                .mute(id: id, role: .output, element: kAudioObjectPropertyElementMain),
                .mute(id: id, role: .output, element: 1),
                .mute(id: id, role: .input, element: kAudioObjectPropertyElementMain),
                .mute(id: id, role: .input, element: 1),
                .volume(id: id), .inputVolume(id: id), .running(id: id),
            ]
            // A driver's controls can appear after its device. Keep existing
            // subscriptions and retry only those still missing.
            let attached = deviceListeners[id] ?? []
            deviceListeners[id] = attached + desired.filter { !attached.contains($0) && addDevice($0) }
        }
    }

    func rebuildProcessListeners() {
        guard isListening, let processIDs else { return }
        let current = Set(processIDs())
        for id in processListeners.keys where !current.contains(id) {
            processListeners.removeValue(forKey: id)?.forEach(removeDevice)
        }
        for id in current {
            let attached = processListeners[id] ?? []
            let desired: [DeviceListener] = [.processInputRunning(id: id), .processInputDevices(id: id)]
            processListeners[id] = attached + desired.filter { !attached.contains($0) && addDevice($0) }
        }
    }

    func restart() -> Bool {
        stop()
        return start()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        deviceListeners.values.forEach { $0.forEach(removeDevice) }
        processListeners.values.forEach { $0.forEach(removeDevice) }
        deviceListeners = [:]
        processListeners = [:]
        knownUIDs = [:]
        systemListeners.forEach(removeSystem)
        systemListeners = []
    }

}

enum CoreAudioEvent: Sendable {
    case devicesChanged
    case serviceRestarted
    case processesChanged
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
