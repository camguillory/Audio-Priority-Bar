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

/// A speaker or headphones paired with this Mac.
public struct PairedBluetoothDevice: Equatable, Sendable {
    public let name: String
    /// Dash separated, such as `70-AE-2A-5E-21-CD`, the form CoreAudio builds
    /// a Bluetooth UID from.
    public let address: String
    public let category: OutputCategory

    /// Its output as a disconnected row, under the UID CoreAudio gives it, so
    /// the row keeps its saved choices across the connection.
    public var device: AudioDevice {
        AudioDevice(
            platformID: 0,
            uid: "\(address):output",
            name: name,
            role: .output,
            isConnected: false,
            declaredCategory: category
        )
    }
}

public struct BluetoothBatteryReport: Equatable, Sendable {
    /// Keyed by address, uppercased hex digits with separators removed.
    public var byAddress: [String: BatteryLevels] = [:]
    public var byName: [String: BatteryLevels] = [:]
    public var pairedAudio: [PairedBluetoothDevice] = []

    public init(
        byAddress: [String: BatteryLevels] = [:],
        byName: [String: BatteryLevels] = [:],
        pairedAudio: [PairedBluetoothDevice] = []
    ) {
        self.byAddress = byAddress
        self.byName = byName
        self.pairedAudio = pairedAudio
    }

    /// The paired device behind a UID, matching a headset's `:input` row as
    /// well as its output. The name is a fallback for a UID in some other
    /// shape, as in `levels(for:)`.
    public func bluetoothDevice(for device: AudioDevice) -> PairedBluetoothDevice? {
        pairedAudio.first { device.uid.hasPrefix("\($0.address):") }
            ?? pairedAudio.first { $0.name == device.name }
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

    /// The address a Bluetooth device's UID starts with, such as
    /// `70-AE-2A-5E-21-CD` from `70-AE-2A-5E-21-CD:output`, or nil for a UID
    /// in any other shape.
    public static func address(of device: AudioDevice) -> String? {
        let prefix = device.uid.prefix { $0 != ":" }
        let parts = prefix.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 6,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
            return nil
        }
        return String(prefix)
    }

    /// The Bluetooth class of device names `system_profiler` reports for
    /// speakers and headphones. Mice, keyboards and phones are left out.
    // ponytail: only the names seen on real devices plus their obvious
    // siblings; add another audio class here when a device turns up missing.
    static let pairedCategories: [String: OutputCategory] = [
        "Speaker": .speaker,
        "Loudspeaker": .speaker,
        "Headphones": .headphone,
        "Headset": .headphone,
    ]

    /// Parses `system_profiler -json SPBluetoothDataType`, keeping connected
    /// Apple headphones that report at least one level, and every paired
    /// speaker or headphones.
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
            // Both lists, because right after a device drops the profiler can
            // still call it connected; CoreAudio decides which ones are off.
            let paired = ["device_connected", "device_not_connected"]
                .flatMap { controller[$0] as? [[String: Any]] ?? [] }
            for entry in paired {
                for (name, value) in entry {
                    guard let info = value as? [String: Any],
                          let address = info["device_address"] as? String,
                          let category = (info["device_minorType"] as? String)
                              .flatMap({ pairedCategories[$0] }) else { continue }
                    report.pairedAudio.append(PairedBluetoothDevice(
                        name: name,
                        address: address.uppercased().replacingOccurrences(of: ":", with: "-"),
                        category: category
                    ))
                }
            }
        }
        // Keeps a device in place in the panel as it connects and drops.
        report.pairedAudio.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return report
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }
}

/// Reads AirPods battery levels and paired audio devices from
/// `system_profiler`, which needs no Bluetooth permission. Each read takes a
/// few hundred milliseconds, so it runs off the main actor and only when asked.
@MainActor
@Observable
public final class BluetoothBatteryMonitor {
    public private(set) var report = BluetoothBatteryReport()
    /// Called when the paired audio devices change.
    @ObservationIgnored public var onPairedAudioChange: (() -> Void)?
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
                let pairedChanged = report.pairedAudio != self.report.pairedAudio
                if report != self.report { self.report = report }
                if pairedChanged { onPairedAudioChange?() }
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
