import Foundation

public final class PriorityStore {
    private enum Key {
        static let inputPriorities = "inputPriorities"
        static let headphoneMicrophonePriorities = "microphonePrioritiesWithHeadphones"
        static let microphonesFollowOutput = "microphonesFollowOutput"
        static let speakerPriorities = "speakerPriorities"
        static let headphonePriorities = "headphonePriorities"
        static let categories = "deviceCategories"
        static let manualMode = "customMode"
        static let linksMicrophone = "linksMicrophone"
        static let selectsPairedDevice = "selectsPairedDevice"
        static let separatelySelectedDevices = "separatelySelectedDevices"
        static let hideNewDisplayOutputs = "hideNewDisplayOutputs"
        static let displayDefaultsApplied = "displayDefaultsApplied"
        static let knownDevices = "knownDevices"
        static let ambiguousPortFamilies = "ambiguousPortFamilies"
        static let forgottenPairedDevices = "forgottenPairedDevices"
        static let legacyNeverUse = "neverUseDevices"
        static let neverUseInputs = "neverUseInputs"
        static let neverUseOutputs = "neverUseOutputs"
        static let neverUseMigration = "roleSpecificNeverUseMigration_v1"
        static let bundleMigration = "legacyBundleMigration_v1"
        static let virtualDefaults = "virtualNeverUseDefaults_v1"
        static let hiddenInputs = "hiddenMics"
        static let hiddenSpeakers = "hiddenSpeakers"
        static let hiddenHeadphones = "hiddenHeadphones"
        static let appliedMicrophoneMutes = "appliedMicrophoneMutes"
        static let showsSwitchNotice = "showsSwitchNotice"
        static let remindsWhenMuted = "remindsWhenMuted"
        static let mutesSpeakersWhenHeadphonesDisconnect = "mutesSpeakersWhenHeadphonesDisconnect"
        static let lightsBusylightWhileRecording = "lightsBusylightWhileRecording"
        static let outlinesMenuBarIcon = "outlinesMenuBarIcon"
        static let menuBarDevices = "menuBarDevices"
        static let showsMenuBarVolume = "showsMenuBarVolume"
        static let pulsesMutedMicrophone = "pulsesMutedMicrophone"
        static let redIconWhenManual = "redIconWhenManual"
        static let keepsDebugLog = "keepsDebugLog"
        static let priorityProfiles = "priorityProfiles"
        static let activePriorityProfile = "activePriorityProfile"
        static let profileBeforeFocus = "profileBeforeFocus"
    }

    /// Marks a microphone muted through its mute property rather than by
    /// zeroing its input volume.
    public static let mutedByProperty: Double = -1

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
        // One-time migration from the pre-rename key: the new key's presence
        // makes this idempotent, so no marker key is needed.
        if defaults.object(forKey: Key.selectsPairedDevice) == nil,
           let legacyValue = defaults.object(forKey: Key.linksMicrophone) as? Bool {
            defaults.set(legacyValue, forKey: Key.selectsPairedDevice)
        }
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
        reconcilePortChanges(devices, known: &known)
        // Devices present before this shipped never passed through the
        // first-sight branch, so seed them once too.
        let seedsExisting = !defaults.bool(forKey: Key.virtualDefaults)
        for device in devices {
            let existing = known.firstIndex {
                $0.uid == device.uid && $0.role == device.role
            }
            var stored = StoredDevice(device: device, lastSeen: now())
            if let existing {
                stored.previousUIDs = known[existing].previousUIDs
                stored.portHistory = known[existing].portHistory
                if stored.followsPortChanges == nil {
                    stored.followsPortChanges = known[existing].followsPortChanges
                }
                known[existing] = stored
            } else {
                known.append(stored)
            }
            // A routing helper is a poor automatic choice, but stays selectable
            // by hand, and the user can opt it back in permanently.
            if device.isVirtual, existing == nil || seedsExisting {
                setNeverUse(device, true)
            }
            applyDisplayDefaultIfNeeded(device)
        }
        if seedsExisting, !devices.isEmpty {
            defaults.set(true, forKey: Key.virtualDefaults)
        }
        saveKnownDevices(known)
        // ponytail: matched by UID only, so a Bluetooth device whose CoreAudio
        // UID is not built from its address stays forgotten; clear by name too
        // if one turns up.
        let seen = Set(devices.map(\.uid))
        let forgotten = defaults.stringArray(forKey: Key.forgottenPairedDevices) ?? []
        defaults.set(forgotten.filter { !seen.contains($0) }, forKey: Key.forgottenPairedDevices)
    }

    /// Old Shortcuts may refer to the port where a device was first selected.
    public func currentUID(for uid: String, role: DeviceRole) -> String {
        let known = knownDevices.filter { $0.role == role }
        if known.contains(where: { $0.uid == uid }) { return uid }
        return known.first { $0.previousUIDs?.contains(uid) == true }?.uid ?? uid
    }

    private func reconcilePortChanges(_ devices: [AudioDevice], known: inout [StoredDevice]) {
        let candidates = devices.compactMap { device -> (AudioDevice, PortIdentity)? in
            guard device.isConnected, device.isDisplayOutput || device.usesUSBLocation == true,
                  let identity = PortIdentity(device.uid),
                  (identity.usbLocation != nil) == (device.usesUSBLocation == true) else { return nil }
            return (device, identity)
        }
        guard !candidates.isEmpty else { return }
        let connected = Set(devices.filter(\.isConnected).map(\.uid))
        let originalPairs = Set(defaults.stringArray(forKey: Key.separatelySelectedDevices) ?? [])
        var ambiguous = Set(defaults.stringArray(forKey: Key.ambiguousPortFamilies) ?? [])
        for (family, group) in Dictionary(grouping: candidates, by: { $0.1.family }) {
            if Set(group.map { $0.1.port }).count > 1, ambiguous.insert(family).inserted {
                // Once two copies have appeared together, a future lone copy
                // cannot prove which one moved. Keep using their exact UIDs.
                defaults.set(ambiguous.sorted(), forKey: Key.ambiguousPortFamilies)
                for i in known.indices where PortIdentity(known[i].uid)?.family == family {
                    if let history = known[i].portHistory {
                        restoreIndependentPorts(history, for: known[i])
                    }
                    known[i].portHistory = nil
                    known[i].previousUIDs = nil
                }
            }
            guard !ambiguous.contains(family) else { continue }
            for (device, identity) in group {
                let matches = known.filter { stored in
                    guard stored.role == device.role, !connected.contains(stored.uid),
                          let old = PortIdentity(stored.uid), old.family == family,
                          old.endpoint == identity.endpoint else { return false }
                    if let verified = stored.followsPortChanges { return verified }
                    // A past device without a descriptor (or a legacy record)
                    // must have a plausible hub location. A legacy display
                    // must have passed the old transport-based display check.
                    if old.usbLocation != nil {
                        return (5...8).contains(old.port.count) && old.port.hasSuffix("00")
                    }
                    return defaults.stringArray(forKey: Key.displayDefaultsApplied)?
                        .contains(stored.uid) == true
                }
                guard !matches.isEmpty else { continue }
                let previous = matches.sorted { $0.lastSeen > $1.lastSeen }
                let existing = known.first { $0.uid == device.uid && $0.role == device.role }
                let records = [existing].compactMap { $0 } + previous
                var originals: [String: PortChoices] = [:]
                for record in records {
                    let current = portChoices(record.uid, role: record.role, separatePairs: originalPairs)
                    if var history = record.portHistory {
                        history.ports[record.uid] = updatedPortChoices(
                            history.ports[record.uid], inherited: history.inherited, current: current
                        )
                        originals.merge(history.ports) { saved, _ in saved }
                    } else {
                        originals[record.uid] = current
                    }
                }
                if originals[device.uid] == nil {
                    originals[device.uid] = portChoices(device.uid, role: device.role, separatePairs: originalPairs)
                }
                mergePreferences(of: records, into: device)
                let aliases = Set(records.flatMap { [$0.uid] + ($0.previousUIDs ?? []) })
                let mergedUIDs = Set(records.map(\.uid))
                known.removeAll { $0.role == device.role && mergedUIDs.contains($0.uid) }
                var merged = StoredDevice(device: device, lastSeen: now())
                merged.previousUIDs = aliases.subtracting([device.uid]).sorted()
                merged.portHistory = PortHistory(ports: originals, inherited: portChoices(device.uid, role: device.role))
                known.append(merged)
            }
        }
    }

    private func portChoices(_ uid: String, role: DeviceRole, separatePairs: Set<String>? = nil) -> PortChoices {
        var choices = PortChoices()
        visitPortLists(role: role) { key, list, ordered in
            let id = key == Key.separatelySelectedDevices ? AudioDevice.pairingKey(of: uid) : uid
            choices.positions[key] = list.firstIndex(of: id).map { ordered ? $0 : 0 }
            return list
        }
        if let separatePairs {
            choices.positions[Key.separatelySelectedDevices] = separatePairs.contains(AudioDevice.pairingKey(of: uid)) ? 0 : nil
        }
        if role == .output {
            choices.category = defaults.dictionary(forKey: Key.categories)?[uid] as? String
        }
        return choices
    }

    /// Only differences from the inherited values were chosen at this port.
    /// An explicit display visibility change also consumes its first-sight default.
    private func updatedPortChoices(
        _ original: PortChoices?, inherited: PortChoices, current: PortChoices
    ) -> PortChoices {
        var result = original ?? PortChoices()
        for key in Set(inherited.positions.keys).union(current.positions.keys)
        where inherited.positions[key] != current.positions[key] {
            result.positions[key] = current.positions[key]
            if (key == Key.hiddenSpeakers || key == Key.hiddenHeadphones),
               let seen = current.positions[Key.displayDefaultsApplied] {
                if original?.positions[Key.displayDefaultsApplied] == nil {
                    result.positions[Key.hiddenSpeakers] = current.positions[Key.hiddenSpeakers]
                    result.positions[Key.hiddenHeadphones] = current.positions[Key.hiddenHeadphones]
                }
                result.positions[Key.displayDefaultsApplied] = seen
            }
        }
        if inherited.category != current.category { result.category = current.category }
        return result
    }

    private func restoreIndependentPorts(_ history: PortHistory, for device: StoredDevice) {
        var ports = history.ports
        ports[device.uid] = updatedPortChoices(
            ports[device.uid], inherited: history.inherited, current: portChoices(device.uid, role: device.role)
        )
        visitPortLists(role: device.role) { key, list, ordered in
            let usesPairKeys = key == Key.separatelySelectedDevices
            let affected = Set(ports.keys.map { usesPairKeys ? AudioDevice.pairingKey(of: $0) : $0 })
            var result = list.filter { !affected.contains($0) }
            let positions = ports.compactMap { uid, choices -> (String, Int)? in
                guard let rank = choices.positions[key] else { return nil }
                return (usesPairKeys ? AudioDevice.pairingKey(of: uid) : uid, rank)
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            for (uid, rank) in positions where !result.contains(uid) {
                result.insert(uid, at: ordered ? max(0, min(rank, result.count)) : result.count)
            }
            return result
        }
        if device.role == .output {
            var categories = defaults.dictionary(forKey: Key.categories) as? [String: String] ?? [:]
            for (uid, choices) in ports { categories[uid] = choices.category }
            defaults.set(categories, forKey: Key.categories)
        }
        // Mute recovery describes a hardware operation, not a preference.
        // Never resurrect old recovery records after a successful unmute.
    }

    /// Visit the UID lists for one endpoint, including each saved profile.
    /// The callback can inspect the lists or return replacements.
    private func visitPortLists(
        role: DeviceRole,
        _ transform: (String, [String], Bool) -> [String]
    ) {
        let inputs = role == .input
        let orders = inputs ? [Key.inputPriorities, Key.headphoneMicrophonePriorities]
                            : [Key.speakerPriorities, Key.headphonePriorities]
        let flags = inputs ? [Key.hiddenInputs] : [Key.hiddenSpeakers, Key.hiddenHeadphones, Key.displayDefaultsApplied]
        let old = storedProfiles
        var profiles = old
        for i in profiles.indices {
            let prefix = profiles[i].id.uuidString + "."
            if inputs {
                profiles[i].microphones = transform(prefix + Key.inputPriorities, profiles[i].microphones, true)
                if let order = profiles[i].microphonesWithHeadphones {
                    profiles[i].microphonesWithHeadphones = transform(prefix + Key.headphoneMicrophonePriorities, order, true)
                }
            } else {
                profiles[i].speakers = transform(prefix + Key.speakerPriorities, profiles[i].speakers, true)
                profiles[i].headphones = transform(prefix + Key.headphonePriorities, profiles[i].headphones, true)
            }
        }
        let active = activeProfileID
        if profiles != old { saveProfiles(profiles, active: active) }
        // The active profile's editable orders live outside the profile array.
        // Read them last, under the same profile ID, so switching profiles
        // while ports are merged cannot transfer one desk's ranks to another.
        for key in orders + flags + [neverUseKey(for: role), Key.separatelySelectedDevices] {
            let value = defaults.stringArray(forKey: key) ?? []
            let ordered = orders.contains(key)
            let prefix = ordered ? active.map { $0.uuidString + "." } ?? "" : ""
            let updated = transform(prefix + key, value, ordered)
            if value != updated { defaults.set(updated, forKey: key) }
        }
    }

    private func mergePreferences(of records: [StoredDevice], into device: AudioDevice) {
        migrateLegacyNeverUseIfNeeded()
        let ids = records.map(\.uid)
        let aliases = Set(ids)
        let uid = device.uid
        let isInput = device.role == .input
        let pairKeys = Set(ids.map(AudioDevice.pairingKey(of:)))
        visitPortLists(role: device.role) { key, values, _ in
            if key == Key.separatelySelectedDevices {
                return values.map { pairKeys.contains($0) ? device.pairingKey : $0 }.uniqued()
            }
            if device.isDisplayOutput, key == Key.hiddenSpeakers || key == Key.hiddenHeadphones,
               !aliases.isSubset(of: values) {
                // New displays start hidden. A visible alias records the user's choice.
                return values.filter { !aliases.contains($0) && $0 != uid }
            }
            // Keep the highest rank, including in inactive profiles.
            return values.map { aliases.contains($0) ? uid : $0 }.uniqued()
        }
        let key = isInput ? Key.appliedMicrophoneMutes : Key.categories
        if var values = defaults.dictionary(forKey: key),
           let chosen = ([uid] + ids).compactMap({ values[$0] }).first {
            for old in ids { values.removeValue(forKey: old) }
            values[uid] = chosen
            defaults.set(values, forKey: key)
        }
    }

    /// A Bluetooth device forgotten while off stays out of the panel, though
    /// macOS still pairs it, until it is seen connected again.
    public func isForgotten(uid: String) -> Bool {
        defaults.stringArray(forKey: Key.forgottenPairedDevices)?.contains(uid) == true
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
            ? [Key.inputPriorities, Key.headphoneMicrophonePriorities]
            : [Key.speakerPriorities, Key.headphonePriorities]
        let hiddenKeys = role == .input
            ? [Key.hiddenInputs]
            : [Key.hiddenSpeakers, Key.hiddenHeadphones]
        for key in priorityKeys + hiddenKeys + [neverUseKey(for: role)] {
            remove(uid, from: key)
        }
        removeFromProfiles(uid, role: role)

        if role == .output {
            var categories = defaults.dictionary(forKey: Key.categories) ?? [:]
            categories.removeValue(forKey: uid)
            defaults.set(categories, forKey: Key.categories)
            // Forgetting clears every saved choice, so a display seen again
            // afterwards is genuinely new and gets the default once more.
            remove(uid, from: Key.displayDefaultsApplied)
            add(uid, to: Key.forgottenPairedDevices)
        }
        remove(AudioDevice.pairingKey(of: uid), from: Key.separatelySelectedDevices)
    }

    public var isManualMode: Bool {
        get { defaults.bool(forKey: Key.manualMode) }
        set { defaults.set(newValue, forKey: Key.manualMode) }
    }

    /// Whether choosing one device of a paired pair, a headset's microphone
    /// or output, selects the other too.
    public var selectsPairedDevice: Bool {
        get { defaults.object(forKey: Key.selectsPairedDevice) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.selectsPairedDevice) }
    }

    /// Whether `selectsPairedDevice` applies to this physical device. A dock
    /// or an audio interface can be set apart, so its output is used without
    /// its microphone overriding the microphone order. Both halves share
    /// the answer.
    public func selectsHalvesTogether(_ device: AudioDevice) -> Bool {
        defaults.stringArray(forKey: Key.separatelySelectedDevices)?
            .contains(device.pairingKey) != true
    }

    public func setSelectsHalvesTogether(_ device: AudioDevice, _ value: Bool) {
        if value {
            remove(device.pairingKey, from: Key.separatelySelectedDevices)
        } else {
            add(device.pairingKey, to: Key.separatelySelectedDevices)
        }
    }

    /// Whether headphones keep a microphone order of their own, while speakers
    /// keep the original one. The first time it is turned on, the headphone
    /// order starts as a copy, so nothing changes until the user reorders it;
    /// turning it off keeps that order for next time.
    public var microphonesFollowOutput: Bool {
        get { defaults.bool(forKey: Key.microphonesFollowOutput) }
        set {
            if newValue, defaults.object(forKey: Key.headphoneMicrophonePriorities) == nil {
                defaults.set(
                    defaults.stringArray(forKey: Key.inputPriorities) ?? [],
                    forKey: Key.headphoneMicrophonePriorities
                )
            }
            defaults.set(newValue, forKey: Key.microphonesFollowOutput)
        }
    }

    public var hideNewDisplayOutputs: Bool {
        get {
            defaults.object(forKey: Key.hideNewDisplayOutputs) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Key.hideNewDisplayOutputs) }
    }

    public var showsSwitchNotice: Bool {
        get { defaults.object(forKey: Key.showsSwitchNotice) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showsSwitchNotice) }
    }

    public var remindsWhenMuted: Bool {
        get { defaults.object(forKey: Key.remindsWhenMuted) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.remindsWhenMuted) }
    }

    public var mutesSpeakersWhenHeadphonesDisconnect: Bool {
        get { defaults.object(forKey: Key.mutesSpeakersWhenHeadphonesDisconnect) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.mutesSpeakersWhenHeadphonesDisconnect) }
    }

    public var lightsBusylightWhileRecording: Bool {
        get { defaults.bool(forKey: Key.lightsBusylightWhileRecording) }
        set { defaults.set(newValue, forKey: Key.lightsBusylightWhileRecording) }
    }

    public var outlinesMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.outlinesMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.outlinesMenuBarIcon) }
    }

    public var menuBarDevices: MenuBarDevices {
        get {
            defaults.string(forKey: Key.menuBarDevices).flatMap(MenuBarDevices.init)
                ?? .outputOnly
        }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarDevices) }
    }

    public var showsMenuBarVolume: Bool {
        get { defaults.bool(forKey: Key.showsMenuBarVolume) }
        set { defaults.set(newValue, forKey: Key.showsMenuBarVolume) }
    }

    /// Whether the menu bar icon pulses while the active microphone is muted.
    public var pulsesMutedMicrophone: Bool {
        get { defaults.object(forKey: Key.pulsesMutedMicrophone) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.pulsesMutedMicrophone) }
    }

    /// Whether the menu bar icon turns red while automatic switching is off.
    public var redIconWhenManual: Bool {
        get { defaults.bool(forKey: Key.redIconWhenManual) }
        set { defaults.set(newValue, forKey: Key.redIconWhenManual) }
    }

    /// Whether the app writes what it sees and does to a local log file.
    public var keepsDebugLog: Bool {
        get { defaults.bool(forKey: Key.keepsDebugLog) }
        set { defaults.set(newValue, forKey: Key.keepsDebugLog) }
    }

    /// Microphones this app muted and has not restored yet, by UID: the input
    /// volume to restore, or `mutedByProperty`. Persisted so a crash or an
    /// unplugged microphone never leaves one silently muted.
    public var appliedMicrophoneMutes: [String: Double] {
        get {
            defaults.dictionary(forKey: Key.appliedMicrophoneMutes)
                as? [String: Double] ?? [:]
        }
        set { defaults.set(newValue, forKey: Key.appliedMicrophoneMutes) }
    }

    public func category(for device: AudioDevice) -> OutputCategory {
        let categories = defaults.dictionary(forKey: Key.categories)
            as? [String: String] ?? [:]
        if let raw = categories[device.uid],
           let category = OutputCategory(rawValue: raw) {
            return category
        }
        // Ahead of the device's own claim, because a speakerphone has no
        // terminal type of its own and may describe itself as headphones.
        if HeadphoneDetection.isKnownSpeaker(device.name) {
            return .speaker
        }
        if let declared = device.declaredCategory {
            return declared
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

    /// Microphones in the order kept for `output`, the category of the device
    /// playing. A nil category, or the setting off, means the original order.
    public func sorted(
        _ devices: [AudioDevice],
        microphonesFor output: OutputCategory?
    ) -> [AudioDevice] {
        sorted(devices, key: priorityKey(role: .input, category: output))
    }

    public func savePriorities(
        _ devices: [AudioDevice],
        microphonesFor output: OutputCategory?
    ) {
        savePriorities(devices, key: priorityKey(role: .input, category: output))
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

    /// Hides a monitor or TV the first time it is seen, and records that it
    /// has been dealt with. Deciding once is what makes showing one by hand
    /// permanent: a later sighting must never hide it again. The record is kept
    /// even when the preference is off, so turning the preference on applies to
    /// genuinely new devices rather than retroactively.
    ///
    /// Hidden in both output categories, matching the app's single Hide
    /// command: a later category move must not surface a device the user
    /// never asked to see.
    private func applyDisplayDefaultIfNeeded(_ device: AudioDevice) {
        guard device.isDisplayOutput else { return }
        var applied = defaults.stringArray(forKey: Key.displayDefaultsApplied) ?? []
        guard !applied.contains(device.uid) else { return }
        applied.append(device.uid)
        defaults.set(applied, forKey: Key.displayDefaultsApplied)
        if hideNewDisplayOutputs {
            hide(device, in: .speaker)
            hide(device, in: .headphone)
        }
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
        if role == .input {
            return category == .headphone && microphonesFollowOutput
                ? Key.headphoneMicrophonePriorities
                : Key.inputPriorities
        }
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

/// A named set of the priority orders and whether automatic switching is on.
/// Everything else, like hiding, Never Auto-Select and categories, is shared.
public struct PriorityProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var speakers: [String]
    public var headphones: [String]
    public var microphones: [String]
    /// Nil until microphones following the output has been turned on.
    public var microphonesWithHeadphones: [String]?
    public var isManual: Bool
}

extension PriorityStore {
    /// Every profile, the active one holding the lists in use right now. The
    /// setup from before profiles existed becomes the first one, Default.
    public var profiles: [PriorityProfile] {
        var stored = storedProfiles
        if stored.isEmpty {
            stored = [currentLists(id: UUID(), name: "Default")]
            saveProfiles(stored, active: stored[0].id)
        }
        let active = activeProfileID
        return stored.map { $0.id == active ? currentLists(id: $0.id, name: $0.name) : $0 }
    }

    public var activeProfileID: UUID? {
        if let raw = defaults.string(forKey: Key.activePriorityProfile),
           let id = UUID(uuidString: raw),
           storedProfiles.contains(where: { $0.id == id }) {
            return id
        }
        return storedProfiles.first?.id
    }

    /// The profile active when a Focus applied another, to return to when it
    /// ends.
    public var profileBeforeFocus: UUID? {
        get { defaults.string(forKey: Key.profileBeforeFocus).flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: Key.profileBeforeFocus) }
    }

    /// Adds a copy of the lists in use under a name no other profile has.
    @discardableResult
    public func addProfile(named name: String) -> PriorityProfile {
        let all = profiles
        let added = currentLists(id: UUID(), name: Self.uniqueName(name, among: all))
        saveProfiles(all + [added], active: activeProfileID)
        return added
    }

    /// A blank name keeps the current one.
    public func renameProfile(_ id: UUID, to name: String) {
        var all = profiles
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].name = Self.uniqueName(name, among: all.filter { $0.id != id })
        saveProfiles(all, active: activeProfileID)
    }

    /// Makes `id` the active profile, keeping the outgoing one's lists, and
    /// returns whether anything changed.
    @discardableResult
    public func loadProfile(_ id: UUID) -> Bool {
        let all = profiles
        guard id != activeProfileID,
              let target = all.first(where: { $0.id == id }) else { return false }
        saveProfiles(all, active: id)
        useLists(of: target)
        return true
    }

    /// Removes a profile, never the last one. Deleting the active profile
    /// moves to the first remaining one without saving into the deleted one.
    /// Returns whether the lists in use changed.
    @discardableResult
    public func deleteProfile(_ id: UUID) -> Bool {
        let all = profiles
        guard all.count > 1, all.contains(where: { $0.id == id }) else { return false }
        let remaining = all.filter { $0.id != id }
        guard id == activeProfileID else {
            saveProfiles(remaining, active: activeProfileID)
            return false
        }
        saveProfiles(remaining, active: remaining[0].id)
        useLists(of: remaining[0])
        return true
    }

    /// What a Focus filter should apply when its Focus turns on, with
    /// `requested` set, or off, with it nil, and which profile to come back
    /// to afterwards. A second Focus keeps the profile from before the first.
    public static func focusChange(
        requested: UUID?,
        active: UUID?,
        before: UUID?,
        existing: [UUID]
    ) -> (apply: UUID?, before: UUID?) {
        guard let requested else {
            let back = before.flatMap { existing.contains($0) ? $0 : nil }
            return (back == active ? nil : back, nil)
        }
        guard existing.contains(requested) else { return (nil, before) }
        return (requested == active ? nil : requested, before ?? active)
    }

    private var storedProfiles: [PriorityProfile] {
        defaults.data(forKey: Key.priorityProfiles).flatMap {
            try? JSONDecoder().decode([PriorityProfile].self, from: $0)
        } ?? []
    }

    private func saveProfiles(_ profiles: [PriorityProfile], active: UUID?) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Key.priorityProfiles)
        }
        defaults.set(active?.uuidString, forKey: Key.activePriorityProfile)
    }

    private func currentLists(id: UUID, name: String) -> PriorityProfile {
        PriorityProfile(
            id: id,
            name: name,
            speakers: defaults.stringArray(forKey: Key.speakerPriorities) ?? [],
            headphones: defaults.stringArray(forKey: Key.headphonePriorities) ?? [],
            microphones: defaults.stringArray(forKey: Key.inputPriorities) ?? [],
            microphonesWithHeadphones: defaults.stringArray(
                forKey: Key.headphoneMicrophonePriorities
            ),
            isManual: isManualMode
        )
    }

    private func useLists(of profile: PriorityProfile) {
        defaults.set(profile.speakers, forKey: Key.speakerPriorities)
        defaults.set(profile.headphones, forKey: Key.headphonePriorities)
        defaults.set(profile.microphones, forKey: Key.inputPriorities)
        // A profile made before the headphone order existed starts from its
        // own microphone order, as turning the setting on does.
        defaults.set(
            profile.microphonesWithHeadphones ?? profile.microphones,
            forKey: Key.headphoneMicrophonePriorities
        )
        isManualMode = profile.isManual
    }

    /// Forgetting a device removes it from every profile, not only the lists in
    /// use. Profiles never drop a device on their own.
    private func removeFromProfiles(_ uid: String, role: DeviceRole) {
        let stored = storedProfiles
        guard !stored.isEmpty else { return }
        let stripped = stored.map { profile in
            var profile = profile
            if role == .input {
                profile.microphones.removeAll { $0 == uid }
                profile.microphonesWithHeadphones?.removeAll { $0 == uid }
            } else {
                profile.speakers.removeAll { $0 == uid }
                profile.headphones.removeAll { $0 == uid }
            }
            return profile
        }
        saveProfiles(stripped, active: activeProfileID)
    }

    /// `name` trimmed, or "Profile" when empty, with a number added when
    /// another profile already uses it.
    static func uniqueName(_ name: String, among others: [PriorityProfile]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Profile" : trimmed
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
