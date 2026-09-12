import AudioPriorityCore
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
            }
        )
    }
}

@MainActor
func testModel(
    audio: FakeAudio,
    defaults: UserDefaults,
    usable: @escaping (AudioDevice) -> Bool = { _ in true },
    state: @escaping (AudioDevice) -> LinkState? = { _ in nil }
) -> AppModel {
    AppModel(
        store: PriorityStore(defaults: defaults),
        audio: audio.operations,
        link: LinkOperations(isUsable: usable, state: state)
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
func showAllRevealsExcludedDevicesInTheirOwnList() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let kept = output(1, "speaker")
    let excluded = output(2, "hdmi", "HDMI")
    store.hide(excluded, in: .speaker)
    let audio = FakeAudio()
    audio.catalog = [kept, excluded]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.speakerDevices == [kept])
    #expect(model.hiddenSpeakerDevices == [excluded])

    model.showAll = true
    model.refreshDevices()

    #expect(model.speakerDevices == [kept, excluded])
    #expect(model.hiddenSpeakerDevices.isEmpty)
}

@Test
@MainActor
func soundSettingsChoiceTurnsAutomaticOffAndSticks() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()

    audio.defaults[.output] = speaker.platformID
    model.handleDefaultChanged(.output)

    #expect(model.isManualMode)
    #expect(audio.selections.isEmpty)
    #expect(model.currentOutputID == speaker.platformID)
    #expect(model.activeOutputCategory == .speaker)

    model.handleDevicesChanged()

    #expect(audio.selections.isEmpty)
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
