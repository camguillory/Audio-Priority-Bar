import Foundation

public struct JabraProfile: Equatable, Sendable {
    public enum ID: Sendable {
        case link380
        case link390
    }

    public enum Signal: Equatable, Sendable {
        case element(
            page: Int,
            usage: Int,
            linkedValue: Int
        )
        case report(
            id: Int,
            byteIndex: Int,
            bitMask: UInt8
        )
    }

    public let id: ID
    public let product: String
    public let signal: Signal
}

public enum JabraLink {
    public static let vendorID = 0x0b0e
    public static let profiles = [
        JabraProfile(
            id: .link380,
            product: "Jabra Link 380",
            signal: .element(
                page: 0xff30,
                usage: 0xfffc,
                linkedValue: 0
            )
        ),
        JabraProfile(
            id: .link390,
            product: "Jabra Link 390",
            // Report 0x04 byte 1 bit 3 comes from hardware research in
            // tobi/AudioPriorityBar#32. Local Link 390 verification is still
            // pending; unreadable monitoring must remain fail-open.
            signal: .report(id: 0x04, byteIndex: 1, bitMask: 0x08)
        ),
    ]

    public static func profile(matching name: String) -> JabraProfile? {
        profiles.first {
            name.range(of: $0.product, options: .caseInsensitive) != nil
        }
    }

    public static func decodeElement(
        value: Int,
        linkedValue: Int
    ) -> Bool {
        value == linkedValue
    }

    public static func snapshot(
        value: Int,
        timestamp: UInt64,
        linkedValue: Int
    ) -> Bool? {
        guard timestamp != 0 else { return nil }
        return decodeElement(value: value, linkedValue: linkedValue)
    }

    public static func decodeReport(
        reportID: Int,
        expectedID: Int,
        bytes: [UInt8],
        byteIndex: Int,
        bitMask: UInt8
    ) -> Bool? {
        guard reportID == expectedID, bytes.indices.contains(byteIndex) else {
            return nil
        }
        return bytes[byteIndex] & bitMask != 0
    }

    public static func aggregate(_ states: [Bool?]) -> LinkState {
        if states.contains(where: { $0 == true }) { return .up }
        if states.allSatisfy({ $0 == nil }) { return .monitoringUnavailable }
        if states.contains(where: { $0 == nil }) { return .unknown }
        return .down
    }

    public static func allowsSelection(
        isSupported: Bool,
        state: LinkState
    ) -> Bool {
        !isSupported || state != .down
    }
}

public struct DebouncedLinkState: Equatable, Sendable {
    public enum Transition: Equatable, Sendable {
        case unchanged
        case changed
        case scheduleDown
        case cancelDown
    }

    public private(set) var observed: Bool?
    public private(set) var effective: Bool?

    public init(observed: Bool? = nil, effective: Bool? = nil) {
        self.observed = observed
        self.effective = effective
    }

    public mutating func seed(_ linked: Bool) -> Bool {
        observed = linked
        guard effective != linked else { return false }
        effective = linked
        return true
    }

    public mutating func observe(_ linked: Bool) -> Transition {
        guard observed != linked else { return .unchanged }
        let cancellingDown = observed == false
        observed = linked

        if linked {
            if effective != true {
                effective = true
                return .changed
            }
            return cancellingDown ? .cancelDown : .unchanged
        }
        return effective == false ? .unchanged : .scheduleDown
    }

    public mutating func commitDown() -> Bool {
        guard observed == false, effective != false else { return false }
        effective = false
        return true
    }
}
