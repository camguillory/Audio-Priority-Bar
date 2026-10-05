import Foundation
import Observation

/// Battery percentages one Bluetooth device reports, each `nil` while it
/// reports nothing for that part, as for a pod sitting in a closed case.
public struct BatteryLevels: Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public var `case`: Int?
    /// Headphones with one battery, such as AirPods Max.
    public var main: Int?
    /// A headset other than AirPods, such as a Jabra behind its Link dongle.
    public var headset: Int?

    public init(
        left: Int? = nil,
        right: Int? = nil,
        case: Int? = nil,
        main: Int? = nil,
        headset: Int? = nil
    ) {
        self.left = left
        self.right = right
        self.case = `case`
        self.main = main
        self.headset = headset
    }

    public var isEmpty: Bool {
        left == nil && right == nil && `case` == nil && main == nil && headset == nil
    }
}

/// One battery shown on a device row: the earbuds, the case, or a single
/// battery.
public struct BatteryBadge: Equatable, Sendable {
    /// At or below this level a badge is flagged as low.
    public static let lowLevel = 20

    public let icon: String
    public let text: String
    public let spokenText: String
    public let isLow: Bool

    init(icon: String, text: String, spokenText: String, level: Int) {
        self.icon = icon
        self.text = text
        self.spokenText = spokenText
        isLow = level <= Self.lowLevel
    }
}

extension BatteryLevels {
    /// Earbuds first, then the case, each only while it reports a level. The
    /// earbuds share a badge, one number when they match and named by side
    /// otherwise, flagged low when either is.
    public var badges: [BatteryBadge] {
        var result: [BatteryBadge] = []
        if let main {
            result.append(BatteryBadge(
                icon: "airpodsmax", text: "\(main)%", spokenText: "Battery \(main)%", level: main
            ))
        }
        if let headset {
            result.append(BatteryBadge(
                icon: "headphones", text: "\(headset)%", spokenText: "Battery \(headset)%", level: headset
            ))
        }
        let sides = [("L", "Left", left), ("R", "Right", right)]
            .compactMap { short, long, level in level.map { (short, long, $0) } }
        if let left, left == right {
            result.append(BatteryBadge(
                icon: "airpods", text: "\(left)%", spokenText: "Earbuds \(left)%", level: left
            ))
        } else if let lowest = sides.map(\.2).min() {
            result.append(BatteryBadge(
                icon: "airpods",
                text: sides.map { "\($0.0) \($0.2)%" }.joined(separator: " "),
                spokenText: sides.map { "\($0.1) earbud \($0.2)%" }.joined(separator: ", "),
                level: lowest
            ))
        }
        if let level = `case` {
            result.append(BatteryBadge(
                icon: "airpods.chargingcase",
                text: "\(level)%",
                spokenText: "Case \(level)%",
                level: level
            ))
        }
        return result
    }
}

public struct BluetoothBatteryReport: Equatable, Sendable {
    /// Keyed by address, uppercased hex digits with separators removed.
    public var byAddress: [String: BatteryLevels] = [:]
    public var byName: [String: BatteryLevels] = [:]

    public init(byAddress: [String: BatteryLevels] = [:], byName: [String: BatteryLevels] = [:]) {
        self.byAddress = byAddress
        self.byName = byName
    }

    /// Levels for an audio device. CoreAudio gives a Bluetooth device a UID
    /// built from its address, such as `70-AE-2A-5E-21-CD:output`; the name is
    /// a fallback for a UID in some other shape.
    public func levels(for device: AudioDevice) -> BatteryLevels? {
        let uid = BluetoothBattery.normalizedAddress(device.uid)
        if let match = byAddress.first(where: { uid.hasPrefix($0.key) }) {
            return match.value
        }
        return byName[device.name]
    }
}

public enum BluetoothBattery {
    /// Apple's Bluetooth vendor ID, carried by AirPods and Beats.
    static let appleVendorID = "0x004C"

    static func normalizedAddress(_ text: String) -> String {
        String(text.uppercased().filter(\.isHexDigit))
    }

    /// Parses `system_profiler -json SPBluetoothDataType`, keeping connected
    /// Apple headphones that report at least one level.
    public static func parse(_ data: Data) -> BluetoothBatteryReport {
        var report = BluetoothBatteryReport()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else {
            return report
        }
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any],
                          (info["device_vendorID"] as? String)?.uppercased()
                              == appleVendorID.uppercased() else { continue }
                    let levels = BatteryLevels(
                        left: percent(info["device_batteryLevelLeft"]),
                        right: percent(info["device_batteryLevelRight"]),
                        case: percent(info["device_batteryLevelCase"]),
                        main: percent(info["device_batteryLevelMain"])
                    )
                    guard !levels.isEmpty else { continue }
                    if let address = info["device_address"] as? String {
                        report.byAddress[normalizedAddress(address)] = levels
                    }
                    report.byName[name] = levels
                }
            }
        }
        return report
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }
}

/// Reads AirPods battery levels from `system_profiler`, which needs no
/// Bluetooth permission. Each read takes a few hundred milliseconds, so it runs
/// off the main actor and only when asked.
@MainActor
@Observable
public final class BluetoothBatteryMonitor {
    public private(set) var report = BluetoothBatteryReport()
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var isReadPending = false
    @ObservationIgnored private let read: @Sendable () async -> Data?

    public init(read: @escaping @Sendable () async -> Data? = BluetoothBatteryMonitor.systemProfiler) {
        self.read = read
    }

    public func levels(for device: AudioDevice) -> BatteryLevels? {
        device.isConnected ? report.levels(for: device) : nil
    }

    /// Starts a read, or queues one more if a read is already running so a
    /// change made during it is not missed.
    public func refresh() {
        guard !isReading else {
            isReadPending = true
            return
        }
        isReading = true
        Task {
            let data = await read()
            if let data {
                let report = BluetoothBattery.parse(data)
                if report != self.report { self.report = report }
            }
            isReading = false
            if isReadPending {
                isReadPending = false
                refresh()
            }
        }
    }

    public nonisolated static func systemProfiler() async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["-json", "SPBluetoothDataType"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: process.terminationStatus == 0 ? data : nil
                )
            }
        }
    }
}
