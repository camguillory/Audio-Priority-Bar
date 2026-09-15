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
