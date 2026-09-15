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

    /// Only a Link dongle can publish an audio device whose headset is absent.
    /// A Jabra headset or speakerphone plugged in directly is present whenever
    /// macOS lists it, yet it may expose the same management collection, so
    /// monitoring one would let an empty pairing list report it as off.
    public static func isDongleProduct(_ name: String) -> Bool {
        name.range(of: dongleFamily, options: .caseInsensitive) != nil
    }

    private static let dongleFamily = "Jabra Link"

    /// USB serial embedded in a CoreAudio device UID, used to bind an audio
    /// device to one physical dongle instead of to every dongle of its model.
    /// Example UID:
    /// `AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:50C275445423:1`
    public static func serial(fromAudioUID uid: String) -> String? {
        guard uid.hasPrefix("AppleUSBAudioEngine:") else { return nil }
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return nil }
        let serial = String(parts[parts.count - 2])
        return serial.isEmpty ? nil : serial
    }

    public static func serialsMatch(_ left: String, _ right: String) -> Bool {
        left.compare(right, options: .caseInsensitive) == .orderedSame
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

    public static func allowsSelection(
        isSupported: Bool,
        state: LinkState
    ) -> Bool {
        guard isSupported else { return true }
        // Unknown still fails open, because monitoring may be unavailable for
        // perfectly good devices. `.checking` is different: an authoritative
        // answer is milliseconds away, so acting now risks routing audio to a
        // headset that is switched off.
        return state != .down && state != .checking
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
