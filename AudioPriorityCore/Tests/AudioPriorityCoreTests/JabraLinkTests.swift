import Testing
@testable import AudioPriorityCore

@Test
func link380ElementDecodingHonorsColdReadTimestamp() {
    #expect(JabraLink.decodeElement(value: 0, linkedValue: 0))
    #expect(!JabraLink.decodeElement(value: 1, linkedValue: 0))
    #expect(JabraLink.snapshot(value: 0, timestamp: 0, linkedValue: 0) == nil)
    #expect(JabraLink.snapshot(value: 0, timestamp: 1, linkedValue: 0) == true)
    #expect(JabraLink.snapshot(value: 1, timestamp: 1, linkedValue: 0) == false)
}

@Test
func link390ReportDecodingIgnoresUnrelatedOrShortReports() {
    #expect(JabraLink.decodeReport(
        reportID: 4,
        expectedID: 4,
        bytes: [4, 0x08],
        byteIndex: 1,
        bitMask: 0x08
    ) == true)
    #expect(JabraLink.decodeReport(
        reportID: 4,
        expectedID: 4,
        bytes: [4, 0x00],
        byteIndex: 1,
        bitMask: 0x08
    ) == false)
    #expect(JabraLink.decodeReport(
        reportID: 3,
        expectedID: 4,
        bytes: [3, 0x08],
        byteIndex: 1,
        bitMask: 0x08
    ) == nil)
    #expect(JabraLink.decodeReport(
        reportID: 4,
        expectedID: 4,
        bytes: [4],
        byteIndex: 1,
        bitMask: 0x08
    ) == nil)
}

@Test
func automaticSelectionFailsOpenUnlessLinkIsConfirmedDown() {
    #expect(JabraLink.allowsSelection(isSupported: false, state: .unknown))
    #expect(JabraLink.allowsSelection(
        isSupported: true,
        state: .monitoringUnavailable
    ))
    #expect(JabraLink.allowsSelection(isSupported: true, state: .unknown))
    #expect(!JabraLink.allowsSelection(isSupported: true, state: .down))
    #expect(JabraLink.allowsSelection(isSupported: true, state: .up))
    // A pending authoritative answer is not permission to route audio.
    #expect(!JabraLink.allowsSelection(isSupported: true, state: .checking))
    #expect(JabraLink.allowsSelection(isSupported: false, state: .checking))
}

@Test
func onlyLinkDonglesAreLinkMonitored() {
    // A dongle publishes its audio device whether or not a headset is on, so
    // it needs monitoring.
    #expect(JabraLink.isDongleProduct("Jabra Link 380"))
    #expect(JabraLink.isDongleProduct("JABRA LINK 390"))
    #expect(JabraLink.isDongleProduct("Jabra Link 370"))
    #expect(JabraLink.isDongleProduct("USB Jabra Link 400"))

    // These are present whenever macOS lists them. Monitoring them would let
    // an empty pairing list mark a working device as off, which is the
    // regression risk for the speakerphone in tobi/AudioPriorityBar#39.
    #expect(!JabraLink.isDongleProduct("Jabra Speak2 75"))
    #expect(!JabraLink.isDongleProduct("Jabra Speak 750"))
    #expect(!JabraLink.isDongleProduct("Jabra Evolve2 85"))
    #expect(!JabraLink.isDongleProduct("Jabra Elite 8 Active"))
    #expect(!JabraLink.isDongleProduct("MacBook Pro Speakers"))
}

@Test
func productProfilesMatchCaseInsensitiveSubstrings() {
    #expect(JabraLink.profile(matching: "USB JABRA LINK 380")?.id == .link380)
    #expect(JabraLink.profile(matching: "Jabra Link 390")?.id == .link390)
    #expect(JabraLink.profile(matching: "Other headset") == nil)
}

@Test
func downTransitionWaitsAndCanBeCancelledByUp() {
    var state = DebouncedLinkState()
    let initial = state.observe(true)
    #expect(initial == .changed)
    #expect(state.effective == true)
    let down = state.observe(false)
    #expect(down == .scheduleDown)
    #expect(state.effective == true)
    let recovered = state.observe(true)
    #expect(recovered == .cancelDown)
    #expect(state.effective == true)
    let committed = state.commitDown()
    #expect(!committed)
}

@Test
func downTransitionCommitsOnlyWhileStillObservedDown() {
    var state = DebouncedLinkState()
    let seeded = state.seed(true)
    #expect(seeded)
    let down = state.observe(false)
    #expect(down == .scheduleDown)
    #expect(state.effective == true)
    let committed = state.commitDown()
    #expect(committed)
    #expect(state.effective == false)
    let duplicate = state.commitDown()
    #expect(!duplicate)
}

@Test
func reportedColdReadSeedsEffectiveStateWithoutDebounce() {
    var state = DebouncedLinkState()
    let seeded = state.seed(false)
    #expect(seeded)
    #expect(state.effective == false)
}
