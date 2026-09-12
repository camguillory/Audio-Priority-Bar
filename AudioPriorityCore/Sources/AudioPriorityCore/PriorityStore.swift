import Foundation

public final class PriorityStore {
    private enum Key {
        static let inputPriorities = "inputPriorities"
        static let speakerPriorities = "speakerPriorities"
        static let headphonePriorities = "headphonePriorities"
        static let categories = "deviceCategories"
        static let manualMode = "customMode"
        static let linksMicrophone = "linksMicrophone"
        static let knownDevices = "knownDevices"
        static let legacyNeverUse = "neverUseDevices"
        static let neverUseInputs = "neverUseInputs"
        static let neverUseOutputs = "neverUseOutputs"
        static let neverUseMigration = "roleSpecificNeverUseMigration_v1"
        static let bundleMigration = "legacyBundleMigration_v1"
        static let virtualDefaults = "virtualNeverUseDefaults_v1"
        static let hiddenInputs = "hiddenMics"
        static let hiddenSpeakers = "hiddenSpeakers"
        static let hiddenHeadphones = "hiddenHeadphones"
    }

    private static let legacyBundleID = "com.example.AudioPriorityBar"
    private static let legacyBundleKeys = [
        Key.inputPriorities,
        Key.speakerPriorities,
        Key.headphonePriorities,
        Key.categories,
        Key.manualMode,
        Key.knownDevices,
        Key.legacyNeverUse,
        Key.hiddenInputs,
        Key.hiddenSpeakers,
        Key.hiddenHeadphones,
    ]

    private let defaults: UserDefaults
    private let now: () -> Date

    public init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        legacyDomain: [String: Any]? = nil
    ) {
        self.defaults = defaults
        self.now = now
        if legacyDomain != nil || defaults === UserDefaults.standard {
            migrateLegacyBundleIfNeeded(
                from: legacyDomain ?? defaults.persistentDomain(
                    forName: Self.legacyBundleID
                )
            )
            migrateLegacyNeverUseIfNeeded()
        }
    }

    public var knownDevices: [StoredDevice] {
        guard let data = defaults.data(forKey: Key.knownDevices),
              let devices = try? JSONDecoder().decode(
                [StoredDevice].self,
                from: data
              ) else {
            return []
        }
        return devices
    }

    public func remember(_ devices: [AudioDevice]) {
        var known = knownDevices
        // Devices present before this shipped never passed through the
        // first-sight branch, so seed them once too.
        let seedsExisting = !defaults.bool(forKey: Key.virtualDefaults)
        for device in devices {
            let existing = known.firstIndex {
                $0.uid == device.uid && $0.role == device.role
            }
            let stored = StoredDevice(device: device, lastSeen: now())
            if let existing {
                known[existing] = stored
            } else {
                known.append(stored)
            }
            // A routing helper is a poor automatic choice, but stays selectable
            // by hand, and the user can opt it back in permanently.
            if device.isVirtual, existing == nil || seedsExisting {
                setNeverUse(device, true)
            }
        }
        if seedsExisting, !devices.isEmpty {
            defaults.set(true, forKey: Key.virtualDefaults)
        }
        saveKnownDevices(known)
    }

    public func storedDevice(
        uid: String,
        role: DeviceRole? = nil
    ) -> StoredDevice? {
        knownDevices.first {
            $0.uid == uid && (role == nil || $0.role == role)
        }
    }

    public func forget(uid: String, role: DeviceRole) {
        migrateLegacyNeverUseIfNeeded()
        saveKnownDevices(knownDevices.filter {
            !($0.uid == uid && $0.role == role)
        })

        let priorityKeys = role == .input
            ? [Key.inputPriorities]
            : [Key.speakerPriorities, Key.headphonePriorities]
        let hiddenKeys = role == .input
            ? [Key.hiddenInputs]
            : [Key.hiddenSpeakers, Key.hiddenHeadphones]
        for key in priorityKeys + hiddenKeys + [neverUseKey(for: role)] {
            remove(uid, from: key)
        }

        if role == .output {
            var categories = defaults.dictionary(forKey: Key.categories) ?? [:]
            categories.removeValue(forKey: uid)
            defaults.set(categories, forKey: Key.categories)
        }
    }

    public var isManualMode: Bool {
        get { defaults.bool(forKey: Key.manualMode) }
        set { defaults.set(newValue, forKey: Key.manualMode) }
    }

    public var linksMicrophone: Bool {
        get { defaults.object(forKey: Key.linksMicrophone) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.linksMicrophone) }
    }

    public func category(for device: AudioDevice) -> OutputCategory {
        let categories = defaults.dictionary(forKey: Key.categories)
            as? [String: String] ?? [:]
        if let raw = categories[device.uid],
           let category = OutputCategory(rawValue: raw) {
            return category
        }
        return HeadphoneDetection.isHeadphone(device.name)
            ? .headphone
            : .speaker
    }

    public func setCategory(
        _ category: OutputCategory,
        for device: AudioDevice
    ) {
        var categories = defaults.dictionary(forKey: Key.categories)
            as? [String: String] ?? [:]
        categories[device.uid] = category.rawValue
        defaults.set(categories, forKey: Key.categories)
    }

    public func isNeverUse(_ device: AudioDevice) -> Bool {
        migrateLegacyNeverUseIfNeeded()
        return defaults.stringArray(forKey: neverUseKey(for: device.role))?
            .contains(device.uid) == true
    }

    public func setNeverUse(_ device: AudioDevice, _ value: Bool) {
        migrateLegacyNeverUseIfNeeded()
        let key = neverUseKey(for: device.role)
        var uids = defaults.stringArray(forKey: key) ?? []
        if value {
            if !uids.contains(device.uid) { uids.append(device.uid) }
        } else {
            uids.removeAll { $0 == device.uid }
        }
        defaults.set(uids, forKey: key)
    }

    public func isHidden(_ device: AudioDevice) -> Bool {
        defaults.stringArray(forKey: hiddenKey(for: device))?
            .contains(device.uid) == true
    }

    public func isHidden(_ device: AudioDevice, in category: OutputCategory) -> Bool {
        defaults.stringArray(forKey: hiddenKey(for: category))?
            .contains(device.uid) == true
    }

    public func hide(_ device: AudioDevice) {
        add(device.uid, to: hiddenKey(for: device))
    }

    public func hide(_ device: AudioDevice, in category: OutputCategory) {
        add(device.uid, to: hiddenKey(for: category))
    }

    public func unhide(_ device: AudioDevice) {
        remove(device.uid, from: hiddenKey(for: device))
    }

    public func unhide(_ device: AudioDevice, from category: OutputCategory) {
        remove(device.uid, from: hiddenKey(for: category))
    }

    public func sorted(_ devices: [AudioDevice], role: DeviceRole) -> [AudioDevice] {
        sorted(devices, key: priorityKey(role: role, category: nil))
    }

    public func sorted(_ devices: [AudioDevice], category: OutputCategory) -> [AudioDevice] {
        sorted(devices, key: priorityKey(role: .output, category: category))
    }

    public func savePriorities(
        _ devices: [AudioDevice],
        role: DeviceRole
    ) {
        savePriorities(devices, key: priorityKey(role: role, category: nil))
    }

    public func savePriorities(
        _ devices: [AudioDevice],
        category: OutputCategory
    ) {
        savePriorities(devices, key: priorityKey(role: .output, category: category))
    }

    public func firstSelectable(
        in devices: [AudioDevice],
        isUsable: (AudioDevice) -> Bool
    ) -> AudioDevice? {
        devices.first { device in
            return device.isConnected
                && !isHidden(device)
                && !isNeverUse(device)
                && isUsable(device)
        }
    }

    public static func mergeVisibleOrder(
        _ visible: [String],
        into stored: [String]
    ) -> [String] {
        let visible = visible.uniqued()
        let visibleSet = Set(visible)
        var remaining = visible.makeIterator()
        var merged = stored.compactMap { uid in
            visibleSet.contains(uid) ? remaining.next() : uid
        }
        merged.append(contentsOf: IteratorSequence(remaining))
        return merged.uniqued()
    }

    private func saveKnownDevices(_ devices: [StoredDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Key.knownDevices)
        }
    }

    private func migrateLegacyBundleIfNeeded(from legacy: [String: Any]?) {
        guard let legacy,
              !defaults.bool(forKey: Key.bundleMigration) else {
            return
        }
        for key in Self.legacyBundleKeys
        where defaults.object(forKey: key) == nil {
            if let value = legacy[key] {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: Key.bundleMigration)
    }

    private func migrateLegacyNeverUseIfNeeded() {
        let hasLegacyValues = defaults.object(forKey: Key.legacyNeverUse) != nil
        guard hasLegacyValues
                || !defaults.bool(forKey: Key.neverUseMigration) else {
            return
        }
        let legacy = defaults.stringArray(forKey: Key.legacyNeverUse) ?? []
        for key in [Key.neverUseInputs, Key.neverUseOutputs] {
            let existing = defaults.stringArray(forKey: key) ?? []
            defaults.set((existing + legacy).uniqued(), forKey: key)
        }
        defaults.removeObject(forKey: Key.legacyNeverUse)
        defaults.set(true, forKey: Key.neverUseMigration)
    }

    private func neverUseKey(for role: DeviceRole) -> String {
        role == .input ? Key.neverUseInputs : Key.neverUseOutputs
    }

    private func hiddenKey(for device: AudioDevice) -> String {
        if device.role == .input { return Key.hiddenInputs }
        return hiddenKey(for: category(for: device))
    }

    private func hiddenKey(for category: OutputCategory) -> String {
        category == .speaker ? Key.hiddenSpeakers : Key.hiddenHeadphones
    }

    private func priorityKey(
        role: DeviceRole,
        category: OutputCategory?
    ) -> String {
        if role == .input { return Key.inputPriorities }
        return category == .headphone
            ? Key.headphonePriorities
            : Key.speakerPriorities
    }

    private func sorted(
        _ devices: [AudioDevice],
        key: String
    ) -> [AudioDevice] {
        let priorities = defaults.stringArray(forKey: key) ?? []
        // ponytail: device lists are tiny; index scans keep ordering obvious.
        return devices.enumerated()
            .sorted { left, right in
                let lhs = priorities.firstIndex(of: left.element.uid) ?? .max
                let rhs = priorities.firstIndex(of: right.element.uid) ?? .max
                return lhs == rhs ? left.offset < right.offset : lhs < rhs
            }
            .map(\.element)
    }

    private func savePriorities(_ devices: [AudioDevice], key: String) {
        let visible = devices.map(\.uid)
        let stored = defaults.stringArray(forKey: key) ?? []
        defaults.set(
            Self.mergeVisibleOrder(visible, into: stored),
            forKey: key
        )
    }

    private func add(_ uid: String, to key: String) {
        var values = defaults.stringArray(forKey: key) ?? []
        if !values.contains(uid) {
            values.append(uid)
            defaults.set(values, forKey: key)
        }
    }

    private func remove(_ uid: String, from key: String) {
        var values = defaults.stringArray(forKey: key) ?? []
        values.removeAll { $0 == uid }
        defaults.set(values, forKey: key)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
