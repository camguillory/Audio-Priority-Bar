import AudioPriorityCore
import Foundation
import Observation
import Testing
@testable import AudioPriorityBar

/// Boxes a flag so `withObservationTracking`'s `@Sendable` `onChange` closure
/// can set it without a strict-concurrency capture error; the model itself is
/// `@MainActor`, so the mutation is never actually concurrent in this test.
private final class ObservationFlag: @unchecked Sendable {
    var value = false
}

private func dualRole(
    isVirtual: Bool = false,
    serial: String = "serial",
    outputID: UInt32 = 1,
    inputID: UInt32 = 101
) -> (
    output: AudioDevice,
    input: AudioDevice
) {
    let name = isVirtual ? "ZoomAudioDevice" : "USB Headset"
    let baseUID = isVirtual
        ? "zoom.us.zoomaudiodevice.001"
        : "AppleUSBAudioEngine:Unknown Manufacturer:USB Headset:\(serial)"
    return (
        AudioDevice(
            platformID: outputID,
            uid: isVirtual ? baseUID : "\(baseUID):1",
            name: name,
            role: .output,
            isVirtual: isVirtual
        ),
        AudioDevice(
            platformID: inputID,
            uid: isVirtual ? baseUID : "\(baseUID):2",
            name: name,
            role: .input,
            isVirtual: isVirtual
        )
    )
}

@Test
@MainActor
func automaticDecisionExplainsPoweredOffHeadphone() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let jabra = output(2, "jabra", "Jabra Link 380")
    audio.catalog = [speaker, jabra]
    let model = testModel(
        audio: audio,
        defaults: defaults,
        usable: { $0.uid != jabra.uid },
        state: { $0.uid == jabra.uid ? .down : nil }
    )

    model.start()

    #expect(model.automaticOutputDecision.target == speaker)
    #expect(model.automaticOutputDecision.skipped == SkippedOutput(
        device: jabra,
        reason: .off
    ))
}

@Test
@MainActor
func automaticDecisionFailsOpenForUnknownHeadphone() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let jabra = output(2, "jabra", "Jabra Link 380")
    audio.catalog = [speaker, jabra]
    let model = testModel(
        audio: audio,
        defaults: defaults,
        usable: { _ in true },
        state: { $0.uid == jabra.uid ? .unknown : nil }
    )

    model.start()

    #expect(model.automaticOutputDecision.target == jabra)
    #expect(model.automaticOutputDecision.skipped == nil)
}

@Test
@MainActor
func automaticSelectionWaitsWhileADongleIsStillBeingChecked() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let jabra = output(2, "jabra", "Jabra Link 380")
    audio.catalog = [speaker, jabra]
    // The dongle lies about its link right after enumeration, so the monitor
    // reports `.checking` until its first authoritative answer arrives.
    var linkState: LinkState = .checking
    let model = testModel(
        audio: audio,
        defaults: defaults,
        usable: { device in
            device.uid == jabra.uid
                ? JabraLink.allowsSelection(isSupported: true, state: linkState)
                : true
        },
        state: { $0.uid == jabra.uid ? linkState : nil }
    )

    model.start()

    // Nothing is routed yet: choosing the speaker now would only be undone.
    #expect(model.automaticOutputDecision.isDeferred)
    #expect(model.automaticOutputDecision.target == nil)
    #expect(audio.selections.isEmpty)

    // A row reading `linkState(for:)` must be told to redraw as soon as the
    // dongle's verdict changes, not only when something unrelated (like
    // hover) happens to re-run its body afterward.
    let didInvalidate = ObservationFlag()
    withObservationTracking {
        _ = model.linkState(for: jabra)
    } onChange: {
        didInvalidate.value = true
    }

    // The answer arrives: the headset really is off, so the speaker wins.
    linkState = .down
    model.handleLinkChanged()

    #expect(didInvalidate.value)
    #expect(!model.automaticOutputDecision.isDeferred)
    #expect(model.automaticOutputDecision.target == speaker)
    #expect(audio.selections.contains { $0.1 == speaker.platformID })
    #expect(!audio.selections.contains { $0.1 == jabra.platformID })
}

@Test
@MainActor
func checkingDoesNotDeferDevicesAlreadyRuledOut() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let speaker = output(1, "speaker")
    let jabra = output(2, "jabra", "Jabra Link 380")
    // Never-auto-select by the user, so its link state is irrelevant and
    // waiting for it would stall selection for nothing.
    store.setNeverUse(jabra, true)
    let audio = FakeAudio()
    audio.catalog = [speaker, jabra]
    let model = testModel(
        audio: audio,
        defaults: defaults,
        usable: { _ in true },
        state: { $0.uid == jabra.uid ? .checking : nil }
    )

    model.start()

    #expect(!model.automaticOutputDecision.isDeferred)
    #expect(model.automaticOutputDecision.target == speaker)
    #expect(model.automaticOutputDecision.skipped == SkippedOutput(
        device: jabra,
        reason: .neverAutoSelect
    ))
}

@Test
@MainActor
func automaticDecisionExplainsNeverAutoSelect() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    store.setNeverUse(headphones, true)
    let audio = FakeAudio()
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.automaticOutputDecision.target == speaker)
    #expect(model.automaticOutputDecision.skipped == SkippedOutput(
        device: headphones,
        reason: .neverAutoSelect
    ))
}

@Test
@MainActor
func automaticDecisionIgnoresHiddenRowsShownForManagement() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    store.hide(headphones, in: .headphone)
    let audio = FakeAudio()
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.showAll = true

    model.start()

    #expect(model.automaticOutputDecision.target == speaker)
    #expect(model.automaticOutputDecision.skipped == nil)
}

@Test
@MainActor
func automaticDecisionStaysQuietForActiveTopDeviceAndManualMode() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let headphones = output(1, "headphones", "AirPods Pro")
    audio.catalog = [headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    #expect(model.currentOutputDevice == headphones)
    #expect(model.automaticOutputDecision.skipped == nil)

    model.setManualMode(true)

    #expect(model.automaticOutputDecision.target == nil)
    #expect(model.automaticOutputDecision.skipped == nil)
}

@Test
@MainActor
func activatingARowSelectsItOnlyWhenItIsNotAlreadyCurrent() throws {
    let audio = FakeAudio()
    let speakers = output(1, "speakers", "Desk Speakers")
    let monitor = output(2, "monitor", "Studio Monitor")
    audio.catalog = [speakers, monitor]
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()
    let current = try #require(model.currentOutputDevice)
    let other = current == speakers ? monitor : speakers
    audio.selections.removeAll()

    model.activate(current)

    #expect(audio.selections.isEmpty)
    #expect(!model.isManualMode)

    model.activate(other)

    #expect(model.currentOutputID == other.platformID)
    #expect(!model.isManualMode)
}

@Test
@MainActor
func panelKeysToggleAndStepTheHighlightedControls() {
    let audio = FakeAudio()
    let speakers = output(1, "speakers", "Desk Speakers")
    audio.catalog = [speakers]
    audio.defaults[.output] = speakers.platformID
    audio.volume = 0.5
    let model = testModel(audio: audio, defaults: isolatedDefaults())
    model.start()

    // No microphone, so no microphone level to walk through.
    #expect(model.panelItems == [.automatic, .outputLevel, .device(speakers.id), .showAll, .settings])

    #expect(model.adjust(.outputLevel, up: true))
    #expect(model.volume == 0.5625)
    model.setVolume(0.98)
    #expect(model.adjust(.outputLevel, up: true))
    #expect(model.volume == 1)
    #expect(!model.adjust(.automatic, up: true))
    #expect(!model.adjust(.microphoneLevel, up: true))

    model.use(.automatic)
    #expect(model.isManualMode)
    model.use(.outputLevel)
    #expect(model.isActiveOutputMuted)
    model.use(.showAll)
    #expect(model.showAll)
}

@Test
@MainActor
func automaticSelectionPairsAnAlreadyCurrentOutput() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    store.savePriorities([macMic, paired.input], role: .input)
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    audio.defaults[.output] = paired.output.platformID
    audio.defaults[.input] = macMic.platformID
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.currentOutputID == paired.output.platformID)
    #expect(model.currentInputID == paired.input.platformID)
    #expect(audio.selections.map(\.0) == [.input])
    #expect(audio.selections.map(\.1) == [paired.input.platformID])
}

@Test
@MainActor
func manualSelectionPairsPhysicalOutputAndInput() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    audio.defaults[.input] = macMic.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectManually(paired.output)

    #expect(model.currentOutputID == paired.output.platformID)
    #expect(model.currentInputID == paired.input.platformID)
    #expect(audio.selections.map(\.0) == [.output, .input])
}

@Test
@MainActor
func soundSettingsOutputSelectionPairsItsMicrophone() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let airPods = output(3, "airpods", "AirPods Pro")
    let macMic = input(2, "mac-mic")
    store.savePriorities([macMic, paired.input], role: .input)
    let audio = FakeAudio()
    audio.catalog = [airPods, paired.output, paired.input, macMic]
    let model = testModel(audio: audio, defaults: defaults, isUserPicking: { true })
    model.start()
    audio.selections.removeAll()

    audio.defaults[.output] = paired.output.platformID
    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentInputID == paired.input.platformID)
    #expect(audio.selections.map(\.0) == [.input])
    #expect(audio.selections.map(\.1) == [paired.input.platformID])
}

@Test
@MainActor
func failedOutputSelectionDoesNotMoveMicrophone() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    audio.defaults[.input] = macMic.platformID
    audio.selectionSucceeds = false
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    #expect(!model.select(paired.output))
    #expect(model.currentInputID == macMic.platformID)
    #expect(audio.selections.isEmpty)
}

@Test
@MainActor
func automaticOutputFailureDoesNotMoveItsMicrophone() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    store.savePriorities([macMic, paired.input], role: .input)
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    audio.defaults[.input] = macMic.platformID
    audio.failedSelectionRoles = [.output]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.currentOutputID == nil)
    #expect(model.currentInputID == macMic.platformID)
    #expect(audio.selections.isEmpty)
}

@Test
@MainActor
func automaticInputDoesNotPairANeverAutoSelectCurrentOutput() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    store.setNeverUse(paired.output, true)
    store.savePriorities([macMic, paired.input], role: .input)
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    audio.defaults[.output] = paired.output.platformID
    audio.defaults[.input] = macMic.platformID
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.currentOutputID == paired.output.platformID)
    #expect(model.currentInputID == macMic.platformID)
    #expect(audio.selections.isEmpty)
}

@Test
@MainActor
func selectingAMicrophoneAlsoSelectsItsOutputWhenEnabled() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let paired = dualRole()
    let speaker = output(2, "speaker")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, speaker]
    audio.defaults[.output] = speaker.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectManually(paired.input)

    #expect(model.currentInputID == paired.input.platformID)
    #expect(model.currentOutputID == paired.output.platformID)
    // Exactly the mic then its output: a returning cycle would fail this
    // count instead of only hanging.
    #expect(audio.selections.map(\.0) == [.input, .output])
}

@Test
@MainActor
func pickingAHeadsetMicrophoneKeepsItsOutputWithAutomaticOn() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let speaker = output(2, "speaker")
    store.setNeverUse(paired.output, true)
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, speaker]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    #expect(model.currentOutputID == speaker.platformID)

    model.selectManually(paired.input)
    model.handleDefaultChanged(.input)
    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentInputID == paired.input.platformID)
    #expect(model.currentOutputID == paired.output.platformID)
}

@Test
@MainActor
func selectingAMicrophoneLeavesOutputAloneWhenDisabled() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    store.selectsPairedDevice = false
    let paired = dualRole()
    let speaker = output(2, "speaker")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, speaker]
    audio.defaults[.output] = speaker.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectManually(paired.input)

    #expect(model.currentInputID == paired.input.platformID)
    #expect(model.currentOutputID == speaker.platformID)
}

@Test
@MainActor
func selectOnlyLeavesOutputAloneWhenPairedSelectionIsEnabled() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let paired = dualRole()
    let speaker = output(2, "speaker")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, speaker]
    audio.defaults[.output] = speaker.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectOnly(paired.input)

    #expect(model.currentInputID == paired.input.platformID)
    #expect(model.currentOutputID == speaker.platformID)
}

@Test
@MainActor
func selectOnlyOutputSurvivesItsDefaultChangeEcho() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let paired = dualRole()
    let speaker = output(2, "speaker")
    let macMic = input(102, "mac-mic")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, speaker, macMic]
    audio.defaults[.output] = speaker.platformID
    audio.defaults[.input] = macMic.platformID
    // The later changes are the user's own, made in Sound Settings.
    let model = testModel(audio: audio, defaults: defaults, isUserPicking: { true })
    model.start()

    model.selectOnly(paired.output)
    model.handleDefaultChanged(.output)

    #expect(model.currentOutputID == paired.output.platformID)
    #expect(model.currentInputID == macMic.platformID)

    audio.defaults[.output] = speaker.platformID
    model.handleDefaultChanged(.output)
    audio.defaults[.output] = paired.output.platformID
    model.handleDefaultChanged(.output)

    #expect(model.currentInputID == paired.input.platformID)
}

@Test
@MainActor
func selectOnlyDoesNotSuppressPairingForARecycledDeviceID() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let paired = dualRole()
    let speaker = output(2, "speaker")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, speaker]
    audio.defaults[.output] = speaker.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectOnly(paired.output)

    // CoreAudio reuses platform IDs, so another headset can arrive holding the
    // one "Output only" was applied to, and it still pairs normally.
    let replacement = dualRole(
        serial: "replacement",
        outputID: paired.output.platformID,
        inputID: 201
    )
    audio.catalog = [replacement.output, replacement.input, speaker]
    audio.defaults[.output] = replacement.output.platformID
    model.handleDefaultChanged(.output)

    #expect(model.currentInputID == replacement.input.platformID)
}

@Test
@MainActor
func automaticMicrophonePriorityDoesNotOverrideAnUnrelatedAutomaticOutput() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    // Forced rather than left to name detection, so this test exercises
    // priority order rather than headphone-keyword classification.
    store.setCategory(.speaker, for: paired.output)
    let macSpeaker = output(2, "mac-speaker")
    let macMic = input(2, "mac-mic")
    store.savePriorities([macSpeaker, paired.output], category: .speaker)
    store.savePriorities([paired.input, macMic], role: .input)
    let audio = FakeAudio()
    audio.catalog = [macSpeaker, macMic, paired.output, paired.input]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    // Output and microphone priority lists stay independent unless the
    // current output is itself the anchor: a microphone chosen purely by its
    // own priority must not reach back and move an unrelated output that
    // automatic selection already, separately, decided on.
    #expect(model.currentOutputID == macSpeaker.platformID)
    #expect(model.currentInputID == paired.input.platformID)
}

@Test
@MainActor
func explicitPairedSelectionWorksWhenDefaultIsSingleDevice() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    store.selectsPairedDevice = false
    let paired = dualRole()
    let speaker = output(2, "speaker")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, speaker]
    audio.defaults[.output] = speaker.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectWithPairedDevice(paired.input)

    #expect(model.currentOutputID == paired.output.platformID)
    #expect(model.currentInputID == paired.input.platformID)
}

@Test
@MainActor
func selectWithPairedDeviceStopsAtAFailedOutputSelection() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    audio.defaults[.input] = macMic.platformID
    audio.failedSelectionRoles = [.output]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectWithPairedDevice(paired.input)

    #expect(model.currentInputID == macMic.platformID)
    #expect(audio.selections.isEmpty)
}

/// A USB headset beside the speakers and the Mac's microphone, left out of
/// automatic switching so using it takes a pick.
@MainActor
private struct HeadsetDesk {
    let audio = FakeAudio()
    let defaults = isolatedDefaults()
    let headset = dualRole()
    let speaker = output(2, "speaker")
    let macMic = input(102, "mac-mic")

    func model(
        selectsPairedDevice: Bool = true,
        headsetMicFirst: Bool = false,
        isUserPicking: @escaping () -> Bool = { false }
    ) -> AppModel {
        let store = PriorityStore(defaults: defaults)
        store.selectsPairedDevice = selectsPairedDevice
        store.setNeverUse(headset.output, true)
        store.savePriorities(
            headsetMicFirst ? [headset.input, macMic] : [macMic, headset.input],
            role: .input
        )
        audio.catalog = [headset.output, headset.input, speaker, macMic]
        let model = testModel(audio: audio, defaults: defaults, isUserPicking: isUserPicking)
        model.start()
        audio.selections.removeAll()
        return model
    }
}

@Test
@MainActor
func outputOnlyKeepsTheMicrophoneWithAutomaticOn() {
    let desk = HeadsetDesk()
    let model = desk.model()
    #expect(model.currentInputID == desk.macMic.platformID)

    model.selectOnly(desk.headset.output)
    model.handleDefaultChanged(.output)
    model.handleDefaultChanged(.input)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == desk.headset.output.platformID)
    #expect(model.currentInputID == desk.macMic.platformID)
    #expect(desk.audio.selections.map(\.1) == [desk.headset.output.platformID])
}

@Test
@MainActor
func outputOnlyHoldsThroughASwitchBack() {
    let desk = HeadsetDesk()
    let model = desk.model()
    model.selectOnly(desk.headset.output)
    model.handleDefaultChanged(.output)
    desk.audio.selections.removeAll()

    desk.audio.defaults[.output] = desk.speaker.platformID
    model.handleDefaultChanged(.output)
    model.handleDefaultChanged(.input)

    #expect(model.currentOutputID == desk.headset.output.platformID)
    #expect(model.currentInputID == desk.macMic.platformID)
    #expect(desk.audio.selections.map(\.1) == [desk.headset.output.platformID])
}

@Test
@MainActor
func aDeviceConnectingEndsAnOutputOnlyPick() {
    let desk = HeadsetDesk()
    let model = desk.model()
    model.selectOnly(desk.headset.output)
    model.handleDefaultChanged(.output)
    // The headset becomes the list's only choice.
    model.store.setNeverUse(desk.headset.output, false)
    model.store.setNeverUse(desk.speaker, true)

    desk.audio.catalog.append(input(103, "usb-mic", "USB Mic"))
    model.handleDevicesChanged()

    #expect(model.currentOutputID == desk.headset.output.platformID)
    #expect(model.currentInputID == desk.headset.input.platformID)
}

@Test
@MainActor
func micOnlyKeepsTheOutputWithAutomaticOn() {
    let desk = HeadsetDesk()
    let model = desk.model()
    #expect(model.currentOutputID == desk.speaker.platformID)

    model.selectOnly(desk.headset.input)
    model.handleDefaultChanged(.input)

    #expect(!model.isManualMode)
    #expect(model.currentInputID == desk.headset.input.platformID)
    #expect(model.currentOutputID == desk.speaker.platformID)
    #expect(desk.audio.selections.map(\.1) == [desk.headset.input.platformID])
}

@Test
@MainActor
func useBothKeepsBothHalvesWithAutomaticOn() {
    let desk = HeadsetDesk()
    let model = desk.model(selectsPairedDevice: false)

    model.selectWithPairedDevice(desk.headset.input)
    model.handleDefaultChanged(.output)
    model.handleDefaultChanged(.input)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == desk.headset.output.platformID)
    #expect(model.currentInputID == desk.headset.input.platformID)
}

@Test
@MainActor
func aHeadsetOutputPickedInControlCenterStillBringsItsMicrophone() {
    let desk = HeadsetDesk()
    let model = desk.model(headsetMicFirst: true, isUserPicking: { true })
    desk.audio.defaults[.input] = desk.macMic.platformID
    model.handleDefaultChanged(.input)

    desk.audio.defaults[.output] = desk.headset.output.platformID
    model.handleDefaultChanged(.output)
    model.handleDefaultChanged(.input)

    #expect(model.currentInputID == desk.headset.input.platformID)
}

@Test
@MainActor
func pairingSkipsMissingHiddenVirtualAndDisabledPartners() {
    let configurations: [(virtual: Bool, hidden: Bool, enabled: Bool)] = [
        (false, true, true),
        (true, false, true),
        (false, false, false),
    ]
    for configuration in configurations {
        let defaults = isolatedDefaults()
        let store = PriorityStore(defaults: defaults)
        store.isManualMode = true
        store.selectsPairedDevice = configuration.enabled
        let paired = dualRole(isVirtual: configuration.virtual)
        let macMic = input(2, "mac-mic")
        if configuration.hidden { store.hide(paired.input) }
        let audio = FakeAudio()
        audio.catalog = [paired.output, paired.input, macMic]
        audio.defaults[.input] = macMic.platformID
        let model = testModel(audio: audio, defaults: defaults)
        model.start()

        model.selectManually(paired.output)

        #expect(model.currentInputID == macMic.platformID)
    }

    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let outputOnly = output(1, "output-only")
    let macMic = input(2, "mac-mic")
    let audio = FakeAudio()
    audio.catalog = [outputOnly, macMic]
    audio.defaults[.input] = macMic.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.selectManually(outputOnly)

    #expect(model.currentInputID == macMic.platformID)
}

@Test
@MainActor
func automaticPairingRespectsMicrophoneNeverAutoSelect() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    store.setNeverUse(paired.input, true)
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    let model = testModel(audio: audio, defaults: defaults)

    model.start()

    #expect(model.currentOutputID == paired.output.platformID)
    #expect(model.currentInputID == macMic.platformID)
}

@Test
@MainActor
func automaticOutputEchoRespectsMicrophoneNeverAutoSelect() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    store.setNeverUse(paired.input, true)
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    audio.defaults[.output] = paired.output.platformID
    audio.defaults[.input] = macMic.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()

    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentInputID == macMic.platformID)
    #expect(audio.selections.isEmpty)
}

@Test
@MainActor
func disablingPairingReappliesAutomaticMicrophonePriority() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let macMic = input(2, "mac-mic")
    store.savePriorities([macMic, paired.input], role: .input)
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, macMic]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    #expect(model.currentInputID == paired.input.platformID)

    model.setSelectsPairedDevice(false)

    #expect(!model.selectsPairedDevice)
    #expect(!model.store.selectsPairedDevice)
    #expect(model.currentInputID == macMic.platformID)
}

@Test
@MainActor
func externalNeverAutoSelectOutputStillPairsItsMicrophone() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let paired = dualRole()
    let speaker = output(2, "speaker")
    let macMic = input(3, "mac-mic")
    store.setNeverUse(paired.output, true)
    store.setNeverUse(speaker, true)
    let audio = FakeAudio()
    audio.catalog = [paired.output, paired.input, speaker, macMic]
    audio.defaults[.output] = speaker.platformID
    audio.defaults[.input] = macMic.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.defaults[.output] = paired.output.platformID
    model.handleDefaultChanged(.output)

    #expect(model.currentInputID == paired.input.platformID)
}

@Test
@MainActor
func deviceCallbackBeforeDefaultCallbackDoesNotEnableManual() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let speaker = output(1, "speaker")
    let newcomer = output(2, "new", "USB Headphones")
    store.setNeverUse(newcomer, true)
    let audio = FakeAudio()
    audio.catalog = [speaker]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog.append(newcomer)
    audio.defaults[.output] = newcomer.platformID
    model.handleDevicesChanged()
    audio.defaults[.output] = newcomer.platformID
    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == speaker.platformID)
}

/// A desk where the speakers go with a room microphone and the headphones with
/// a lapel microphone, with Microphones follow the output turned on.
@MainActor
private struct FollowingDesk {
    let defaults = isolatedDefaults()
    let store: PriorityStore
    let audio = FakeAudio()
    let speaker = output(1, "speaker", "Desk Speakers")
    let headphones = output(2, "headphones", "Studio Headphones")
    let roomMic = input(3, "room-mic", "Room Mic")
    let lapelMic = input(4, "lapel-mic", "Lapel Mic")
    let macMic = input(5, "mac-mic", "MacBook Pro Microphone")

    init(following: Bool = true) {
        store = PriorityStore(defaults: defaults)
        store.setCategory(.headphone, for: headphones)
        store.savePriorities([roomMic, lapelMic, macMic], role: .input)
        if following {
            store.microphonesFollowOutput = true
            store.savePriorities([lapelMic, roomMic, macMic], microphonesFor: .headphone)
        }
    }

    func model(isUserPicking: @escaping () -> Bool = { false }) -> AppModel {
        testModel(audio: audio, defaults: defaults, isUserPicking: isUserPicking)
    }
}

@Test
@MainActor
func connectingHeadphonesSelectsTheHeadphoneMicrophoneOrder() {
    let desk = FollowingDesk()
    desk.audio.catalog = [desk.speaker, desk.roomMic, desk.lapelMic]
    let model = desk.model()
    model.start()
    #expect(model.currentInputID == desk.roomMic.platformID)

    desk.audio.catalog.append(desk.headphones)
    model.handleDevicesChanged()

    #expect(model.currentOutputID == desk.headphones.platformID)
    #expect(model.currentInputID == desk.lapelMic.platformID)
}

@Test
@MainActor
func disconnectingHeadphonesReturnsToTheSpeakerMicrophoneOrder() {
    let desk = FollowingDesk()
    desk.audio.catalog = [desk.speaker, desk.headphones, desk.roomMic, desk.lapelMic]
    let model = desk.model()
    model.start()
    #expect(model.currentInputID == desk.lapelMic.platformID)

    desk.audio.catalog = [desk.speaker, desk.roomMic, desk.lapelMic]
    model.handleDevicesChanged()

    #expect(model.currentOutputID == desk.speaker.platformID)
    #expect(model.currentInputID == desk.roomMic.platformID)
}

@Test
@MainActor
func pickingAnOutputInControlCenterMovesTheMicrophone() {
    let desk = FollowingDesk()
    desk.audio.catalog = [desk.speaker, desk.headphones, desk.roomMic, desk.lapelMic]
    let model = desk.model(isUserPicking: { true })
    model.start()
    var notices: [[AudioDevice]] = []
    model.onAutomaticSwitch = { notices.append($0) }

    desk.audio.defaults[.output] = desk.speaker.platformID
    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == desk.speaker.platformID)
    #expect(model.currentInputID == desk.roomMic.platformID)
    #expect(notices.map { $0.map(\.uid) } == [["room-mic"]])
}

@Test
@MainActor
func aPairedUsbHeadsetMicrophoneStillWins() {
    let desk = FollowingDesk()
    let headset = dualRole(outputID: 6, inputID: 106)
    desk.store.setCategory(.headphone, for: headset.output)
    desk.audio.catalog = [desk.speaker, desk.roomMic, desk.lapelMic]
    let model = desk.model()
    model.start()

    desk.audio.catalog += [headset.output, headset.input]
    model.handleDevicesChanged()

    #expect(model.currentOutputID == headset.output.platformID)
    #expect(model.currentInputID == headset.input.platformID)
}

@Test
@MainActor
func aMicrophonePickedInControlCenterSurvivesAnOutputChange() {
    let desk = FollowingDesk()
    desk.audio.catalog = [
        desk.speaker, desk.headphones, desk.roomMic, desk.lapelMic, desk.macMic,
    ]
    let model = desk.model(isUserPicking: { true })
    model.start()

    desk.audio.defaults[.input] = desk.macMic.platformID
    model.handleDefaultChanged(.input)
    desk.audio.defaults[.output] = desk.speaker.platformID
    model.handleDefaultChanged(.output)

    #expect(model.currentOutputID == desk.speaker.platformID)
    #expect(model.currentInputID == desk.macMic.platformID)
}

@Test
@MainActor
func manualModeLeavesTheMicrophoneAlone() {
    let desk = FollowingDesk()
    desk.audio.catalog = [desk.speaker, desk.headphones, desk.roomMic, desk.lapelMic]
    desk.audio.defaults[.output] = desk.speaker.platformID
    desk.audio.defaults[.input] = desk.roomMic.platformID
    desk.store.isManualMode = true
    let model = desk.model()
    model.start()

    model.selectManually(desk.headphones)

    #expect(model.currentOutputID == desk.headphones.platformID)
    #expect(model.currentInputID == desk.roomMic.platformID)
}

@Test
@MainActor
func editingTheOtherOrderDoesNotSwitchTheMicrophone() {
    let desk = FollowingDesk()
    desk.store.savePriorities([desk.roomMic, desk.lapelMic, desk.macMic], microphonesFor: .headphone)
    desk.audio.catalog = [desk.speaker, desk.roomMic, desk.lapelMic]
    let model = desk.model()
    model.start()
    desk.audio.selections.removeAll()

    model.viewMicrophoneOrder(for: .headphone)
    model.moveInput(from: IndexSet(integer: 1), to: 0)

    #expect(model.currentInputID == desk.roomMic.platformID)
    #expect(desk.audio.selections.isEmpty)
    #expect(desk.store.sorted([desk.roomMic, desk.lapelMic], microphonesFor: .headphone)
        .map(\.uid) == ["lapel-mic", "room-mic"])
    #expect(desk.store.sorted([desk.roomMic, desk.lapelMic], microphonesFor: .speaker)
        .map(\.uid) == ["room-mic", "lapel-mic"])
}

@Test
@MainActor
func withTheSettingOffOneOrderServesBoth() {
    let desk = FollowingDesk()
    desk.store.microphonesFollowOutput = false
    desk.audio.catalog = [desk.speaker, desk.roomMic, desk.lapelMic]
    let model = desk.model()
    model.start()

    desk.audio.catalog.append(desk.headphones)
    model.handleDevicesChanged()

    #expect(model.currentOutputID == desk.headphones.platformID)
    #expect(model.currentInputID == desk.roomMic.platformID)
}

@Test
@MainActor
func reorderingInManualModeLeavesTheMicrophoneAlone() {
    let desk = FollowingDesk()
    desk.audio.catalog = [desk.speaker, desk.roomMic, desk.lapelMic]
    desk.audio.defaults[.output] = desk.speaker.platformID
    desk.audio.defaults[.input] = desk.roomMic.platformID
    desk.store.isManualMode = true
    let model = desk.model()
    model.start()

    model.moveInput(from: IndexSet(integer: 1), to: 0)

    #expect(model.inputDevices.map(\.uid) == ["lapel-mic", "room-mic"])
    #expect(model.currentInputID == desk.roomMic.platformID)
    #expect(desk.audio.selections.isEmpty)
}

@Test
@MainActor
func theMicrophoneIsChosenForTheOutputJustSelected() {
    let desk = FollowingDesk()
    desk.audio.catalog = [desk.speaker, desk.headphones, desk.roomMic, desk.lapelMic]
    desk.audio.defaults[.output] = desk.speaker.platformID
    desk.audio.defaults[.input] = desk.roomMic.platformID
    let model = desk.model()

    model.start()

    #expect(model.currentOutputID == desk.headphones.platformID)
    #expect(model.currentInputID == desk.lapelMic.platformID)
    #expect(desk.audio.selections.map(\.0) == [.output, .input])
}

/// Two profiles over the same hardware: at the desk the desk speakers and the
/// room microphone come first, while travelling the laptop's own do.
@MainActor
private struct TwoProfiles {
    let defaults = isolatedDefaults()
    let store: PriorityStore
    let audio = FakeAudio()
    let deskSpeakers = output(1, "desk-speakers", "Desk Speakers")
    let laptopSpeakers = output(2, "laptop-speakers", "MacBook Pro Speakers")
    let roomMic = input(3, "room-mic", "Room Mic")
    let laptopMic = input(4, "laptop-mic", "MacBook Pro Microphone")
    let deskID: UUID
    let travelID: UUID

    init(travelIsManual: Bool = false) {
        store = PriorityStore(defaults: defaults)
        store.savePriorities([deskSpeakers, laptopSpeakers], category: .speaker)
        store.savePriorities([roomMic, laptopMic], role: .input)
        deskID = store.profiles[0].id
        travelID = store.addProfile(named: "Travel").id
        store.loadProfile(travelID)
        store.savePriorities([laptopSpeakers, deskSpeakers], category: .speaker)
        store.savePriorities([laptopMic, roomMic], role: .input)
        store.isManualMode = travelIsManual
        store.loadProfile(deskID)
        audio.catalog = [deskSpeakers, laptopSpeakers, roomMic, laptopMic]
    }

    func model(isUserPicking: @escaping () -> Bool = { false }) -> AppModel {
        testModel(audio: audio, defaults: defaults, isUserPicking: isUserPicking)
    }
}

@Test
@MainActor
func applyingAProfileSelectsItsTopDevicesAtOnce() {
    let setup = TwoProfiles()
    let model = setup.model()
    model.start()
    #expect(model.currentOutputID == setup.deskSpeakers.platformID)
    var applied: [(String, [String])] = []
    model.onProfileApplied = { applied.append(($0, $1.map(\.uid))) }

    #expect(model.applyProfile(id: setup.travelID, announces: true))

    #expect(model.activeProfileID == setup.travelID)
    #expect(model.currentOutputID == setup.laptopSpeakers.platformID)
    #expect(model.currentInputID == setup.laptopMic.platformID)
    #expect(applied.map(\.0) == ["Travel"])
    #expect(applied.first?.1 == ["laptop-speakers", "laptop-mic"])
}

@Test
@MainActor
func aManualProfileSelectsOnceThenHolds() {
    let setup = TwoProfiles(travelIsManual: true)
    let model = setup.model()
    model.start()

    model.applyProfile(id: setup.travelID)
    #expect(model.isManualMode)
    #expect(model.currentOutputID == setup.laptopSpeakers.platformID)

    let headphones = output(5, "headphones", "AirPods Pro")
    setup.audio.catalog.append(headphones)
    model.handleDevicesChanged()

    #expect(model.currentOutputID == setup.laptopSpeakers.platformID)
}

@Test
@MainActor
func applyingAProfileClearsAControlCenterPick() {
    let setup = TwoProfiles()
    let model = setup.model(isUserPicking: { true })
    model.start()
    setup.audio.defaults[.output] = setup.laptopSpeakers.platformID
    model.handleDefaultChanged(.output)
    #expect(model.currentOutputID == setup.laptopSpeakers.platformID)

    // Applying the profile already in use is how a shortcut asks for its
    // devices back.
    model.applyProfile(id: setup.deskID)

    #expect(model.currentOutputID == setup.deskSpeakers.platformID)
    #expect(model.keptPicks.isEmpty)
}

@Test
@MainActor
func aProfileWithAMissingDeviceFallsBackByPriority() {
    let setup = TwoProfiles()
    setup.audio.catalog = [setup.deskSpeakers, setup.laptopSpeakers, setup.roomMic]
    let model = setup.model()
    model.start()

    model.applyProfile(id: setup.travelID)

    #expect(model.currentOutputID == setup.laptopSpeakers.platformID)
    #expect(model.currentInputID == setup.roomMic.platformID)
}

@Test
@MainActor
func panelKeysStepThroughProfilesAndMicrophoneOrders() throws {
    let setup = TwoProfiles()
    let model = setup.model()
    model.start()
    #expect(model.panelItems.contains(.profile))
    #expect(!model.panelItems.contains(.microphoneOrder))

    #expect(model.adjust(.profile, up: true))
    #expect(model.activeProfileID == setup.travelID)
    // Past the last profile it comes back round to the first.
    #expect(model.adjust(.profile, up: true))
    #expect(model.activeProfileID == setup.deskID)
    #expect(model.adjust(.profile, up: false))
    #expect(model.activeProfileID == setup.travelID)

    #expect(!model.adjust(.microphoneOrder, up: true))
    model.setMicrophonesFollowOutput(true)
    let items = model.panelItems
    let order = try #require(items.firstIndex(of: .microphoneOrder))
    #expect(items[order + 1] == .device(model.inputDevices[0].id))
    #expect(model.adjust(.microphoneOrder, up: true))
    #expect(model.microphoneOrderCategory == .headphone)
    model.use(.microphoneOrder)
    #expect(model.microphoneOrderCategory == .speaker)
}
