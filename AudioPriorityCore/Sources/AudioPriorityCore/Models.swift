import Foundation

public enum DeviceRole: String, Codable, CaseIterable, Sendable {
    case input
    case output
}

public enum OutputCategory: String, Codable, CaseIterable, Sendable {
    case speaker
    case headphone
}

public enum LinkState: Equatable, Sendable {
    case up
    case down
    case unknown
    case monitoringUnavailable
}

public struct AudioDevice: Identifiable, Equatable, Hashable, Sendable {
    public let platformID: UInt32
    public let uid: String
    public let name: String
    public let role: DeviceRole
    public var isConnected: Bool
    /// Software routing device (Krisp, Zoom, a Multi-Output Device) rather than
    /// a physical endpoint.
    public var isVirtual: Bool

    public var id: String { roleIdentifier }
    public var roleIdentifier: String { "\(role.rawValue):\(uid)" }
    public var pairingKey: String {
        guard uid.hasPrefix("AppleUSBAudioEngine:"),
              uid.split(
                  separator: ":",
                  omittingEmptySubsequences: false
              ).count >= 5,
              let separator = uid.lastIndex(of: ":") else {
            return uid
        }
        let suffix = uid[uid.index(after: separator)...]
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
            ? String(uid[..<separator])
            : uid
    }

    public init(
        platformID: UInt32,
        uid: String,
        name: String,
        role: DeviceRole,
        isConnected: Bool = true,
        isVirtual: Bool = false
    ) {
        self.platformID = platformID
        self.uid = uid
        self.name = name
        self.role = role
        self.isConnected = isConnected
        self.isVirtual = isVirtual
    }

}

public struct StoredDevice: Codable, Equatable, Sendable {
    public let uid: String
    public let name: String
    public let isInput: Bool
    public var lastSeen: Date

    public var role: DeviceRole { isInput ? .input : .output }

    public init(uid: String, name: String, isInput: Bool, lastSeen: Date) {
        self.uid = uid
        self.name = name
        self.isInput = isInput
        self.lastSeen = lastSeen
    }

    public init(device: AudioDevice, lastSeen: Date) {
        self.init(
            uid: device.uid,
            name: device.name,
            isInput: device.role == .input,
            lastSeen: lastSeen
        )
    }

    public func disconnectedDevice() -> AudioDevice {
        AudioDevice(
            platformID: 0,
            uid: uid,
            name: name,
            role: role,
            isConnected: false
        )
    }

    public func relativeLastSeen(to now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(lastSeen)
        return switch seconds {
        case ..<60: "now"
        case ..<3_600: "\(Int(seconds / 60))m ago"
        case ..<86_400: "\(Int(seconds / 3_600))h ago"
        case ..<604_800: "\(Int(seconds / 86_400))d ago"
        case ..<2_592_000: "\(Int(seconds / 604_800))w ago"
        default: "\(Int(seconds / 2_592_000))mo ago"
        }
    }
}
