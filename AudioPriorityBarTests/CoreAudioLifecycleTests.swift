import AudioPriorityCore
import CoreAudio
import Testing
@testable import AudioPriorityBar

@MainActor
private final class ListenerLog {
    var systemAdds: [SystemListener] = []
    var systemRemoves: [SystemListener] = []
    var deviceAdds: [DeviceListener] = []
    var deviceRemoves: [DeviceListener] = []
    var failingSystem: SystemListener?
}

@MainActor
private func lifecycle(
    log: ListenerLog,
    deviceIDs: @escaping () -> [AudioObjectID]
) -> CoreAudioListenerLifecycle {
    CoreAudioListenerLifecycle(
        addSystem: {
            log.systemAdds.append($0)
            return $0 != log.failingSystem
        },
        removeSystem: { log.systemRemoves.append($0) },
        deviceIDs: deviceIDs,
        addDevice: {
            log.deviceAdds.append($0)
            return true
        },
        removeDevice: { log.deviceRemoves.append($0) }
    )
}

@Test
@MainActor
func listenerStartRollsBackPartialRegistration() {
    let log = ListenerLog()
    log.failingSystem = .defaultOutput
    let sut = lifecycle(log: log, deviceIDs: { [42] })

    #expect(!sut.start())
    #expect(log.systemAdds == [.devices, .defaultInput, .defaultOutput])
    #expect(log.systemRemoves == [.defaultInput, .devices])
    #expect(log.deviceAdds.isEmpty)
    #expect(!sut.isListening)
}

@Test
@MainActor
func listenerStartRegistersMuteElementsAndVolumePerDevice() {
    let log = ListenerLog()
    let sut = lifecycle(log: log, deviceIDs: { [10, 20] })

    #expect(sut.start())
    #expect(log.systemAdds == [.devices, .defaultInput, .defaultOutput])
    let expected: Set<DeviceListener> = [
        .mute(id: 10, role: .output, element: kAudioObjectPropertyElementMain),
        .mute(id: 10, role: .output, element: 1),
        .mute(id: 10, role: .input, element: kAudioObjectPropertyElementMain),
        .mute(id: 10, role: .input, element: 1),
        .volume(id: 10),
        .mute(id: 20, role: .output, element: kAudioObjectPropertyElementMain),
        .mute(id: 20, role: .output, element: 1),
        .mute(id: 20, role: .input, element: kAudioObjectPropertyElementMain),
        .mute(id: 20, role: .input, element: 1),
        .volume(id: 20),
    ]
    #expect(Set(log.deviceAdds) == expected)
}

@Test
@MainActor
func recycledDeviceIDStillForcesRemoveThenReadd() {
    let log = ListenerLog()
    let sut = lifecycle(log: log, deviceIDs: { [42] })
    #expect(sut.start())
    log.deviceAdds.removeAll()

    sut.rebuildDeviceListeners()

    #expect(log.deviceRemoves.count == 5)
    #expect(log.deviceAdds.count == 5)
    #expect(Set(log.deviceRemoves) == Set(log.deviceAdds))
}

@Test
@MainActor
func stopIsIdempotentAndAllowsRestart() {
    let log = ListenerLog()
    let sut = lifecycle(log: log, deviceIDs: { [1] })
    #expect(sut.start())

    sut.stop()
    sut.stop()

    #expect(log.deviceRemoves.count == 5)
    #expect(log.systemRemoves == [.devices, .defaultInput, .defaultOutput])
    #expect(!sut.isListening)
    #expect(sut.start())
}

@Test
func callbackGateDropsEventsAfterStop() {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        func read() -> Int { lock.withLock { value } }
    }
    let counter = Counter()
    let gate = CoreAudioCallbackGate { _ in counter.increment() }

    gate.setActive(true)
    gate.send(.devicesChanged)
    gate.setActive(false)
    gate.send(.muteOrVolumeChanged)

    #expect(counter.read() == 1)
}
