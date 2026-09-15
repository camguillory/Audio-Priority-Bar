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

    /// Builds the body of one query, zero padded to a single frame.
    ///
    /// Returns nil when the arguments would not fit. Every command this app
    /// sends is a few bytes, so overflow is a programming error rather than a
    /// reason to fragment writes. Replies are reassembled generically because
    /// their length is not under our control.
    public static func encodeQuery(
        destination: UInt8 = dongleAddress,
        sequence: UInt8,
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
            queryKind | UInt8(declared),
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
