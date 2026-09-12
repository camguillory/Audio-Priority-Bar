import AudioPriorityCore
import Testing
@testable import AudioPriorityBar

private func dualRole(isVirtual: Bool = false) -> (
    output: AudioDevice,
    input: AudioDevice
) {
    let name = isVirtual ? "ZoomAudioDevice" : "USB Headset"
    let baseUID = isVirtual
        ? "zoom.us.zoomaudiodevice.001"
        : "AppleUSBAudioEngine:Unknown Manufacturer:USB Headset:serial"
    return (
        AudioDevice(
            platformID: 1,
            uid: isVirtual ? baseUID : "\(baseUID):1",
            name: name,
            role: .output,
            isVirtual: isVirtual
        ),
        AudioDevice(
            platformID: 101,
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
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()

    audio.defaults[.output] = paired.output.platformID
    model.handleDefaultChanged(.output)

    #expect(model.isManualMode)
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
func automaticInputDoesNotPairAnExcludedCurrentOutput() {
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
func pairingNeverMovesOutputFromAnInputSelection() {
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
    #expect(model.currentOutputID == speaker.platformID)
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
        store.linksMicrophone = configuration.enabled
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

    model.setLinksMicrophone(false)

    #expect(!model.linksMicrophone)
    #expect(!model.store.linksMicrophone)
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
