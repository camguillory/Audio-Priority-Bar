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
func aggregatePrefersUpAndRequiresEverySignalForDown() {
    #expect(JabraLink.aggregate([]) == .monitoringUnavailable)
    #expect(JabraLink.aggregate([nil]) == .monitoringUnavailable)
    #expect(JabraLink.aggregate([false]) == .down)
    #expect(JabraLink.aggregate([false, nil]) == .unknown)
    #expect(JabraLink.aggregate([false, true]) == .up)
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
