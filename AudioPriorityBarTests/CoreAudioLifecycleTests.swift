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

/// Values measured on real hardware, so the mapper is pinned to what macOS
/// actually reports rather than to what the headers suggest.
@Test
func terminalMappingCoversBothValueSpaces() {
    // USB and Bluetooth arrive translated into CoreAudio constants.
    #expect(CoreAudioProperties.category(forTerminal: 0x68647068) == .headphone)
    #expect(CoreAudioProperties.category(forTerminal: 0x73706B72) == .speaker)
    // Built-in devices report the raw USB Audio codes.
    #expect(CoreAudioProperties.category(forTerminal: 0x0302) == .headphone)
    #expect(CoreAudioProperties.category(forTerminal: 0x0301) == .speaker)
    // A speakerphone has no CoreAudio constant, only the raw codes.
    #expect(CoreAudioProperties.category(forTerminal: 0x0403) == .speaker)
    #expect(CoreAudioProperties.category(forTerminal: 0x0404) == .speaker)
    #expect(CoreAudioProperties.category(forTerminal: 0x0405) == .speaker)
    #expect(CoreAudioProperties.category(forTerminal: 0x0402) == .headphone)
}

@Test
func terminalMappingDeclaresNothingForAmbiguousTerminals() {
    // Aggregate devices report Unknown, and a monitor reports its own port.
    #expect(CoreAudioProperties.category(forTerminal: 0) == nil)
    #expect(CoreAudioProperties.category(forTerminal: 0x68646D69) == nil) // 'hdmi'
    #expect(CoreAudioProperties.category(forTerminal: 0x73706466) == nil) // 'spdf'
    #expect(CoreAudioProperties.category(forTerminal: 0x6C696E65) == nil) // 'line'
}

@Test
func streamsMustAgreeBeforeTheyCountAsEvidence() {
    // Every measured device has one stream, which is the ordinary case.
    #expect(CoreAudioProperties.category(forTerminals: [0x0301]) == .speaker)
    // An unrecognised stream alongside a recognised one does not veto it.
    #expect(CoreAudioProperties.category(forTerminals: [0, 0x0302]) == .headphone)
    // Nothing recognised means no claim, so the caller falls back.
    #expect(CoreAudioProperties.category(forTerminals: [0, 0x68646D69]) == nil)
    #expect(CoreAudioProperties.category(forTerminals: []) == nil)
    // Disagreement is no evidence rather than a coin toss on stream order.
    #expect(CoreAudioProperties.category(forTerminals: [0x0301, 0x0302]) == nil)
}

@Test
func onlyVideoCableTransportsCountAsDisplayOutputs() {
    // Both attached Dell panels report HDMI, including the one behind a
    // USB-C hub, so the hub does not need its own case.
    #expect(CoreAudioProperties.isDisplayTransport(0x68646D69)) // 'hdmi'
    #expect(CoreAudioProperties.isDisplayTransport(0x64707274)) // 'dprt'

    #expect(!CoreAudioProperties.isDisplayTransport(0x626C746E)) // 'bltn'
    #expect(!CoreAudioProperties.isDisplayTransport(0x75736220)) // 'usb '
    #expect(!CoreAudioProperties.isDisplayTransport(0x626C7565)) // 'blue'
    #expect(!CoreAudioProperties.isDisplayTransport(0x76697274)) // 'virt'
    #expect(!CoreAudioProperties.isDisplayTransport(0x67727570)) // 'grup'
    // Thunderbolt carries a dock rather than a panel, so it is left out.
    #expect(!CoreAudioProperties.isDisplayTransport(0x7468756E)) // 'thun'
    #expect(!CoreAudioProperties.isDisplayTransport(0))
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
func listenerStartRegistersMuteVolumeAndActivityPerDevice() {
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
        .inputVolume(id: 10),
        .running(id: 10),
        .mute(id: 20, role: .output, element: kAudioObjectPropertyElementMain),
        .mute(id: 20, role: .output, element: 1),
        .mute(id: 20, role: .input, element: kAudioObjectPropertyElementMain),
        .mute(id: 20, role: .input, element: 1),
        .volume(id: 20),
        .inputVolume(id: 20),
        .running(id: 20),
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

    #expect(log.deviceRemoves.count == 7)
    #expect(log.deviceAdds.count == 7)
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

    #expect(log.deviceRemoves.count == 7)
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
