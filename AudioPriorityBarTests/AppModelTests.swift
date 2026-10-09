import AudioPriorityCore
import CoreAudio
import Foundation
import Testing
@testable import AudioPriorityBar

@MainActor
final class FakeAudio {
    var catalog: [AudioDevice] = []
    var defaults: [DeviceRole: UInt32] = [:]
    var volume: Float?
    var muted: Set<String> = []
    var selections: [(DeviceRole, UInt32)] = []
    var selectionSucceeds = true
    var failedSelectionRoles: Set<DeviceRole> = []
    var volumeReadCount = 0
    var muteReadCount = 0
    /// Devices without a settable mute property, like ZoomAudioDevice or a
    /// Scarlett Solo.
    var noMuteProperty: Set<UInt32> = []
    var inputVolumes: [UInt32: Float] = [:]
    var running: Set<UInt32> = []

    var operations: AudioOperations {
        AudioOperations(
            devices: { self.catalog },
            defaultDevice: { self.defaults[$0] },
            setDefault: {
                guard self.selectionSucceeds,
                      !self.failedSelectionRoles.contains($0) else {
                    return false
                }
                self.defaults[$0] = $1
                self.selections.append(($0, $1))
                return true
            },
            outputVolume: {
                self.volumeReadCount += 1
                return self.volume
            },
            setOutputVolume: {
                self.volume = $0
                return true
            },
            isMuted: {
                self.muteReadCount += 1
                return self.muted.contains("\($0.rawValue):\($1)")
            },
            setMute: { role, id, muted in
                guard !self.noMuteProperty.contains(id) else { return false }
                if muted {
                    self.muted.insert("\(role.rawValue):\(id)")
                } else {
                    self.muted.remove("\(role.rawValue):\(id)")
                }
                return true
            },
            canSetMute: { !self.noMuteProperty.contains($1) },
            inputVolume: { self.inputVolumes[$0] },
            setInputVolume: {
                guard self.inputVolumes[$0] != nil else { return false }
                self.inputVolumes[$0] = $1
                return true
            },
            isRunning: { self.running.contains($0) }
        )
    }
}

@MainActor
func testModel(
    audio: FakeAudio,
    defaults: UserDefaults,
    usable: @escaping (AudioDevice) -> Bool = { _ in true },
    state: @escaping (AudioDevice) -> LinkState? = { _ in nil },
    isUserPicking: @escaping () -> Bool = { false }
) -> AppModel {
    AppModel(
        store: PriorityStore(defaults: defaults),
        audio: audio.operations,
        link: LinkOperations(isUsable: usable, state: state),
        isUserPicking: isUserPicking
    )
}

func output(
    _ id: UInt32,
    _ uid: String,
    _ name: String = "Speaker"
) -> AudioDevice {
    AudioDevice(platformID: id, uid: uid, name: name, role: .output)
}

func input(
    _ id: UInt32,
    _ uid: String,
    _ name: String = "Microphone"
) -> AudioDevice {
    AudioDevice(platformID: id, uid: uid, name: name, role: .input)
}

func isolatedDefaults() -> UserDefaults {
    let suite = "AppModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test
@MainActor
func startupSelectsHighestPriorityInputAndOutput() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    audio.catalog = [input(1, "mic"), output(2, "speaker")]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(audio.selections.map(\.0) == [.output, .input])
    #expect(model.currentInputID == 1)
    #expect(model.currentOutputID == 2)
}

@Test
@MainActor
func startupScansMuteStateOnceAfterSelectingDefaults() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    audio.catalog = [input(1, "mic"), output(2, "speaker")]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(audio.muteReadCount == 4)
}

@Test
@MainActor
func muteAndVolumeCallbacksAreCoalesced() async {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.volumeReadCount = 0

    model.handleMuteOrVolumeChanged()
    model.handleMuteOrVolumeChanged()
    for _ in 0..<100 where audio.volumeReadCount == 0 {
        await Task.yield()
    }

    #expect(audio.volumeReadCount == 1)
}

@Test
@MainActor
func failedSelectionDoesNotClaimDeviceIsCurrent() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]
    audio.selectionSucceeds = false
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.currentOutputID == nil)
    #expect(audio.selections.isEmpty)
}

@Test
@MainActor
func startupPrefersHeadphonesOverSpeakers() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.currentOutputID == headphones.platformID)
    #expect(model.activeOutputCategory == .headphone)
}

@Test
@MainActor
func startupFallsBackWhenHeadphonesAreUnusable() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let unavailable = output(2, "jabra", "Jabra Link 380")
    audio.catalog = [speaker, unavailable]
    let model = testModel(
        audio: audio,
        defaults: defaults,
        usable: { $0.uid != "jabra" }
    )

    model.start()

    #expect(audio.selections.last?.1 == speaker.platformID)
    #expect(model.activeOutputCategory == .speaker)
}

@Test
@MainActor
func neverAutoSelectDeviceRemainsVisible() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let speaker = output(1, "speaker")
    store.setNeverUse(speaker, true)
    let audio = FakeAudio()
    audio.catalog = [speaker]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.speakerDevices == [speaker])
    #expect(audio.selections.isEmpty)
}

@Test
@MainActor
func showAllRevealsHiddenDevicesInTheirOwnList() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let kept = output(1, "speaker")
    let hidden = output(2, "hdmi", "HDMI")
    store.hide(hidden, in: .speaker)
    let audio = FakeAudio()
    audio.catalog = [kept, hidden]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.speakerDevices == [kept])
    #expect(model.hiddenSpeakerDevices == [hidden])

    model.showAll = true
    model.refreshDevices()

    #expect(model.speakerDevices == [kept, hidden])
    #expect(model.hiddenSpeakerDevices.isEmpty)
}

/// A started model whose Bluetooth read returns the Echo Dot under `list`,
/// `device_connected` or `device_not_connected`.
@MainActor
private func modelWithPairedEcho(
    _ audio: FakeAudio,
    list: String,
    defaults: UserDefaults = isolatedDefaults()
) async throws -> AppModel {
    let profile = Data("""
    {"SPBluetoothDataType": [{"\(list)": [
      {"Echo Dot-65W": {"device_address": "AC:41:6A:C5:C3:F1", "device_minorType": "Speaker"}}
    ]}]}
    """.utf8)
    let battery = BluetoothBatteryMonitor(read: { profile })
    let model = AppModel(
        store: PriorityStore(defaults: defaults),
        audio: audio.operations,
        link: LinkOperations(isUsable: { _ in true }, state: { _ in nil }),
        battery: battery
    )
    model.start()
    for _ in 0..<1000 where battery.report.pairedAudio.isEmpty { await Task.yield() }
    try #require(!battery.report.pairedAudio.isEmpty)
    return model
}

private let echo = output(2, "AC-41-6A-C5-C3-F1:output", "Echo Dot-65W")

@Test
@MainActor
func aDisconnectedBluetoothSpeakerStaysListedDimmedWithoutWaitingForTheProfiler() async throws {
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker"), echo]
    // Measured: right after the Echo Dot dropped, system_profiler still listed
    // it as connected.
    let model = try await modelWithPairedEcho(audio, list: "device_connected")
    #expect(model.speakerDevices.map(\.uid) == ["speaker", echo.uid])
    #expect(model.speakerDevices.map(\.isConnected) == [true, true])

    audio.catalog = [output(1, "speaker")]
    model.handleDevicesChanged()

    #expect(model.speakerDevices.map(\.uid) == ["speaker", echo.uid])
    #expect(model.speakerDevices.map(\.isConnected) == [true, false])
    #expect(model.canConnect(try #require(model.speakerDevices.last)))
}

@Test
@MainActor
func aBluetoothSpeakerClickedWhileOffIsSelectedOnceItConnects() async throws {
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]
    let model = try await modelWithPairedEcho(audio, list: "device_not_connected")
    #expect(model.currentOutputID == 1)
    model.selectingBluetoothAddress = "AC-41-6A-C5-C3-F1"

    // The built-in speaker ranks first, so automatic switching alone would
    // keep it.
    audio.catalog.append(echo)
    model.handleDevicesChanged()

    #expect(model.currentOutputID == echo.platformID)
    #expect(model.isManualMode)
    #expect(model.selectingBluetoothAddress == nil)
}

@Test
@MainActor
func aHiddenBluetoothSpeakerIsListedOnlyWhenShowingEverything() async throws {
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]
    let model = try await modelWithPairedEcho(audio, list: "device_not_connected")
    let paired = try #require(model.speakerDevices.first { $0.uid == echo.uid })

    model.hide(paired)
    #expect(model.speakerDevices.map(\.uid) == ["speaker"])
    #expect(model.hiddenSpeakerDevices.map(\.uid) == [echo.uid])

    model.showAll = true
    model.refreshDevices()
    #expect(model.speakerDevices.map(\.uid) == ["speaker", echo.uid])
}

@Test
@MainActor
func aForgottenBluetoothSpeakerStaysGoneUntilItConnectsAgain() async throws {
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]
    let model = try await modelWithPairedEcho(audio, list: "device_not_connected")
    let paired = try #require(model.speakerDevices.first { $0.uid == echo.uid })

    model.forget(paired)
    model.showAll = true
    model.refreshDevices()
    #expect(model.speakerDevices.map(\.uid) == ["speaker"])

    audio.catalog.append(echo)
    model.handleDevicesChanged()
    audio.catalog.removeLast()
    model.handleDevicesChanged()
    #expect(model.speakerDevices.map(\.uid) == ["speaker", echo.uid])
}

@Test
@MainActor
func aPairedSpeakerRememberedAsHeadphonesIsListedUnderSpeakers() async throws {
    // Measured: a JBL Xtreme was remembered as headphones before a Bluetooth
    // headphones claim was ignored, while Bluetooth reports it as a speaker.
    let defaults = isolatedDefaults()
    var remembered = echo
    remembered.declaredCategory = .headphone
    PriorityStore(defaults: defaults).remember([remembered])
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]

    let model = try await modelWithPairedEcho(audio, list: "device_not_connected", defaults: defaults)

    #expect(model.speakerDevices.map(\.uid) == ["speaker", echo.uid])
    #expect(model.headphoneDevices.isEmpty)
}

@Test
@MainActor
func theIdleMicOfHeadphonesPlayingCountsAsInUse() {
    // AirPods play while the Mac's own mic records, so the AirPods mic row is
    // not current yet disconnecting it would cut the sound.
    let airpods = output(1, "70-AE-2A-5E-21-CD:output", "AirPods Pro")
    let airpodsMic = input(3, "70-AE-2A-5E-21-CD:input", "AirPods Pro")
    let audio = FakeAudio()
    audio.catalog = [airpods, echo, airpodsMic, input(4, "BuiltInMicrophoneDevice")]
    audio.defaults = [.output: 1, .input: 4]
    let model = testModel(audio: audio, defaults: isolatedDefaults())

    model.refreshDevices()

    #expect(model.isInUse(airpodsMic))
    #expect(!model.isInUse(echo))
}

@Test
@MainActor
func aBluetoothDeviceStopsShowingConnectingOnceCoreAudioHasIt() {
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()
    model.connectingBluetoothAttempts = ["AC-41-6A-C5-C3-F1": UUID()]

    audio.catalog.append(output(2, "AC-41-6A-C5-C3-F1:output", "Echo Dot-65W"))
    model.handleDevicesChanged()

    #expect(model.connectingBluetoothAttempts.isEmpty)
}

@Test
@MainActor
func aBluetoothDeviceWithAnUnfamiliarUIDIsMatchedByName() async throws {
    // Not seen on hardware: an LE Audio device whose UID is not built from its
    // address must be listed once, not also as a paired device that is off,
    // and offer Disconnect.
    var oddEcho = output(2, "le-audio-echo", "Echo Dot-65W")
    oddEcho.transportType = kAudioDeviceTransportTypeBluetoothLE
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker"), oddEcho]

    let model = try await modelWithPairedEcho(audio, list: "device_connected")

    #expect(model.speakerDevices.map(\.uid) == ["speaker", "le-audio-echo"])
    #expect(model.bluetoothAddress(of: oddEcho) == "AC-41-6A-C5-C3-F1")
    #expect(model.canDisconnect(oddEcho))
}

@Test
@MainActor
func anOutsideChangeIsSwitchedBackAndAutomaticStaysOn() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()
    var notices: [[AudioDevice]] = []
    model.onAutomaticSwitch = { notices.append($0) }

    audio.defaults[.output] = speaker.platformID
    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == headphones.platformID)
    #expect(audio.selections.map(\.1) == [headphones.platformID])
    #expect(notices.map { $0.map(\.uid) } == [["headphones"]])
}

@Test
@MainActor
func speakersTakingOverFromDisconnectedHeadphonesStartMuted() {
    let defaults = isolatedDefaults()
    PriorityStore(defaults: defaults).mutesSpeakersWhenHeadphonesDisconnect = true
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    #expect(model.currentOutputID == headphones.platformID)

    audio.catalog = [speaker]
    model.handleDevicesChanged()

    #expect(model.currentOutputID == speaker.platformID)
    #expect(model.isActiveOutputMuted)
}

@Test
@MainActor
func speakersTakingOverFromAPoweredOffJabraHeadsetStartMuted() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.mutesSpeakersWhenHeadphonesDisconnect = true
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let jabra = output(2, "jabra", "Jabra Link 380")
    store.setCategory(.headphone, for: jabra)
    audio.catalog = [speaker, jabra]
    var isHeadsetOn = true
    let model = testModel(
        audio: audio,
        defaults: defaults,
        usable: { $0.uid != "jabra" || isHeadsetOn }
    )
    model.start()
    #expect(model.currentOutputID == jabra.platformID)

    // The dongle stays plugged in, so only the link verdict changes.
    isHeadsetOn = false
    model.handleLinkChanged()

    #expect(model.currentOutputID == speaker.platformID)
    #expect(model.isActiveOutputMuted)
}

@Test
@MainActor
func speakersStartMutedWhenMacOSMovesTheOutputAfterTheHeadphonesLeave() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    store.mutesSpeakersWhenHeadphonesDisconnect = true
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    audio.defaults[.output] = headphones.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    // The device list can change while the default still names the
    // headphones that are already gone.
    audio.catalog = [speaker]
    model.handleDevicesChanged()
    audio.defaults[.output] = speaker.platformID
    model.handleDefaultChanged(.output)

    #expect(model.isActiveOutputMuted)
}

@Test
@MainActor
func speakersStayUnmutedUnlessThePlayingHeadphonesLeaveWithTheOptionOn() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    audio.defaults[.output] = headphones.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog = [speaker]
    audio.defaults[.output] = speaker.platformID
    model.handleDevicesChanged()
    #expect(!model.isActiveOutputMuted)

    model.setMutesSpeakersWhenHeadphonesDisconnect(true)
    audio.catalog = [speaker, headphones]
    model.handleDevicesChanged()
    audio.catalog = [speaker]
    model.handleDevicesChanged()
    #expect(!model.isActiveOutputMuted)
}

@Test
@MainActor
func aPickInControlCenterStaysUntilADeviceConnectsOrDisconnects() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults, isUserPicking: { true })
    model.start()
    audio.selections.removeAll()

    audio.defaults[.output] = speaker.platformID
    model.handleDefaultChanged(.output)
    // A Jabra verdict refreshes the lists without connecting anything.
    model.handleLinkChanged()

    #expect(!model.isManualMode)
    #expect(audio.selections.isEmpty)
    #expect(model.currentOutputID == speaker.platformID)

    audio.catalog.append(input(3, "usb-mic", "USB Mic"))
    model.handleDevicesChanged()

    #expect(model.currentOutputID == headphones.platformID)
}

@Test
@MainActor
func airPodsTakingTheMicrophoneOnEarDetectionIsSwitchedBack() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let airPods = output(1, "airpods-out", "AirPods Pro")
    let airPodsMic = input(2, "airpods-in", "AirPods Pro")
    let scarlett = input(3, "scarlett", "Scarlett Solo USB")
    store.savePriorities([scarlett, airPodsMic], role: .input)
    let audio = FakeAudio()
    audio.catalog = [airPods, airPodsMic, scarlett]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    #expect(model.currentInputID == scarlett.platformID)

    // Long after they connected, putting them in makes macOS move the mic.
    audio.defaults[.input] = airPodsMic.platformID
    model.handleDefaultChanged(.input)

    #expect(!model.isManualMode)
    #expect(model.currentInputID == scarlett.platformID)
    #expect(model.currentOutputID == airPods.platformID)
}

@Test
@MainActor
func airPodsTakingTheOutputBackInManualModeIsSwitchedBack() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker", "MacBook Air Speakers")
    let airPods = output(2, "airpods-out", "AirPods Pro")
    let airPodsMic = input(3, "airpods-in", "AirPods Pro")
    let scarlett = input(4, "scarlett", "Scarlett Solo USB")
    let audio = FakeAudio()
    audio.catalog = [speaker, airPods, airPodsMic, scarlett]
    audio.defaults[.output] = airPods.platformID
    audio.defaults[.input] = scarlett.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    model.selectManually(speaker)
    model.handleDefaultChanged(.output)
    audio.selections.removeAll()

    // Seen in a real trace: seconds after the pick, with nothing connecting,
    // macOS moves the output and microphone to the AirPods in the user's ears.
    audio.defaults[.output] = airPods.platformID
    model.handleDefaultChanged(.output)
    audio.defaults[.input] = airPodsMic.platformID
    model.handleDefaultChanged(.input)

    #expect(model.isManualMode)
    #expect(model.currentOutputID == speaker.platformID)
    #expect(model.currentInputID == scarlett.platformID)
    #expect(audio.selections.map(\.1) == [speaker.platformID, scarlett.platformID])
}

@Test
@MainActor
func airPodsTakingBothDevicesAtOnceInManualModeAreBothSwitchedBack() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker", "MacBook Air Speakers")
    let airPods = output(2, "airpods-out", "AirPods Pro")
    let airPodsMic = input(3, "airpods-in", "AirPods Pro")
    let scarlett = input(4, "scarlett", "Scarlett Solo USB")
    let audio = FakeAudio()
    audio.catalog = [speaker, airPods, airPodsMic, scarlett]
    audio.defaults[.output] = speaker.platformID
    audio.defaults[.input] = scarlett.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    // Seen in a real trace: macOS moves both 3 ms apart, so the input has
    // already moved when the output's event is handled.
    audio.defaults[.output] = airPods.platformID
    audio.defaults[.input] = airPodsMic.platformID
    model.handleDefaultChanged(.output)
    model.handleDefaultChanged(.input)

    #expect(model.currentOutputID == speaker.platformID)
    #expect(model.currentInputID == scarlett.platformID)
    #expect(audio.defaults[.output] == speaker.platformID)
    #expect(audio.defaults[.input] == scarlett.platformID)
}

@Test
@MainActor
func aPickInControlCenterStaysInManualMode() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let airPods = output(2, "airpods", "AirPods Pro")
    let audio = FakeAudio()
    audio.catalog = [speaker, airPods]
    audio.defaults[.output] = speaker.platformID
    let model = testModel(audio: audio, defaults: defaults, isUserPicking: { true })
    model.start()

    audio.defaults[.output] = airPods.platformID
    model.handleDefaultChanged(.output)

    #expect(model.isManualMode)
    #expect(model.currentOutputID == airPods.platformID)
    #expect(audio.selections.isEmpty)
}

@Test
@MainActor
func aNewlyConnectedOutputStaysInManualMode() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let airPods = output(2, "airpods", "AirPods Pro")
    let audio = FakeAudio()
    audio.catalog = [speaker]
    audio.defaults[.output] = speaker.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog.append(airPods)
    audio.defaults[.output] = airPods.platformID
    model.handleDefaultChanged(.output)

    #expect(model.currentOutputID == airPods.platformID)
    #expect(audio.selections.isEmpty)
}

@Test
@MainActor
func macOSTakingTheOutputAgainAfterASwitchBackIsLeftAndNamed() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let airPods = output(2, "airpods", "AirPods Pro")
    let audio = FakeAudio()
    audio.catalog = [speaker, airPods]
    audio.defaults[.output] = speaker.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    // Smart Routing retries about 4 seconds after each switch back.
    for _ in 0..<3 {
        audio.defaults[.output] = airPods.platformID
        model.handleDefaultChanged(.output)
    }

    #expect(audio.selections.map(\.1) == [speaker.platformID])
    #expect(model.takeoverDevice?.uid == airPods.uid)

    model.selectManually(speaker)

    #expect(model.takeoverDevice == nil)
    #expect(model.currentOutputID == speaker.platformID)
}

@Test
@MainActor
func automaticModeKeepsAMicrophoneMacOSTakesAgainAfterASwitchBack() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let airPods = output(1, "airpods-out", "AirPods Pro")
    let airPodsMic = input(2, "airpods-in", "AirPods Pro")
    let scarlett = input(3, "scarlett", "Scarlett Solo USB")
    store.savePriorities([scarlett, airPodsMic], role: .input)
    let audio = FakeAudio()
    audio.catalog = [airPods, airPodsMic, scarlett]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    for _ in 0..<3 {
        audio.defaults[.input] = airPodsMic.platformID
        model.handleDefaultChanged(.input)
    }

    #expect(!model.isManualMode)
    #expect(model.currentInputID == airPodsMic.platformID)
    #expect(model.takeoverDevice?.uid == airPodsMic.uid)
}

@Test
@MainActor
func outputMovingBeforeTheDisconnectArrivesKeepsAutomaticOn() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    // Seen in a real trace: the default moves to the speakers 40 ms before
    // the AirPods leave the device list.
    audio.defaults[.output] = speaker.platformID
    model.handleDefaultChanged(.output)
    audio.catalog = [speaker]
    model.handleDevicesChanged()

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == speaker.platformID)
}

@Test
@MainActor
func newHeadphoneBecomesAutomaticOutput() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()

    audio.catalog.append(headphones)
    model.handleDevicesChanged()

    #expect(!model.isManualMode)
    #expect(audio.selections.last?.1 == headphones.platformID)
    #expect(model.activeOutputCategory == .headphone)
}

@Test
@MainActor
func losingAndReturningHeadphonesSwitchesAutomaticOutput() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()

    audio.catalog = [speaker]
    model.handleDevicesChanged()

    #expect(audio.selections.last?.1 == speaker.platformID)
    #expect(model.activeOutputCategory == .speaker)

    audio.catalog.append(headphones)
    model.handleDevicesChanged()

    #expect(audio.selections.last?.1 == headphones.platformID)
    #expect(model.activeOutputCategory == .headphone)
}

@Test
@MainActor
func manualModeNeverChangesDevicesAutomatically() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog.append(output(2, "headphones", "AirPods Pro"))
    model.handleDevicesChanged()

    #expect(audio.selections.isEmpty)
    #expect(model.isManualMode)
}

@Test
@MainActor
func explicitChoiceTurnsAutomaticOffUntilReenabled() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectManually(speaker)
    audio.selections.removeAll()
    model.handleDevicesChanged()

    #expect(model.isManualMode)
    #expect(model.currentOutputID == speaker.platformID)
    #expect(audio.selections.isEmpty)

    model.setManualMode(false)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == headphones.platformID)
    #expect(audio.selections.last?.1 == headphones.platformID)
}

@Test
@MainActor
func appDefaultChangeEchoKeepsAutomaticOn() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let headphones = output(1, "headphones", "AirPods Pro")
    audio.catalog = [headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == headphones.platformID)
}

@Test
@MainActor
func systemFallbackAfterDisconnectKeepsAutomaticOn() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog = [speaker]
    audio.defaults[.output] = speaker.platformID
    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == speaker.platformID)
}

@Test
@MainActor
func systemChoiceDuringConnectionStillAppliesPriority() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let preferred = output(2, "preferred", "AirPods Pro")
    let newcomer = output(3, "newcomer", "USB Headphones")
    audio.catalog = [speaker, preferred]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()

    audio.catalog.append(newcomer)
    audio.defaults[.output] = newcomer.platformID
    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == preferred.platformID)
    #expect(audio.selections.last?.1 == preferred.platformID)
}

@Test
@MainActor
func unlinkedHeadsetIsSkippedDuringAutomaticSelection() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let unlinked = output(1, "jabra", "Jabra Link 380")
    let fallback = output(2, "airpods", "AirPods Pro")
    audio.catalog = [unlinked, fallback]
    let model = testModel(
        audio: audio,
        defaults: defaults,
        usable: { $0.uid != "jabra" },
        state: { $0.uid == "jabra" ? .down : nil }
    )

    model.start()

    #expect(audio.selections.last?.1 == fallback.platformID)
    #expect(model.linkState(for: unlinked) == .down)
    // The menu bar warning follows the active output only, so a powered-off
    // device we already switched away from must not raise it.
    #expect(!model.isActiveOutputLinkDown)
}

@Test
@MainActor
func menuBarWarningTracksOnlyTheActiveOutputBeingUnplayable() {
    let defaults = isolatedDefaults()

    // Manual mode parks the user on a headset that is powered off, which is
    // the case automatic switching cannot rescue them from.
    let audio = FakeAudio()
    let jabra = output(1, "jabra", "Jabra Link 380")
    audio.catalog = [jabra]
    let stranded = testModel(
        audio: audio,
        defaults: defaults,
        usable: { _ in true },
        state: { $0.uid == "jabra" ? .down : nil }
    )
    stranded.start()
    #expect(stranded.currentOutputID == jabra.platformID)
    #expect(stranded.isActiveOutputLinkDown)

    // Every other link state leaves the warning off, including the transient
    // checking window and the two states that mean "not known".
    for state in [LinkState.up, .checking, .unknown, .monitoringUnavailable] {
        let audio = FakeAudio()
        audio.catalog = [jabra]
        let model = testModel(
            audio: audio,
            defaults: defaults,
            usable: { _ in true },
            state: { _ in state }
        )
        model.start()
        #expect(!model.isActiveOutputLinkDown)
    }

    // No selected output at all.
    let empty = FakeAudio()
    let idle = testModel(audio: empty, defaults: defaults)
    idle.start()
    #expect(idle.currentOutputDevice == nil)
    #expect(!idle.isActiveOutputLinkDown)
}

@Test
@MainActor
func fullDuplexMuteStateIsRoleScoped() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    audio.catalog = [input(7, "shared"), output(7, "shared")]
    audio.muted = ["input:7"]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.isMuted(input(7, "shared")))
    #expect(!model.isMuted(output(7, "shared")))
}

@Test
@MainActor
func reduceMotionKeepsMutedMicrophoneIndicatorSteady() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let microphone = input(1, "microphone")
    audio.catalog = [microphone]
    audio.defaults[.input] = microphone.platformID
    audio.muted = ["input:1"]
    let model = AppModel(
        store: PriorityStore(defaults: defaults),
        audio: audio.operations,
        link: LinkOperations(isUsable: { _ in true }, state: { _ in nil }),
        reduceMotion: { true }
    )

    model.start()

    #expect(model.isActiveInputMuted)
    #expect(model.micFlashState)
    model.stop()
    #expect(!model.micFlashState)
}

@Test
@MainActor
func mutedMicPulsingOffKeepsMutedMicrophoneIndicatorSteady() {
    let defaults = isolatedDefaults()
    PriorityStore(defaults: defaults).mutedMicPulsing = false
    let audio = FakeAudio()
    let microphone = input(1, "microphone")
    audio.catalog = [microphone]
    audio.defaults[.input] = microphone.platformID
    audio.muted = ["input:1"]
    let model = AppModel(
        store: PriorityStore(defaults: defaults),
        audio: audio.operations,
        link: LinkOperations(isUsable: { _ in true }, state: { _ in nil })
    )

    model.start()

    #expect(model.isActiveInputMuted)
    #expect(model.micFlashState)
    model.stop()
    #expect(!model.micFlashState)
}

// Jabra Link 380 and the MacBook Pro microphone both expose a settable input
// mute on the main element (macOS 26, probed 2026-09-26), which FakeAudio
// models by default. ZoomAudioDevice has none and rests at zero volume.

@Test
@MainActor
func microphoneMuteMovesToTheNewMicrophone() {
    let audio = FakeAudio()
    let headset = input(1, "headset", "Jabra Link 380")
    let builtIn = input(2, "builtin", "MacBook Pro Microphone")
    audio.catalog = [headset, builtIn]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()

    model.setMicrophoneMuted(true)
    #expect(audio.muted == ["input:1"])

    audio.catalog = [builtIn]
    model.handleDevicesChanged()
    #expect(model.currentInputID == 2)
    #expect(model.isMicrophoneMuted)
    #expect(audio.muted.contains("input:2"))

    audio.catalog = [headset, builtIn]
    model.handleDevicesChanged()
    #expect(model.currentInputID == 1)
    #expect(audio.muted == ["input:1"])

    model.selectManually(builtIn)
    model.handleDefaultChanged(.input)
    #expect(audio.muted == ["input:2"])
    #expect(model.isActiveInputMuted)
}

@Test
@MainActor
func muteFallsBackToZeroVolumeAndRestoresTheLevel() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "zoom", "ZoomAudioDevice")]
    audio.noMuteProperty = [1]
    audio.inputVolumes = [1: 0.627]
    let defaults = isolatedDefaults()
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.setMicrophoneMuted(true)
    #expect(audio.inputVolumes[1] == 0)
    #expect(model.isActiveInputMuted)
    #expect(PriorityStore(defaults: defaults).appliedMicrophoneMutes["zoom"] != nil)

    model.setMicrophoneMuted(false)
    #expect(audio.inputVolumes[1] == 0.627)
    #expect(!model.isActiveInputMuted)
    #expect(PriorityStore(defaults: defaults).appliedMicrophoneMutes.isEmpty)
}

@Test
@MainActor
func aVirtualMicrophoneRestingAtZeroVolumeIsNotShownMuted() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "zoom", "ZoomAudioDevice")]
    audio.noMuteProperty = [1]
    audio.inputVolumes = [1: 0]
    let model = testModel(audio: audio, defaults: isolatedDefaults())

    model.start()

    #expect(!model.isMicrophoneMuted)
    #expect(!model.isActiveInputMuted)
}

@Test
@MainActor
func unmutingElsewhereClearsTheMute() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "mic")]
    let defaults = isolatedDefaults()
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    model.setMicrophoneMuted(true)

    audio.muted.remove("input:1")
    model.refreshMute()

    #expect(!model.isMicrophoneMuted)
    #expect(PriorityStore(defaults: defaults).appliedMicrophoneMutes.isEmpty)
}

@Test
@MainActor
func aHeadsetMuteButtonIsFollowed() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "headset")]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()

    audio.muted.insert("input:1")
    model.refreshMute()

    #expect(model.isMicrophoneMuted)
}

@Test
@MainActor
func aMicrophoneMutedWhileUnpluggedComesBackUnmuted() {
    let audio = FakeAudio()
    let headset = input(1, "headset")
    let builtIn = input(2, "builtin")
    audio.catalog = [headset, builtIn]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()
    model.setMicrophoneMuted(true)

    audio.catalog = [builtIn]
    model.handleDevicesChanged()
    model.setMicrophoneMuted(false)
    audio.catalog = [headset, builtIn]
    model.handleDevicesChanged()

    #expect(model.currentInputID == 1)
    #expect(audio.muted.isEmpty)
    #expect(!model.isMicrophoneMuted)
}

@Test
@MainActor
func quittingRestoresAppliedMutes() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "mic")]
    let defaults = isolatedDefaults()
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    model.setMicrophoneMuted(true)

    model.stop()

    #expect(audio.muted.isEmpty)
    #expect(PriorityStore(defaults: defaults).appliedMicrophoneMutes.isEmpty)
}

@Test
@MainActor
func recordingIsReportedForTheCurrentMicrophoneOnly() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "mic"), input(2, "other")]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()
    audio.running = [2]
    model.refreshMute()
    #expect(!model.isInputRecording)

    audio.running = [1]
    model.refreshMute()
    #expect(model.isInputRecording)
}

@Test
@MainActor
func aConnectedHeadsetTriggersOneSwitchNotice() {
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()
    var notices: [[AudioDevice]] = []
    model.onAutomaticSwitch = { notices.append($0) }

    audio.catalog = [speaker, headphones]
    model.handleDevicesChanged()
    model.handleDefaultChanged(.output)

    #expect(notices.map { $0.map(\.uid) } == [["headphones"]])
}

@Test
@MainActor
func manualSelectionShowsNoSwitchNotice() {
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    audio.catalog = [speaker, output(2, "headphones", "AirPods Pro")]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()
    var notices: [[AudioDevice]] = []
    model.onAutomaticSwitch = { notices.append($0) }

    model.selectManually(speaker)
    model.handleDefaultChanged(.output)

    #expect(notices.isEmpty)
}

@Test
@MainActor
func startupShowsNoSwitchNotice() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "mic"), output(2, "speaker")]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    var notices: [[AudioDevice]] = []
    model.onAutomaticSwitch = { notices.append($0) }

    model.start()

    #expect(notices.isEmpty)
}

@Test
@MainActor
func movingTheMicrophoneLevelWhileMutedUnmutes() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "mic")]
    audio.inputVolumes = [1: 0.627]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()
    model.setMicrophoneMuted(true)

    model.setMicrophoneLevel(0.4)

    #expect(!model.isMicrophoneMuted)
    #expect(audio.muted.isEmpty)
    #expect(audio.inputVolumes[1] == 0.4)
    #expect(model.microphoneLevel == 0.4)
}

@Test
@MainActor
func aZeroVolumeMuteShowsTheLevelItWillRestore() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "zoom", "ZoomAudioDevice")]
    audio.noMuteProperty = [1]
    audio.inputVolumes = [1: 0.627]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()

    model.setMicrophoneMuted(true)

    #expect(audio.inputVolumes[1] == 0)
    #expect(model.microphoneLevel == 0.627)
}

@Test
@MainActor
func outputMuteTogglesAndRaisingTheVolumeUnmutes() {
    let audio = FakeAudio()
    audio.catalog = [output(1, "speaker")]
    audio.defaults = [.output: 1]
    audio.volume = 0.43
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()
    #expect(model.isOutputMutable)

    model.setOutputMuted(true)
    #expect(model.isActiveOutputMuted)

    model.setVolume(0.5)
    #expect(!model.isActiveOutputMuted)
    #expect(audio.muted.isEmpty)
}

@Test
@MainActor
func aMicrophoneWithNeitherMuteNorLevelCannotBeMuted() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "scarlett", "Scarlett Solo USB")]
    audio.defaults = [.input: 1]
    audio.noMuteProperty = [1]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()

    #expect(!model.isMicrophoneLevelControllable)
    #expect(!model.isMicrophoneMutable)
}

@Test
@MainActor
func anOutputWithNeitherVolumeNorMuteCannotBeControlled() {
    let audio = FakeAudio()
    audio.catalog = [output(1, "scarlett", "Scarlett Solo USB")]
    audio.defaults = [.output: 1]
    audio.noMuteProperty = [1]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()

    #expect(!model.isVolumeControllable)
    #expect(!model.isOutputMutable)
}

@Test
@MainActor
func urlCommandsMuteOnlyAMicrophoneThatCanBeMuted() {
    let audio = FakeAudio()
    audio.catalog = [input(1, "headset", "USB Headset")]
    audio.defaults = [.input: 1]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()

    model.perform(.toggleMicMute)
    #expect(model.isMicrophoneMuted)
    #expect(audio.muted == ["input:1"])
    model.perform(.muteMic)
    #expect(model.isMicrophoneMuted)
    model.perform(.toggleMicMute)
    #expect(!model.isMicrophoneMuted)
    #expect(audio.muted.isEmpty)
    model.perform(.unmuteMic)
    #expect(!model.isMicrophoneMuted)

    audio.noMuteProperty = [1]
    model.refreshVolume()
    model.perform(.muteMic)
    #expect(!model.isMicrophoneMuted)
    model.perform(.toggleMicMute)
    #expect(!model.isMicrophoneMuted)
}
