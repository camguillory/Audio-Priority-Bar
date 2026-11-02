import Foundation

/// Jabra GNP vendor messaging, used to read a dongle's real Bluetooth
/// connection state.
///
/// The telephony "link" bit in `JabraLink` cannot be trusted on its own: the
/// dongle asserts a false "connected" roughly 1.8s after USB enumeration,
/// identically whether a headset is on or off, and never corrects it. Asking
/// the dongle over GNP is the only way to learn the truth, so `JabraLink`
/// survives only as a fallback for devices that do not answer.
///
/// The framing and pairing-record query are based on jabridge (Apache-2.0,
/// https://github.com/Watchdog0x/jabridge), verified locally against a Jabra
/// Link 380 (PID 0x24ca) paired with an Evolve2 85.
public enum JabraGNP {

    // MARK: - Management collection

    /// Vendor usage page carrying the management byte stream.
    public static let usagePage = 0xff00
    public static let usage = 0x01

    /// Canonical GNP report number. The physical HID report ID is discovered
    /// from the descriptor and is not guaranteed to equal this value, so
    /// nothing here may hard-code it.
    public static let canonicalReportID: UInt8 = 0x05

    /// Largest physical report length, including the report ID byte.
    public static let maximumFrameLength = 65

    // MARK: - Framing

    public static let hostAddress: UInt8 = 0x00
    public static let dongleAddress: UInt8 = 0x01

    public static let kindMask: UInt8 = 0xc0
    public static let lengthMask: UInt8 = 0x3f
    public static let queryKind: UInt8 = 0x40
    /// Changes a setting. The headset acknowledges it separately, and a query
    /// sent right after already reads the new value.
    public static let writeKind: UInt8 = 0x80
    public static let replyKind: UInt8 = 0xc0
    /// Unsolicited notifications carry a zero kind and are never replies.
    public static let eventKind: UInt8 = 0x00

    /// Canonical header bytes preceding the arguments.
    public static let headerLength = 6

    // MARK: - Pairing database

    public static let pairingGroup: UInt8 = 0x0d
    /// Reads one remembered-device record. Its reply carries both the
    /// connection state and the cursor for the next record, so the companion
    /// name opcode 0x32 is not needed for link detection.
    public static let recordOp: UInt8 = 0x28

    /// The dongle announces a remembered device connecting or disconnecting
    /// without being asked, about 100ms after it happens. Used only as a
    /// trigger to re-read the pairing database, so nothing depends on the
    /// layout of its payload.
    public static let connectionEventOp: UInt8 = 0x26

    /// Record state byte meaning "this remembered device is connected".
    public static let connectedState: UInt8 = 0x03
    public static let cursorLength = 2
    /// Cursor value that terminates a database walk.
    public static let endCursor: [UInt8] = [0xff, 0xff]
    /// Both database types must terminate before "nothing connected" is
    /// proven, because a device may populate only one of them.
    public static let bluetoothTypes: [UInt8] = [0x00, 0x01]
    /// Upper bound on records per database, guarding against a runaway walk.
    public static let recordCap = 256
    /// A record reply must be long enough to carry cursor, state and address.
    public static let recordMinimumLength = 12
    public static let recordStateIndex = 2

    /// Arguments for a record query. The cursor is treated as opaque bytes:
    /// the dongle's byte order for this field disagrees with jabridge's
    /// little-endian encode and decode, which cancel out only because they are
    /// applied symmetrically. Echoing the received bytes avoids the question.
    public static func recordArguments(
        cursor: [UInt8],
        bluetoothType: UInt8
    ) -> [UInt8] {
        cursor + [bluetoothType]
    }

    // MARK: - Descriptor-driven layout

    /// One candidate management element, as read from a HID descriptor.
    public struct Element: Equatable, Sendable {
        public enum Direction: Equatable, Sendable {
            case input
            case output
        }

        public let direction: Direction
        public let reportID: UInt8
        /// Total width of the element in bits.
        public let bits: Int

        public init(direction: Direction, reportID: UInt8, bits: Int) {
            self.direction = direction
            self.reportID = reportID
            self.bits = bits
        }
    }

    /// Physical transport parameters for one device's management collection.
    public struct Layout: Equatable, Sendable {
        public let inputReportID: UInt8
        public let outputReportID: UInt8
        /// Body bytes per frame, excluding the report ID.
        public let inputFrameLength: Int
        public let outputFrameLength: Int

        public init(
            inputReportID: UInt8,
            outputReportID: UInt8,
            inputFrameLength: Int,
            outputFrameLength: Int
        ) {
            self.inputReportID = inputReportID
            self.outputReportID = outputReportID
            self.inputFrameLength = inputFrameLength
            self.outputFrameLength = outputFrameLength
        }
    }

    /// Chooses the management layout from the device's FF00:0001 elements.
    /// Returns nil when no usable pair exists, or when either direction is
    /// ambiguous, so an unrecognised device falls back instead of guessing.
    public static func selectLayout(_ elements: [Element]) -> Layout? {
        var input: (id: UInt8, length: Int)?
        var output: (id: UInt8, length: Int)?
        for element in elements {
            guard element.reportID != 0,
                  element.bits > 0,
                  element.bits.isMultiple(of: 8) else { continue }
            let length = element.bits / 8
            guard length >= headerLength,
                  length + 1 <= maximumFrameLength else { continue }
            let candidate = (id: element.reportID, length: length)
            switch element.direction {
            case .input:
                if let input, input != candidate { return nil }
                input = candidate
            case .output:
                if let output, output != candidate { return nil }
                output = candidate
            }
        }
        guard let input, let output else { return nil }
        return Layout(
            inputReportID: input.id,
            outputReportID: output.id,
            inputFrameLength: input.length,
            outputFrameLength: output.length
        )
    }

    // MARK: - Encoding

    /// Builds the body of one query or write, zero padded to a single frame.
    ///
    /// Returns nil when the arguments would not fit. Every command this app
    /// sends is a few bytes, so overflow is a programming error rather than a
    /// reason to fragment writes. Replies are reassembled generically because
    /// their length is not under our control.
    public static func encodeQuery(
        destination: UInt8 = dongleAddress,
        sequence: UInt8,
        kind: UInt8 = queryKind,
        group: UInt8,
        op: UInt8,
        arguments: [UInt8],
        frameLength: Int
    ) -> [UInt8]? {
        let declared = headerLength + arguments.count
        guard declared <= Int(lengthMask), declared <= frameLength else {
            return nil
        }
        var body: [UInt8] = [
            destination,
            hostAddress,
            sequence,
            kind | UInt8(declared),
            group,
            op,
        ]
        body += arguments
        body += [UInt8](repeating: 0, count: frameLength - body.count)
        return body
    }

    // MARK: - Decoding

    public struct Message: Equatable, Sendable {
        public let destination: UInt8
        public let source: UInt8
        public let sequence: UInt8
        public let kind: UInt8
        public let group: UInt8
        public let op: UInt8
        public let arguments: [UInt8]

        public init(
            destination: UInt8,
            source: UInt8,
            sequence: UInt8,
            kind: UInt8,
            group: UInt8,
            op: UInt8,
            arguments: [UInt8]
        ) {
            self.destination = destination
            self.source = source
            self.sequence = sequence
            self.kind = kind
            self.group = group
            self.op = op
            self.arguments = arguments
        }
    }

    /// Decodes a canonical body, meaning a frame with the report ID removed.
    public static func decode(_ body: [UInt8]) -> Message? {
        guard body.count >= headerLength else { return nil }
        let declared = Int(body[3] & lengthMask)
        guard declared >= headerLength, declared <= body.count else {
            return nil
        }
        return Message(
            destination: body[0],
            source: body[1],
            sequence: body[2],
            kind: body[3] & kindMask,
            group: body[4],
            op: body[5],
            arguments: Array(body[headerLength..<declared])
        )
    }

    /// Whether `message` is the specific reply being awaited. Every field is
    /// checked so stale replies and unsolicited events cannot be mistaken for
    /// an answer.
    public static func isReply(
        _ message: Message,
        sequence: UInt8,
        group: UInt8,
        op: UInt8,
        source: UInt8 = dongleAddress
    ) -> Bool {
        message.destination == hostAddress
            && message.source == source
            && message.sequence == sequence
            && message.kind == replyKind
            && message.group == group
            && message.op == op
    }

    /// True for the dongle's unsolicited announcement that a remembered device
    /// connected or disconnected. It carries a state byte, which is
    /// deliberately ignored: the announcement only says something changed, and
    /// a pairing walk is what establishes what.
    public static func isConnectionEvent(_ message: Message) -> Bool {
        message.destination == hostAddress
            && message.source == dongleAddress
            && message.kind == eventKind
            && message.group == pairingGroup
            && message.op == connectionEventOp
    }

    /// Accumulates physical frames into canonical bodies.
    public struct Reassembler: Sendable {
        private var body: [UInt8] = []

        public init() {}

        /// Feeds one frame with the report ID already removed, returning a
        /// canonical body once it is complete.
        public mutating func feed(_ chunk: [UInt8]) -> [UInt8]? {
            body += chunk
            // The declared length lives in the fourth header byte.
            guard body.count > 3 else { return nil }
            let declared = Int(body[3] & lengthMask)
            guard declared >= headerLength else {
                body.removeAll()
                return nil
            }
            guard body.count >= declared else { return nil }
            let complete = Array(body[0..<declared])
            body.removeAll()
            return complete
        }

        public mutating func reset() {
            body.removeAll()
        }
    }

    // MARK: - Headset battery

    /// The headset behind a dongle, as a GNP address.
    public static let headsetAddress: UInt8 = 0x04
    public static let statusGroup: UInt8 = 0x12
    /// Answered with `[flags, percent, ...]`, and also sent unasked when the
    /// level changes, per jabridge.
    public static let batteryOp: UInt8 = 0x02

    /// The headset's battery percentage, from its answer to a battery query or
    /// from an update it sent unasked.
    public static func batteryLevel(_ message: Message) -> Int? {
        guard message.destination == hostAddress,
              message.source == headsetAddress,
              message.kind == replyKind || message.kind == eventKind,
              message.group == statusGroup,
              message.op == batteryOp,
              message.arguments.count >= 2,
              message.arguments[1] <= 100 else { return nil }
        return Int(message.arguments[1])
    }

    // MARK: - Headset settings

    /// Settings the headset keeps itself. Every client on the dongle receives
    /// every reply, so another app's reads keep these current too. Each op
    /// means the same on every headset that has the setting, and one that
    /// lacks it refuses the read, so answering is what makes it supported.
    public static let settingsGroup: UInt8 = 0x13
    public static let noiseModeOp: UInt8 = 0x87
    public static let sidetoneOp: UInt8 = 0x7c
    /// On-ear detection, 01 on. While on, the headset darkens its busylight
    /// whenever it is off the head, keeping the busy state as it was.
    public static let headDetectionOp: UInt8 = 0x92

    /// Noise control on headsets that keep it here rather than at 0x87:
    /// asked with `[01]`, answered with one byte, 01 off, 02 HearThrough and
    /// 04 noise cancellation, written as `[01, value]`, and announced as
    /// `[09, 01, value]` once bit 9 of the event mask is set. Not measured:
    /// no such headset was at hand, and an Evolve2 85 refuses both the op
    /// and the bit.
    public static let ambienceModeOp: UInt8 = 0xbe
    private static let ambienceSelector: UInt8 = 0x01
    public static let ambienceChangesBit: UInt8 = 9

    /// The arguments a read of `op` needs.
    public static func readArguments(for op: UInt8) -> [UInt8] {
        op == ambienceModeOp ? [ambienceSelector] : []
    }

    public static func ambienceArguments(_ mode: NoiseMode) -> [UInt8] {
        [ambienceSelector, mode.ambienceByte]
    }
    /// In the status group: 01 while the headset is busy, in a call or with
    /// its busylight turned on by hand, 00 otherwise.
    public static let busyOp: UInt8 = 0x08

    /// Lights or clears the busylight as the wearer's own choice, the one
    /// its button makes, so either undoes the other. A second byte of 01
    /// marks a presence status instead, which the headset ignores once the
    /// wearer has chosen.
    public static func busyArguments(_ isBusy: Bool) -> [UInt8] {
        [isBusy ? 0x01 : 0x00, 0x00]
    }

    /// Four bytes, big-endian, naming the kinds of event the headset sends.
    /// It sends none until a host writes the mask, even unchanged, and then
    /// starts with the current state of each kind.
    public static let eventMaskOp: UInt8 = 0x4c
    public static let settingChangesBit: UInt8 = 4
    private static let settingChangesEvent: UInt8 = 0x04
    private static let statusChangeEvent: UInt8 = 0x08
    private static let boomEvent: UInt8 = 0x06
    private static let earcupEvent: UInt8 = 0x02
    private static let ambienceEvent: UInt8 = 0x09

    /// Microphone telemetry. Op 0x00 switches it on; op 0x01 then reports
    /// `[00, muted]` whenever the microphone mutes or unmutes, whoever
    /// asked: the headset's button or boom, or a call app.
    public static let telemetryGroup: UInt8 = 0x23
    public static let telemetrySwitchOp: UInt8 = 0x00
    private static let telemetryEventOp: UInt8 = 0x01
    private static let micMuteTelemetry: UInt8 = 0x00

    /// Adds setting changes, and noise changes for a headset that keeps its
    /// noise control at `ambienceModeOp`. A headset without that op refuses
    /// the whole mask when its bit is set.
    public static func subscribedMask(_ mask: [UInt8], ambience: Bool = false) -> [UInt8] {
        var mask = mask
        mask[3] |= 1 << settingChangesBit
        if ambience { mask[2] |= 1 << (ambienceChangesBit - 8) }
        return mask
    }

    public enum NoiseMode: UInt8, CaseIterable, Sendable {
        case off = 0x00
        case cancelling = 0x01
        /// HearThrough mixed with what is playing, the kind the headset's
        /// own button picks.
        case hearThrough = 0x03

        /// 02 is HearThrough on its own, shown as HearThrough too.
        /// ponytail: choosing HearThrough writes 03; a headset with only
        /// the plain kind refuses it, and the read-back keeps its mode.
        public init?(byte: UInt8) {
            self.init(rawValue: byte == 0x02 ? 0x03 : byte)
        }

        /// The same modes as kept at `ambienceModeOp`.
        public init?(ambienceByte: UInt8) {
            switch ambienceByte {
            case 0x01: self = .off
            case 0x02: self = .hearThrough
            case 0x04: self = .cancelling
            default: return nil
            }
        }

        public var ambienceByte: UInt8 {
            switch self {
            case .off: 0x01
            case .hearThrough: 0x02
            case .cancelling: 0x04
            }
        }
    }

    public struct Sidetone: Equatable, Sendable {
        public var isOn: Bool
        /// Kept as read, so switching sidetone never changes its level.
        public let level: UInt8

        public init(isOn: Bool, level: UInt8) {
            self.isOn = isOn
            self.level = level
        }

        /// The switch byte is inverted: 00 is on and 01 is off.
        public var arguments: [UInt8] { [isOn ? 0x00 : 0x01, level] }
    }

    public struct HeadsetControls: Equatable, Sendable {
        public var noiseMode: NoiseMode?
        public var sidetone: Sidetone?
        /// From the telephony hook switch, which a call sets and the
        /// busylight button does not.
        public private(set) var isInCall: Bool?
        public var isBusy: Bool?
        /// The microphone line, open in a call and also whenever an app
        /// records or the headset's call button opens it without a call.
        public var isLineOpen: Bool?
        /// The call button opened the line with no app recording, a call of
        /// the headset's own until the button is pressed again.
        public var isHeadsetCall = false
        /// The headset puts this mode back the moment a call ends, dropping
        /// any change made during the call. Nil when the call began unseen.
        public private(set) var modeBeforeCall: NoiseMode?
        /// Raised, the boom mutes the microphone in a call, silencing sidetone.
        public var isBoomUp: Bool?
        /// The mute the headset reported itself, or failing that the one a
        /// call app confirmed on the dongle's Mute light. Nil leaves the
        /// boom to tell.
        public var answeredMute: Bool?
        public var detectsHead: Bool?
        /// From the sensor in each earcup, nil until the headset reports it.
        public var isLeftCupOn: Bool?
        public var isRightCupOn: Bool?

        public init(
            noiseMode: NoiseMode? = nil,
            sidetone: Sidetone? = nil,
            isInCall: Bool? = nil,
            isBoomUp: Bool? = nil
        ) {
            self.noiseMode = noiseMode
            self.sidetone = sidetone
            self.isInCall = isInCall
            self.isBoomUp = isBoomUp
        }

        public var hasControls: Bool { noiseMode != nil || sidetone != nil }

        public mutating func setInCall(_ inCall: Bool) {
            if inCall, isInCall == false { modeBeforeCall = noiseMode }
            if !inCall { modeBeforeCall = nil }
            isInCall = inCall
        }

        /// The headset plays audio as in a call while its microphone line is
        /// open, with or without one.
        public var playsCallAudio: Bool { isInCall == true || isLineOpen == true }

        /// A call from an app, or one the headset started itself.
        public var isCalling: Bool { isInCall == true || isHeadsetCall }

        /// The noise control heard now. Call audio pauses HearThrough, and
        /// sidetone turns noise cancellation off while it plays.
        public var audibleNoiseMode: NoiseMode? {
            guard let noiseMode else { return nil }
            guard playsCallAudio else { return noiseMode }
            return noiseMode == .hearThrough || sidetone?.isOn == true ? .off : noiseMode
        }

        /// Whether choosing `mode` changes what is heard now.
        public func isAvailable(_ mode: NoiseMode) -> Bool {
            guard playsCallAudio else { return true }
            switch mode {
            case .off: return true
            case .cancelling: return sidetone?.isOn != true
            case .hearThrough: return false
            }
        }

        /// Muted at the headset while its microphone line is open or its
        /// busylight marks the user busy, the times its mute means something.
        public var isMicMuted: Bool {
            guard playsCallAudio || isBusy == true else { return false }
            return answeredMute ?? (isBoomUp == true)
        }

        public var isSidetoneSilenced: Bool { sidetone?.isOn == true && isMicMuted }

        /// Busy, but dark because on-ear detection sees the headset off the
        /// head. Without detection the light shows wherever the headset is.
        public var isBusylightDark: Bool {
            isBusy == true && detectsHead == true
                && isLeftCupOn == false && isRightCupOn == false
        }
    }

    public enum HeadsetSetting: Equatable, Sendable {
        case noiseMode(NoiseMode)
        /// The noise mode, from a headset that keeps it at `ambienceModeOp`.
        case ambienceMode(NoiseMode)
        case sidetone(Sidetone)
        case busy(Bool)
        case inCall(Bool)
        case lineOpen(Bool)
        case boomUp(Bool)
        case headDetection(Bool)
        case earcup(isLeft: Bool, isOn: Bool)
        case telemetryOn(Bool)
        case eventMask([UInt8])
    }

    /// A value from the headset's answer to anyone's query, or one it sends
    /// unasked: some headsets announce a changed setting with its value.
    public static func headsetSetting(_ message: Message) -> HeadsetSetting? {
        let isReply = message.kind == replyKind
        guard message.destination == hostAddress,
              message.source == headsetAddress,
              isReply || message.kind == eventKind else { return nil }
        let arguments = message.arguments
        switch (message.group, message.op) {
        case (settingsGroup, noiseModeOp):
            guard arguments.count == 1,
                  let mode = NoiseMode(byte: arguments[0]) else { return nil }
            return .noiseMode(mode)
        case (settingsGroup, sidetoneOp):
            guard arguments.count == 2, arguments[0] <= 0x01 else { return nil }
            return .sidetone(Sidetone(isOn: arguments[0] == 0x00, level: arguments[1]))
        case (settingsGroup, headDetectionOp):
            guard arguments.count == 1, arguments[0] <= 0x01 else { return nil }
            return .headDetection(arguments[0] == 0x01)
        case (settingsGroup, ambienceModeOp):
            guard arguments.count == 1,
                  let mode = NoiseMode(ambienceByte: arguments[0]) else { return nil }
            return .ambienceMode(mode)
        case (statusGroup, busyOp):
            guard arguments.count == 1, arguments[0] <= 0x01 else { return nil }
            return .busy(arguments[0] == 0x01)
        case (pairingGroup, eventMaskOp):
            // Events on this op are the subscribed ones, never the mask.
            guard isReply, arguments.count == 4 else { return nil }
            return .eventMask(arguments)
        case (telemetryGroup, telemetrySwitchOp):
            guard arguments.count == 1, arguments[0] <= 0x01 else { return nil }
            return .telemetryOn(arguments[0] == 0x01)
        default:
            return nil
        }
    }

    public enum HeadsetEvent: Equatable, Sendable {
        /// The ops whose value changed, in the settings group.
        case settingsChanged([UInt8])
        case busy(Bool)
        case boomUp(Bool)
        case earcup(isLeft: Bool, isOn: Bool)
        case ambienceMode(NoiseMode)
        case micMuted(Bool)
    }

    /// An event the headset sends once subscribed: `[04, ops...]` when
    /// settings change, `[08, status op, value]` when a status changes,
    /// `[06, position]` for the boom: 00 raised to mute, 01 down, 02 parked
    /// all the way up, and `[02, earcup]` when an earcup goes on or off the
    /// head: 00 and 01 for the left one on and off, 02 and 03 for the right.
    public static func headsetEvent(_ message: Message) -> HeadsetEvent? {
        guard message.destination == hostAddress,
              message.source == headsetAddress,
              message.kind == eventKind,
              let kind = message.arguments.first else { return nil }
        let arguments = message.arguments
        if message.group == telemetryGroup, message.op == telemetryEventOp {
            // Other telemetry shares the op, speech detection among it.
            guard kind == micMuteTelemetry, arguments.count == 2,
                  arguments[1] <= 0x01 else { return nil }
            return .micMuted(arguments[1] == 0x01)
        }
        guard message.group == pairingGroup, message.op == eventMaskOp else { return nil }
        switch kind {
        case settingChangesEvent:
            return .settingsChanged(Array(arguments.dropFirst()))
        case statusChangeEvent:
            guard arguments.count == 3,
                  arguments[1] == busyOp,
                  arguments[2] <= 0x01 else { return nil }
            return .busy(arguments[2] == 0x01)
        case boomEvent:
            guard arguments.count == 2, arguments[1] <= 0x02 else { return nil }
            return .boomUp(arguments[1] != 0x01)
        case earcupEvent:
            guard arguments.count == 2, arguments[1] <= 0x03 else { return nil }
            return .earcup(isLeft: arguments[1] < 0x02, isOn: arguments[1].isMultiple(of: 2))
        case ambienceEvent:
            guard arguments.count == 3, arguments[1] == ambienceSelector,
                  let mode = NoiseMode(ambienceByte: arguments[2]) else { return nil }
            return .ambienceMode(mode)
        default:
            return nil
        }
    }

    // MARK: - Link evidence

    public enum Evidence: Equatable, Sendable {
        case connected
        case disconnected
        /// Evidence was incomplete, so neither state is proven.
        case inconclusive
    }

    /// Walks a dongle's remembered-device databases to decide whether anything
    /// is connected to it.
    ///
    /// `connected` may short-circuit on the first connected record, but
    /// `disconnected` requires every database to terminate cleanly. A timeout,
    /// malformed record, repeated cursor or cap exhaustion yields
    /// `inconclusive`, so automatic switching never acts on partial evidence.
    public struct PairingWalk: Sendable {
        public enum Step: Equatable, Sendable {
            case query(cursor: [UInt8], bluetoothType: UInt8)
            case finished(Evidence)
        }

        private let bluetoothTypes: [UInt8]
        private let cap: Int
        private var typeIndex = 0
        private var cursor: [UInt8]
        private var seen: Set<[UInt8]> = []
        private var visited = 0

        public init(
            bluetoothTypes: [UInt8] = JabraGNP.bluetoothTypes,
            cap: Int = JabraGNP.recordCap
        ) {
            self.bluetoothTypes = bluetoothTypes
            self.cap = cap
            cursor = [UInt8](repeating: 0, count: JabraGNP.cursorLength)
        }

        public mutating func start() -> Step {
            guard typeIndex < bluetoothTypes.count else {
                return .finished(.inconclusive)
            }
            return .query(cursor: cursor, bluetoothType: bluetoothTypes[typeIndex])
        }

        /// Accepts the arguments of one record reply.
        public mutating func accept(record arguments: [UInt8]) -> Step {
            guard typeIndex < bluetoothTypes.count,
                  arguments.count >= JabraGNP.recordMinimumLength else {
                return .finished(.inconclusive)
            }
            if arguments[JabraGNP.recordStateIndex] == JabraGNP.connectedState {
                return .finished(.connected)
            }
            visited += 1
            guard visited < cap else { return .finished(.inconclusive) }
            let next = Array(arguments[0..<JabraGNP.cursorLength])
            if next == JabraGNP.endCursor || next == cursor || seen.contains(next) {
                return advanceDatabase()
            }
            seen.insert(cursor)
            cursor = next
            return .query(cursor: cursor, bluetoothType: bluetoothTypes[typeIndex])
        }

        /// Records a missing, malformed or timed-out reply.
        public mutating func fail() -> Step {
            .finished(.inconclusive)
        }

        private mutating func advanceDatabase() -> Step {
            typeIndex += 1
            guard typeIndex < bluetoothTypes.count else {
                return .finished(.disconnected)
            }
            cursor = [UInt8](repeating: 0, count: JabraGNP.cursorLength)
            seen.removeAll()
            visited = 0
            return .query(cursor: cursor, bluetoothType: bluetoothTypes[typeIndex])
        }
    }

    /// Resolves the value a dongle should report. Complete GNP evidence wins;
    /// otherwise the legacy bit is the fallback. `nil` means unknown.
    public static func resolve(vendor: Evidence?, legacy: Bool?) -> Bool? {
        switch vendor {
        case .connected: true
        case .disconnected: false
        case .inconclusive, nil: legacy
        }
    }
}
