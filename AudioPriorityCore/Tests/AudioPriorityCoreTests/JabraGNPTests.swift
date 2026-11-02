import Testing
@testable import AudioPriorityCore

// Byte sequences below were captured from a Jabra Link 380 (PID 0x24ca)
// paired with an Evolve2 85. Frames are shown as canonical bodies, meaning the
// physical HID report ID has already been stripped.

/// Link 380 management collection: report 5 in both directions, 63 body bytes.
private let link380Elements = [
    JabraGNP.Element(direction: .input, reportID: 5, bits: 504),
    JabraGNP.Element(direction: .output, reportID: 5, bits: 504),
]

/// Record reply for the connected Evolve2 85: cursor 00 01, state 03.
private let connectedRecord: [UInt8] = [
    0x00, 0x01, 0x03, 0x00, 0x04, 0x11,
    0x70, 0xbf, 0x92, 0xf4, 0x2f, 0xb8,
    0x04, 0x01, 0x67, 0x00,
]

/// Record reply for a remembered but disconnected device: state 01.
private let disconnectedRecord: [UInt8] = [
    0x00, 0x02, 0x01, 0x00, 0x00, 0x11,
    0x20, 0x64, 0xde, 0xca, 0x65, 0x75,
    0xff, 0xfc, 0xff, 0x00,
]

/// Final record in a database: the cursor terminates the walk.
private let lastRecord: [UInt8] = [
    0xff, 0xff, 0x01, 0x00, 0x00, 0x11,
    0x7b, 0x86, 0x95, 0xd3, 0x10, 0x3a,
    0xff, 0xfc, 0xff, 0x00,
]

/// Canonical reply body for `connectedRecord`: six header bytes plus sixteen
/// argument bytes, so the declared length is 22 (0xc0 | 0x16 == 0xd6).
private let connectedReplyBody: [UInt8] =
    [0x00, 0x01, 0x12, 0xd6, 0x0d, 0x28] + connectedRecord

@Test
func layoutComesFromTheDescriptorRatherThanAHardCodedReportID() {
    let layout = JabraGNP.selectLayout(link380Elements)
    #expect(layout?.inputReportID == 5)
    #expect(layout?.outputReportID == 5)
    #expect(layout?.outputFrameLength == 63)

    // A dongle numbering its management reports differently is still usable.
    let relocated = JabraGNP.selectLayout([
        JabraGNP.Element(direction: .input, reportID: 9, bits: 256),
        JabraGNP.Element(direction: .output, reportID: 8, bits: 256),
    ])
    #expect(relocated?.inputReportID == 9)
    #expect(relocated?.outputReportID == 8)
    #expect(relocated?.outputFrameLength == 32)
}

@Test
func layoutRejectsUnusableOrAmbiguousCollections() {
    // Only one direction present.
    #expect(JabraGNP.selectLayout([link380Elements[0]]) == nil)
    // Report ID 0 is not a numbered report.
    #expect(JabraGNP.selectLayout([
        JabraGNP.Element(direction: .input, reportID: 0, bits: 504),
        JabraGNP.Element(direction: .output, reportID: 0, bits: 504),
    ]) == nil)
    // Too small to carry a header.
    #expect(JabraGNP.selectLayout([
        JabraGNP.Element(direction: .input, reportID: 5, bits: 8),
        JabraGNP.Element(direction: .output, reportID: 5, bits: 8),
    ]) == nil)
    // Not byte aligned.
    #expect(JabraGNP.selectLayout([
        JabraGNP.Element(direction: .input, reportID: 5, bits: 12),
        JabraGNP.Element(direction: .output, reportID: 5, bits: 12),
    ]) == nil)
    // Two different input reports is ambiguous, so fall back instead.
    #expect(JabraGNP.selectLayout(link380Elements + [
        JabraGNP.Element(direction: .input, reportID: 7, bits: 504),
    ]) == nil)
}

@Test
func encodedQueryMatchesTheBytesTheVendorStackSends() {
    let arguments = JabraGNP.recordArguments(cursor: [0x00, 0x00], bluetoothType: 0)
    let body = JabraGNP.encodeQuery(
        sequence: 0x12,
        group: JabraGNP.pairingGroup,
        op: JabraGNP.recordOp,
        arguments: arguments,
        frameLength: 63
    )
    // destination 01, host 00, sequence 12, query|length 49, class 0d, op 28.
    #expect(body?.prefix(9) == [0x01, 0x00, 0x12, 0x49, 0x0d, 0x28, 0x00, 0x00, 0x00])
    #expect(body?.count == 63)
    #expect(body?.dropFirst(9).allSatisfy { $0 == 0 } == true)
}

@Test
func encodedQueryRefusesArgumentsThatWouldNotFitOneFrame() {
    #expect(JabraGNP.encodeQuery(
        sequence: 1,
        group: JabraGNP.pairingGroup,
        op: JabraGNP.recordOp,
        arguments: [UInt8](repeating: 0, count: 4),
        frameLength: 8
    ) == nil)
    #expect(JabraGNP.encodeQuery(
        sequence: 1,
        group: JabraGNP.pairingGroup,
        op: JabraGNP.recordOp,
        arguments: [UInt8](repeating: 0, count: 64),
        frameLength: 63
    ) == nil)
}

@Test
func decodeReadsTheDeclaredLengthAndIgnoresTrailingPadding() {
    var body = connectedReplyBody
    body += [UInt8](repeating: 0, count: 63 - body.count)
    let message = JabraGNP.decode(body)
    #expect(message?.destination == JabraGNP.hostAddress)
    #expect(message?.source == JabraGNP.dongleAddress)
    #expect(message?.sequence == 0x12)
    #expect(message?.kind == JabraGNP.replyKind)
    #expect(message?.group == JabraGNP.pairingGroup)
    #expect(message?.op == JabraGNP.recordOp)
    #expect(message?.arguments == connectedRecord)
}

@Test
func decodeRejectsShortAndInconsistentBodies() {
    #expect(JabraGNP.decode([0x00, 0x01, 0x12]) == nil)
    // Declared length below the header size.
    #expect(JabraGNP.decode([0x00, 0x01, 0x12, 0xc3, 0x0d, 0x28]) == nil)
    // Declares more bytes than were received.
    #expect(JabraGNP.decode([0x00, 0x01, 0x12, 0xd6, 0x0d, 0x28]) == nil)
}

@Test
func replyMatchingRejectsStaleRepliesAndUnsolicitedEvents() {
    let reply = JabraGNP.Message(
        destination: JabraGNP.hostAddress,
        source: JabraGNP.dongleAddress,
        sequence: 0x12,
        kind: JabraGNP.replyKind,
        group: JabraGNP.pairingGroup,
        op: JabraGNP.recordOp,
        arguments: connectedRecord
    )
    let expected = (
        sequence: UInt8(0x12),
        group: JabraGNP.pairingGroup,
        op: JabraGNP.recordOp
    )
    #expect(JabraGNP.isReply(
        reply, sequence: expected.sequence, group: expected.group, op: expected.op
    ))
    // A different sequence is a stale reply from an earlier attempt.
    #expect(!JabraGNP.isReply(
        reply, sequence: 0x13, group: expected.group, op: expected.op
    ))
    // Wrong opcode.
    #expect(!JabraGNP.isReply(
        reply, sequence: expected.sequence, group: expected.group, op: 0x32
    ))

    // The connection-state notification uses the same class and opcode space
    // but is an event, not an answer to our query.
    let event = JabraGNP.Message(
        destination: JabraGNP.hostAddress,
        source: JabraGNP.dongleAddress,
        sequence: 0x12,
        kind: JabraGNP.eventKind,
        group: JabraGNP.pairingGroup,
        op: JabraGNP.recordOp,
        arguments: connectedRecord
    )
    #expect(!JabraGNP.isReply(
        event, sequence: expected.sequence, group: expected.group, op: expected.op
    ))
}

@Test
func connectionAnnouncementsAreRecognisedButNeverTreatedAsAnswers() throws {
    // Captured from a Link 380 about 100ms after an Evolve2 85 was powered
    // off, while a walk for sequence 0x0d was outstanding.
    let announcement: [UInt8] = [
        0x00, 0x01, 0xae, 0x11, 0x0d, 0x26,
        0x01, 0x70, 0xbf, 0x92, 0xf4, 0x2f, 0xb8, 0x01, 0x00, 0x04, 0xff,
    ]
    let message = try #require(JabraGNP.decode(announcement))
    #expect(message.kind == JabraGNP.eventKind)
    #expect(JabraGNP.isConnectionEvent(message))
    // It must not be mistaken for a record, whatever we are waiting for.
    #expect(!JabraGNP.isReply(
        message,
        sequence: 0xae,
        group: JabraGNP.pairingGroup,
        op: JabraGNP.recordOp
    ))

    // A record reply is not an announcement, so a walk cannot retrigger itself.
    let reply = try #require(JabraGNP.decode(connectedReplyBody))
    #expect(!JabraGNP.isConnectionEvent(reply))
}

@Test
func reassemblerJoinsFragmentedRepliesAndDropsGarbage() {
    var reassembler = JabraGNP.Reassembler()
    let body = connectedReplyBody
    // Split across two physical frames.
    #expect(reassembler.feed(Array(body[0..<5])) == nil)
    #expect(reassembler.feed(Array(body[5...])) == body)

    // A single frame carrying padding yields only the declared bytes.
    var padded = body
    padded += [UInt8](repeating: 0, count: 63 - padded.count)
    #expect(reassembler.feed(padded) == body)

    // An implausible declared length is discarded rather than buffered.
    #expect(reassembler.feed([0x00, 0x01, 0x12, 0xc0]) == nil)
    #expect(reassembler.feed(padded) == body)
}

@Test
func walkProvesConnectedFromTheFirstConnectedRecord() {
    var walk = JabraGNP.PairingWalk()
    #expect(walk.start() == .query(cursor: [0x00, 0x00], bluetoothType: 0x00))
    #expect(walk.accept(record: connectedRecord) == .finished(.connected))
}

@Test
func walkProvesDisconnectedOnlyAfterEveryDatabaseTerminates() {
    var walk = JabraGNP.PairingWalk()
    #expect(walk.start() == .query(cursor: [0x00, 0x00], bluetoothType: 0x00))
    // Cursor advances using the bytes the dongle returned, opaquely.
    #expect(walk.accept(record: disconnectedRecord)
        == .query(cursor: [0x00, 0x02], bluetoothType: 0x00))
    // Terminating the first database moves to the second, not to a verdict.
    #expect(walk.accept(record: lastRecord)
        == .query(cursor: [0x00, 0x00], bluetoothType: 0x01))
    #expect(walk.accept(record: lastRecord) == .finished(.disconnected))
}

@Test
func walkStaysInconclusiveOnPartialEvidence() {
    // A timeout mid-walk must never be read as "headset off".
    var timedOut = JabraGNP.PairingWalk()
    _ = timedOut.start()
    #expect(timedOut.fail() == .finished(.inconclusive))

    // A truncated record is not evidence either.
    var malformed = JabraGNP.PairingWalk()
    _ = malformed.start()
    #expect(malformed.accept(record: [0x00, 0x01, 0x01])
        == .finished(.inconclusive))

    // A repeated cursor ends that database rather than looping forever.
    var cyclic = JabraGNP.PairingWalk()
    _ = cyclic.start()
    let selfReferential: [UInt8] = [0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    #expect(cyclic.accept(record: selfReferential)
        == .query(cursor: [0x00, 0x00], bluetoothType: 0x01))

    // Exhausting the record cap is suspicious, so it proves nothing.
    var runaway = JabraGNP.PairingWalk(bluetoothTypes: [0x00], cap: 2)
    _ = runaway.start()
    #expect(runaway.accept(record: disconnectedRecord)
        == .query(cursor: [0x00, 0x02], bluetoothType: 0x00))
    #expect(runaway.accept(record: [
        0x00, 0x03, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]) == .finished(.inconclusive))
}

@Test
func completeVendorEvidenceOverridesTheUntrustworthyLegacyBit() {
    // This is the reported bug: after a replug the legacy bit claims linked
    // while no headset is connected. Vendor evidence must win.
    #expect(JabraGNP.resolve(vendor: .disconnected, legacy: true) == false)
    #expect(JabraGNP.resolve(vendor: .connected, legacy: false) == true)
    // Without usable vendor evidence the legacy bit is the fallback.
    #expect(JabraGNP.resolve(vendor: .inconclusive, legacy: true) == true)
    #expect(JabraGNP.resolve(vendor: nil, legacy: false) == false)
    #expect(JabraGNP.resolve(vendor: .inconclusive, legacy: nil) == nil)
    #expect(JabraGNP.resolve(vendor: nil, legacy: nil) == nil)
}

@Test
func headsetBatteryIsReadFromItsReplyOrUnaskedUpdate() throws {
    // The Evolve2 85's reply to a battery query, captured at 95%: flags 24,
    // level 5f.
    let reply = try #require(JabraGNP.decode(
        [0x00, 0x04, 0x7a, 0xca, 0x12, 0x02, 0x24, 0x5f, 0x10, 0x23]
    ))
    #expect(JabraGNP.batteryLevel(reply) == 95)

    // The same message sent unasked carries an event kind.
    let update = try #require(JabraGNP.decode(
        [0x00, 0x04, 0x00, 0x0a, 0x12, 0x02, 0x24, 0x40, 0x10, 0x23]
    ))
    #expect(JabraGNP.batteryLevel(update) == 64)

    // From the dongle rather than the headset, or out of range.
    let fromDongle = try #require(JabraGNP.decode(
        [0x00, 0x01, 0x7a, 0xca, 0x12, 0x02, 0x24, 0x5f, 0x10, 0x23]
    ))
    #expect(JabraGNP.batteryLevel(fromDongle) == nil)
    let invalid = try #require(JabraGNP.decode(
        [0x00, 0x04, 0x7a, 0xca, 0x12, 0x02, 0x24, 0xe6, 0x10, 0x23]
    ))
    #expect(JabraGNP.batteryLevel(invalid) == nil)
}

@Test
func headsetSettingsAreReadFromItsReplies() throws {
    // Evolve2 85 replies captured in HearThrough, with sidetone off and then
    // on at level 06 as Jabra Direct showed it.
    let mode = try #require(JabraGNP.decode([0x00, 0x04, 0xb2, 0xc7, 0x13, 0x87, 0x03]))
    #expect(JabraGNP.headsetSetting(mode) == .noiseMode(.hearThrough))
    let off = try #require(JabraGNP.decode([0x00, 0x04, 0xb3, 0xc8, 0x13, 0x7c, 0x01, 0x06]))
    #expect(JabraGNP.headsetSetting(off) == .sidetone(.init(isOn: false, level: 0x06)))
    let on = try #require(JabraGNP.decode([0x00, 0x04, 0xb3, 0xc8, 0x13, 0x7c, 0x00, 0x06]))
    #expect(JabraGNP.headsetSetting(on) == .sidetone(.init(isOn: true, level: 0x06)))

    // HearThrough without what is playing, written from the Mac and kept,
    // still shows as HearThrough.
    let plain = try #require(JabraGNP.decode([0x00, 0x04, 0x34, 0xc7, 0x13, 0x87, 0x02]))
    #expect(JabraGNP.headsetSetting(plain) == .noiseMode(.hearThrough))
    // A headset that announces the new value itself, rather than naming
    // the op that changed.
    let announced = try #require(JabraGNP.decode([0x00, 0x04, 0x31, 0x07, 0x13, 0x87, 0x01]))
    #expect(JabraGNP.headsetSetting(announced) == .noiseMode(.cancelling))

    // A mode value never seen, a reply from the dongle, or a query is no value.
    let unknown = try #require(JabraGNP.decode([0x00, 0x04, 0xb2, 0xc7, 0x13, 0x87, 0x05]))
    #expect(JabraGNP.headsetSetting(unknown) == nil)
    let fromDongle = try #require(JabraGNP.decode([0x00, 0x01, 0xb2, 0xc7, 0x13, 0x87, 0x01]))
    #expect(JabraGNP.headsetSetting(fromDongle) == nil)
    let query = try #require(JabraGNP.decode([0x04, 0x00, 0xb2, 0x46, 0x13, 0x87]))
    #expect(JabraGNP.headsetSetting(query) == nil)
}

@Test
func switchingSidetoneKeepsItsLevelAndWritesTheInvertedSwitch() throws {
    var sidetone = JabraGNP.Sidetone(isOn: false, level: 0x03)
    sidetone.isOn = true
    // The write that turned noise cancellation on from the Mac.
    let mode = try #require(JabraGNP.encodeQuery(
        destination: JabraGNP.headsetAddress,
        sequence: 0xa5,
        kind: JabraGNP.writeKind,
        group: JabraGNP.settingsGroup,
        op: JabraGNP.noiseModeOp,
        arguments: [JabraGNP.NoiseMode.cancelling.rawValue],
        frameLength: 63
    ))
    #expect(Array(mode.prefix(7)) == [0x04, 0x00, 0xa5, 0x87, 0x13, 0x87, 0x01])
    let write = try #require(JabraGNP.encodeQuery(
        destination: JabraGNP.headsetAddress,
        sequence: 0xa6,
        kind: JabraGNP.writeKind,
        group: JabraGNP.settingsGroup,
        op: JabraGNP.sidetoneOp,
        arguments: sidetone.arguments,
        frameLength: 63
    ))
    #expect(Array(write.prefix(8)) == [0x04, 0x00, 0xa6, 0x88, 0x13, 0x7c, 0x00, 0x03])
}

@Test
func busyStateAndEventMaskAreReadFromReplies() throws {
    // Evolve2 85 behind a Link 380, busy because the dongle's off-hook was
    // set (the busylight button gives the same reply), and its event mask.
    let busy = try #require(JabraGNP.decode([0x00, 0x04, 0xa6, 0xc7, 0x12, 0x08, 0x01]))
    #expect(JabraGNP.headsetSetting(busy) == .busy(true))
    let mask = try #require(JabraGNP.decode(
        [0x00, 0x04, 0xa3, 0xca, 0x0d, 0x4c, 0x00, 0x00, 0x01, 0x7f]
    ))
    #expect(JabraGNP.headsetSetting(mask) == .eventMask([0x00, 0x00, 0x01, 0x7f]))
    // An event on the same op is a subscribed one, never the mask.
    let event = try #require(JabraGNP.decode(
        [0x00, 0x04, 0xa3, 0x0a, 0x0d, 0x4c, 0x04, 0x87, 0x7c, 0x56]
    ))
    #expect(JabraGNP.headsetSetting(event) == nil)
    // Subscribing keeps every bit and adds setting changes.
    #expect(JabraGNP.subscribedMask([0x00, 0x00, 0x01, 0x7f]) == [0x00, 0x00, 0x01, 0x7f])
    #expect(JabraGNP.subscribedMask([0x00, 0x00, 0x00, 0x00]) == [0x00, 0x00, 0x00, 0x10])
}

@Test
func subscribedEventsNameChangedSettingsAndBusyState() throws {
    // Sent after a press of the sound modes button, and at a call's start.
    let mode = try #require(JabraGNP.decode([0x00, 0x04, 0x99, 0x08, 0x0d, 0x4c, 0x04, 0x87]))
    #expect(JabraGNP.headsetEvent(mode) == .settingsChanged([0x87]))
    let busy = try #require(JabraGNP.decode(
        [0x00, 0x04, 0xa5, 0x09, 0x0d, 0x4c, 0x08, 0x08, 0x01]
    ))
    #expect(JabraGNP.headsetEvent(busy) == .busy(true))
    // A reply rather than an event is not ours.
    let reply = try #require(JabraGNP.decode([0x00, 0x04, 0x99, 0xc8, 0x0d, 0x4c, 0x04, 0x87]))
    #expect(JabraGNP.headsetEvent(reply) == nil)
}

@Test
func aCallPlaysSidetoneInsteadOfHearThroughAndCancellation() {
    let sidetoneOn = JabraGNP.Sidetone(isOn: true, level: 6)
    let sidetoneOff = JabraGNP.Sidetone(isOn: false, level: 6)
    var controls = JabraGNP.HeadsetControls(
        noiseMode: .hearThrough,
        sidetone: sidetoneOff,
        isInCall: false
    )
    #expect(controls.audibleNoiseMode == .hearThrough)
    #expect(controls.isAvailable(.hearThrough))

    // HearThrough pauses, and the headset will put it back after the call.
    controls.setInCall(true)
    #expect(controls.audibleNoiseMode == .off)
    #expect(controls.modeBeforeCall == .hearThrough)
    #expect(!controls.isAvailable(.hearThrough))
    #expect(controls.isAvailable(.cancelling))

    controls.noiseMode = .cancelling
    #expect(controls.audibleNoiseMode == .cancelling)

    // Sidetone turns cancellation off, and the raised boom silences sidetone.
    controls.sidetone = sidetoneOn
    #expect(controls.audibleNoiseMode == .off)
    #expect(!controls.isAvailable(.cancelling))
    #expect(!controls.isSidetoneSilenced)
    controls.isBoomUp = true
    #expect(controls.isSidetoneSilenced)

    controls.setInCall(false)
    #expect(controls.modeBeforeCall == nil)
    #expect(!controls.isSidetoneSilenced)
}

@Test
func answeredMuteOutranksTheBoom() {
    var controls = JabraGNP.HeadsetControls(isInCall: true, isBoomUp: false)
    #expect(!controls.isMicMuted)
    // The headset's report follows its button even with the boom down.
    controls.answeredMute = true
    #expect(controls.isMicMuted)
    // And it still wins once the boom is raised, if it says unmuted.
    controls.isBoomUp = true
    controls.answeredMute = false
    #expect(!controls.isMicMuted)
    controls.setInCall(false)
    controls.answeredMute = true
    #expect(!controls.isMicMuted)
    // The busylight alone, marking the user busy, still shows the mute.
    controls.isBusy = true
    #expect(controls.isMicMuted)
}

@Test
func theHeadsetReportsItsMicrophoneMuteWhoeverAsked() throws {
    // In a call run through Jabra Direct's Zoom plugin: Zoom's Mute, then
    // Unmute; the headset's button sends the same two.
    let muted = try #require(JabraGNP.decode([0x00, 0x04, 0xab, 0x08, 0x23, 0x01, 0x00, 0x01]))
    #expect(JabraGNP.headsetEvent(muted) == .micMuted(true))
    let unmuted = try #require(JabraGNP.decode([0x00, 0x04, 0xe3, 0x08, 0x23, 0x01, 0x00, 0x00]))
    #expect(JabraGNP.headsetEvent(unmuted) == .micMuted(false))
    // Speech detection shares the op and is not a mute.
    let speech = try #require(JabraGNP.decode([0x00, 0x04, 0x8d, 0x08, 0x23, 0x01, 0x08, 0x01]))
    #expect(JabraGNP.headsetEvent(speech) == nil)
    // The telemetry switch, read while Jabra Direct had it on.
    let telemetry = try #require(JabraGNP.decode([0x00, 0x04, 0xa2, 0xc7, 0x23, 0x00, 0x01]))
    #expect(JabraGNP.headsetSetting(telemetry) == .telemetryOn(true))
}

@Test
func anOpenMicrophoneLinePlaysCallAudioWithoutACall() {
    // As with Voice Memos recording or the call button pressed with no call
    // app: HearThrough faded and the mute button answered.
    var controls = JabraGNP.HeadsetControls(
        noiseMode: .hearThrough,
        sidetone: .init(isOn: false, level: 6),
        isInCall: false
    )
    controls.answeredMute = true
    #expect(!controls.isMicMuted)
    controls.isLineOpen = true
    #expect(controls.audibleNoiseMode == .off)
    #expect(!controls.isAvailable(.hearThrough))
    #expect(controls.isAvailable(.cancelling))
    #expect(controls.isMicMuted)
    // No call began, so there is no mode for the headset to put back.
    #expect(controls.modeBeforeCall == nil)
    controls.isLineOpen = false
    #expect(controls.audibleNoiseMode == .hearThrough)
    #expect(!controls.isMicMuted)
}

@Test
func aCallFirstSeenMidwayHasNoModeToRestore() {
    var controls = JabraGNP.HeadsetControls(noiseMode: .cancelling)
    controls.setInCall(true)
    #expect(controls.modeBeforeCall == nil)
}

@Test
func boomEventsTellUpFromDown() throws {
    // Captured while the boom was raised and lowered during a call.
    let up = try #require(JabraGNP.decode([0x00, 0x04, 0x1e, 0x08, 0x0d, 0x4c, 0x06, 0x02]))
    #expect(JabraGNP.headsetEvent(up) == .boomUp(true))
    let down = try #require(JabraGNP.decode([0x00, 0x04, 0x16, 0x08, 0x0d, 0x4c, 0x06, 0x01]))
    #expect(JabraGNP.headsetEvent(down) == .boomUp(false))
    // Raised only to the mute position, short of parked, which still muted.
    let muting = try #require(JabraGNP.decode([0x00, 0x04, 0x13, 0x08, 0x0d, 0x4c, 0x06, 0x00]))
    #expect(JabraGNP.headsetEvent(muting) == .boomUp(true))
}

@Test
func aHeadsetWithNoiseControlAtTheAmbienceOpIsReadAndWrittenThere() throws {
    // Not captured: built from the layout for headsets that keep noise
    // control at 0xbe, which no headset at hand does.
    #expect(JabraGNP.readArguments(for: JabraGNP.ambienceModeOp) == [0x01])
    #expect(JabraGNP.readArguments(for: JabraGNP.noiseModeOp).isEmpty)
    let reply = try #require(JabraGNP.decode([0x00, 0x04, 0x31, 0xc7, 0x13, 0xbe, 0x04]))
    #expect(JabraGNP.headsetSetting(reply) == .ambienceMode(.cancelling))
    let write = try #require(JabraGNP.encodeQuery(
        destination: JabraGNP.headsetAddress,
        sequence: 0x32,
        kind: JabraGNP.writeKind,
        group: JabraGNP.settingsGroup,
        op: JabraGNP.ambienceModeOp,
        arguments: JabraGNP.ambienceArguments(.hearThrough),
        frameLength: 63
    ))
    #expect(Array(write.prefix(8)) == [0x04, 0x00, 0x32, 0x88, 0x13, 0xbe, 0x01, 0x02])
    let changed = try #require(JabraGNP.decode([0x00, 0x04, 0x33, 0x09, 0x0d, 0x4c, 0x09, 0x01, 0x01]))
    #expect(JabraGNP.headsetEvent(changed) == .ambienceMode(.off))
    // Calibration is no mode of ours.
    let calibrating = try #require(JabraGNP.decode([0x00, 0x04, 0x34, 0xc7, 0x13, 0xbe, 0x80]))
    #expect(JabraGNP.headsetSetting(calibrating) == nil)
    // Only such a headset gets the extra subscription bit; the Evolve2 85
    // refuses the whole mask with it.
    #expect(JabraGNP.subscribedMask([0x00, 0x00, 0x01, 0x7f], ambience: true) == [0x00, 0x00, 0x03, 0x7f])
    #expect(JabraGNP.subscribedMask([0x00, 0x00, 0x01, 0x7f]) == [0x00, 0x00, 0x01, 0x7f])
}

@Test
func onEarDetectionDarkensTheBusylightOnlyOffTheHead() throws {
    // Captured with on-ear detection switched on, and while the headset was
    // taken off, left earcup first, and put back on.
    let detection = try #require(JabraGNP.decode([0x00, 0x04, 0xa1, 0xc7, 0x13, 0x92, 0x01]))
    #expect(JabraGNP.headsetSetting(detection) == .headDetection(true))
    let leftOff = try #require(JabraGNP.decode([0x00, 0x04, 0x45, 0x08, 0x0d, 0x4c, 0x02, 0x01]))
    #expect(JabraGNP.headsetEvent(leftOff) == .earcup(isLeft: true, isOn: false))
    let rightOff = try #require(JabraGNP.decode([0x00, 0x04, 0x46, 0x08, 0x0d, 0x4c, 0x02, 0x03]))
    #expect(JabraGNP.headsetEvent(rightOff) == .earcup(isLeft: false, isOn: false))
    let leftOn = try #require(JabraGNP.decode([0x00, 0x04, 0x47, 0x08, 0x0d, 0x4c, 0x02, 0x00]))
    #expect(JabraGNP.headsetEvent(leftOn) == .earcup(isLeft: true, isOn: true))
    let rightOn = try #require(JabraGNP.decode([0x00, 0x04, 0x4a, 0x08, 0x0d, 0x4c, 0x02, 0x02]))
    #expect(JabraGNP.headsetEvent(rightOn) == .earcup(isLeft: false, isOn: true))

    var controls = JabraGNP.HeadsetControls()
    controls.isBusy = true
    controls.isLeftCupOn = false
    controls.isRightCupOn = false
    // Without detection the light shows wherever the headset lies.
    controls.detectsHead = false
    #expect(!controls.isBusylightDark)
    controls.detectsHead = true
    #expect(controls.isBusylightDark)
    controls.isRightCupOn = true
    #expect(!controls.isBusylightDark)
}

@Test
func theBusylightIsWrittenAsTheWearersChoice() throws {
    // The write that lit it from the Mac after the headset's button had
    // been used, and the value the headset sent unasked.
    let on = try #require(JabraGNP.encodeQuery(
        destination: JabraGNP.headsetAddress,
        sequence: 0xa1,
        kind: JabraGNP.writeKind,
        group: JabraGNP.statusGroup,
        op: JabraGNP.busyOp,
        arguments: JabraGNP.busyArguments(true),
        frameLength: 63
    ))
    #expect(Array(on.prefix(8)) == [0x04, 0x00, 0xa1, 0x88, 0x12, 0x08, 0x01, 0x00])
    let lit = try #require(JabraGNP.decode([0x00, 0x04, 0x28, 0x07, 0x12, 0x08, 0x01]))
    #expect(JabraGNP.headsetSetting(lit) == .busy(true))
    #expect(JabraGNP.busyArguments(false) == [0x00, 0x00])
}

@Test
func audioDeviceSerialBindsStateToOnePhysicalDongle() {
    #expect(JabraLink.serial(
        fromAudioUID: "AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:50C275445423:1"
    ) == "50C275445423")
    #expect(JabraLink.serial(
        fromAudioUID: "AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:50C275445423:2"
    ) == "50C275445423")
    #expect(JabraLink.serial(fromAudioUID: "BuiltInSpeakerDevice") == nil)
    #expect(JabraLink.serial(fromAudioUID: "AppleUSBAudioEngine:a:b:c") == nil)
    #expect(JabraLink.serialsMatch("50c275445423", "50C275445423"))
    #expect(!JabraLink.serialsMatch("50C275445423", "70BF92F42FB8"))
}
