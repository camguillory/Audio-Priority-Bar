import AudioPriorityCore
import IOBluetooth
import SwiftUI

extension AppModel {
    func setManualMode(_ enabled: Bool) {
        DebugLog.shared.write("automatic switching \(enabled ? "off" : "on")")
        isManualMode = enabled
        store.isManualMode = enabled
        keptPicks = [:]
        switchedBackAt = [:]
        takeoverUIDs = [:]
        if !enabled {
            applyHighestPriorityDevices()
        }
    }

    func setSelectsPairedDevice(_ enabled: Bool) {
        DebugLog.shared.write("setting selectsPairedDevice = \(enabled)")
        selectsPairedDevice = enabled
        store.selectsPairedDevice = enabled
        if enabled, let output = currentOutputDevice {
            selectPairedDevice(of: output, automatically: !isManualMode)
        } else if !isManualMode {
            applyHighestPriorityInput()
        }
    }

    func setMicrophonesFollowOutput(_ enabled: Bool) {
        DebugLog.shared.write("setting microphonesFollowOutput = \(enabled)")
        microphonesFollowOutput = enabled
        store.microphonesFollowOutput = enabled
        viewedMicrophoneCategory = nil
        refreshDevices()
        if !isManualMode { applyHighestPriorityInput() }
    }

    /// Shows the other category's microphone order, or the one in use again.
    func viewMicrophoneOrder(for category: OutputCategory) {
        DebugLog.shared.write("viewing the microphone order with \(category.rawValue)")
        viewedMicrophoneCategory = category == (activeOutputCategory ?? .speaker)
            ? nil
            : category
        refreshDevices()
    }

    func showMicrophoneOrderInUse() {
        guard viewedMicrophoneCategory != nil else { return }
        viewedMicrophoneCategory = nil
        refreshDevices()
    }

    func setHideNewDisplayOutputs(_ enabled: Bool) {
        DebugLog.shared.write("setting hideNewDisplayOutputs = \(enabled)")
        hideNewDisplayOutputs = enabled
        store.hideNewDisplayOutputs = enabled
    }

    func setShowsSwitchNotice(_ enabled: Bool) {
        DebugLog.shared.write("setting showsSwitchNotice = \(enabled)")
        showsSwitchNotice = enabled
        store.showsSwitchNotice = enabled
    }

    func setRemindsWhenMuted(_ enabled: Bool) {
        DebugLog.shared.write("setting remindsWhenMuted = \(enabled)")
        remindsWhenMuted = enabled
        store.remindsWhenMuted = enabled
    }

    func setMutesSpeakersWhenHeadphonesDisconnect(_ enabled: Bool) {
        DebugLog.shared.write("setting mutesSpeakersWhenHeadphonesDisconnect = \(enabled)")
        mutesSpeakersWhenHeadphonesDisconnect = enabled
        store.mutesSpeakersWhenHeadphonesDisconnect = enabled
    }

    func setLightsBusylightWhileRecording(_ enabled: Bool) {
        DebugLog.shared.write("setting lightsBusylightWhileRecording = \(enabled)")
        lightsBusylightWhileRecording = enabled
        store.lightsBusylightWhileRecording = enabled
        updateAutomaticBusylights()
    }

    func setOutlinesMenuBarIcon(_ enabled: Bool) {
        DebugLog.shared.write("setting outlinesMenuBarIcon = \(enabled)")
        outlinesMenuBarIcon = enabled
        store.outlinesMenuBarIcon = enabled
    }

    func setMenuBarDevices(_ devices: MenuBarDevices) {
        DebugLog.shared.write("setting menuBarDevices = \(devices.rawValue)")
        menuBarDevices = devices
        store.menuBarDevices = devices
    }

    func setShowsMenuBarVolume(_ enabled: Bool) {
        DebugLog.shared.write("setting showsMenuBarVolume = \(enabled)")
        showsMenuBarVolume = enabled
        store.showsMenuBarVolume = enabled
    }

    func setPulsesMutedMicrophone(_ enabled: Bool) {
        DebugLog.shared.write("setting pulsesMutedMicrophone = \(enabled)")
        pulsesMutedMicrophone = enabled
        store.pulsesMutedMicrophone = enabled
        refreshMute()
    }

    func setRedIconWhenManual(_ enabled: Bool) {
        DebugLog.shared.write("setting redIconWhenManual = \(enabled)")
        redIconWhenManual = enabled
        store.redIconWhenManual = enabled
    }

    func setKeepsDebugLog(_ enabled: Bool) {
        if !enabled { DebugLog.shared.write("debug log turned off") }
        keepsDebugLog = enabled
        store.keepsDebugLog = enabled
        DebugLog.shared.isEnabled = enabled
        if enabled { logSnapshot() }
    }

    /// Deletes the saved days. A log left on starts over with a snapshot.
    func clearDebugLog() {
        DebugLog.shared.clear()
        DebugLog.shared.write("debug log cleared")
        logSnapshot()
    }

    /// The versions, settings and lists a reader needs to make sense of the
    /// lines that follow.
    func logSnapshot() {
        let log = DebugLog.shared
        guard log.isEnabled else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        log.write("\(appDisplayName) \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)")
        log.write("permissions: \(Permissions.summary())")
        log.write("settings: automatic \(!isManualMode), selectsPairedDevice \(selectsPairedDevice), microphonesFollowOutput \(microphonesFollowOutput), hideNewDisplayOutputs \(hideNewDisplayOutputs), mutesSpeakersWhenHeadphonesDisconnect \(mutesSpeakersWhenHeadphonesDisconnect), lightsBusylightWhileRecording \(lightsBusylightWhileRecording), showsSwitchNotice \(showsSwitchNotice), remindsWhenMuted \(remindsWhenMuted)")
        log.write("profile: \(profiles.first { $0.id == activeProfileID }?.name ?? "none"), \(profiles.count) in all")
        log.write("speakers: \(logList(speakerDevices + hiddenSpeakerDevices))")
        log.write("headphones: \(logList(headphoneDevices + hiddenHeadphoneDevices))")
        if microphonesFollowOutput {
            for category in OutputCategory.allCases {
                log.write("microphones with \(category.rawValue): \(logList(store.sorted(inputDevices, microphonesFor: category)))")
            }
        } else {
            log.write("microphones: \(logList(inputDevices))")
        }
        log.write("current: output \(currentOutputDevice?.logName ?? "none"), microphone \(currentInputDevice?.logName ?? "none")")
        if !keptPicks.isEmpty { log.write("kept picks: \(keptPicks)") }
    }

    /// Devices in order, each with what decides whether it can be chosen.
    private func logList(_ devices: [AudioDevice]) -> String {
        devices.isEmpty ? "none" : devices.map(logEntry).joined(separator: "; ")
    }

    func logEntry(_ device: AudioDevice) -> String {
        var flags = [device.transportCode]
        if device.role == .output { flags.append(store.category(for: device).rawValue) }
        if let declared = device.declaredCategory { flags.append("declares \(declared.rawValue)") }
        if !device.isConnected { flags.append("not connected") }
        if device.isVirtual { flags.append("virtual") }
        if device.isDisplayOutput { flags.append("display") }
        if store.isHidden(device) { flags.append("hidden") }
        if store.isNeverUse(device) { flags.append("never automatic") }
        if let state = linkState(for: device) { flags.append("link \(state)") }
        return "\(device.logName) (\(flags.joined(separator: ", ")))"
    }

    func canConnect(_ device: AudioDevice) -> Bool {
        !device.isConnected && battery.report.bluetoothDevice(for: device) != nil
    }

    func isConnecting(_ device: AudioDevice) -> Bool {
        battery.report.bluetoothDevice(for: device)
            .map { connectingBluetoothAttempts[$0.address] != nil } ?? false
    }

    /// A connected device's Bluetooth address, from its UID or, for a UID in
    /// another shape, from the paired device of the same name.
    func bluetoothAddress(of device: AudioDevice) -> String? {
        BluetoothBattery.address(of: device)
            ?? (device.isBluetooth ? battery.report.bluetoothDevice(for: device)?.address : nil)
    }

    /// Whether this device, or the other half of the same hardware, is the
    /// current output or microphone.
    func isInUse(_ device: AudioDevice) -> Bool {
        [currentOutputDevice, currentInputDevice].contains { $0?.isSameDevice(as: device) == true }
    }

    /// Opens the Bluetooth link and leaves the rest to CoreAudio, which adds
    /// the device a few seconds later. With `selecting`, the device is then
    /// selected as a click on a connected row would; otherwise automatic
    /// switching decides. The first attempt asks for Bluetooth permission.
    func connect(_ device: AudioDevice, selecting: Bool = false) {
        guard let address = battery.report.bluetoothDevice(for: device)?.address else { return }
        if selecting { selectingBluetoothAddress = address }
        guard connectingBluetoothAttempts[address] == nil else { return }
        let attempt = UUID()
        connectingBluetoothAttempts[address] = attempt
        DebugLog.shared.write("connecting \(device.logName) over Bluetooth\(selecting ? ", to select it" : "")")
        Task {
            if await bluetooth(address, { $0.openConnection() }) {
                // Covers the gap before CoreAudio adds the device, which
                // ends the spinner sooner through refreshDevices.
                try? await Task.sleep(for: .seconds(10))
            } else {
                DebugLog.shared.write("could not connect \(device.logName) over Bluetooth")
                NSSound.beep()
            }
            if connectingBluetoothAttempts[address] == attempt {
                connectingBluetoothAttempts[address] = nil
                // A device that fails or never shows up is not selected later,
                // out of the blue.
                if selectingBluetoothAddress == address { selectingBluetoothAddress = nil }
            }
        }
    }

    func canDisconnect(_ device: AudioDevice) -> Bool {
        device.isConnected && device.isBluetooth && bluetoothAddress(of: device) != nil
    }

    /// CoreAudio then removes the device, and automatic switching moves on as
    /// it would for headphones switched off.
    func disconnect(_ device: AudioDevice) {
        guard let address = bluetoothAddress(of: device) else { return }
        DebugLog.shared.write("disconnecting \(device.logName) over Bluetooth")
        Task {
            if await !bluetooth(address, { $0.closeConnection() }) {
                DebugLog.shared.write("could not disconnect \(device.logName) over Bluetooth")
                NSSound.beep()
            }
        }
    }

    /// IOBluetooth calls block for seconds, so they run on a dispatch queue
    /// rather than tie up a Swift concurrency thread.
    private func bluetooth(
        _ address: String,
        _ call: @escaping @Sendable (IOBluetoothDevice) -> IOReturn
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = IOBluetoothDevice(addressString: address).map(call)
                continuation.resume(returning: result == kIOReturnSuccess)
            }
        }
    }
    func setMicrophoneMuted(_ muted: Bool) {
        DebugLog.shared.write("microphone \(muted ? "mute" : "unmute") asked for")
        isMicrophoneMuted = muted
        refreshMute()
        refreshVolume()
    }

    func perform(_ command: URLCommand) {
        DebugLog.shared.write("command \(command.rawValue)")
        switch command {
        case .toggleMicMute: setMicrophoneMuted(!isMicrophoneMuted)
        case .muteMic: setMicrophoneMuted(true)
        case .unmuteMic: setMicrophoneMuted(false)
        case .toggleAutomatic: setManualMode(!isManualMode)
        case .enableAutomatic: setManualMode(false)
        case .disableAutomatic: setManualMode(true)
        }
    }

    /// Moving the level while muted unmutes, as the macOS volume keys do.
    func setMicrophoneLevel(_ value: Float) {
        guard let id = currentInputID else { return }
        if isMicrophoneMuted { setMicrophoneMuted(false) }
        guard audio.setInputVolume(id, value) else { return }
        microphoneLevel = value
        logSettledLevel(.input, value)
    }

    /// Logs a level once it has held for half a second.
    func logSettledLevel(_ role: DeviceRole, _ value: Float, outside: Bool = false) {
        guard DebugLog.shared.isEnabled else { return }
        levelLogTasks[role]?.cancel()
        levelLogTasks[role] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            levelLogTasks[role] = nil
            DebugLog.shared.write("\(role == .input ? "microphone" : "output") level \(outside ? "changed outside the app to" : "set to") \(Int((value * 100).rounded()))%")
        }
    }

    func setOutputMuted(_ muted: Bool) {
        DebugLog.shared.write("clicked output \(muted ? "mute" : "unmute")")
        guard let id = currentOutputID, audio.setMute(.output, id, muted) else {
            DebugLog.shared.write("could not \(muted ? "mute" : "unmute") the output")
            return
        }
        refreshMute()
    }

    /// With automatic switching on, a pick stays as one in Control Center
    /// does, until it leaves or the list would use a device that connects
    /// later. Every role the pick moved is kept, or automatic switching would
    /// move a paired half back.
    func selectManually(_ device: AudioDevice) {
        DebugLog.shared.write("picked \(device.logName)")
        switchedBackAt = [:]
        takeoverUIDs = [:]
        let before = currentUIDs
        guard select(device) else { return }
        keepPicks(DeviceRole.allCases.filter { $0 == device.role || before[$0] != currentUIDs[$0] })
    }

    /// Keeps `roles` on their current devices while automatic switching is
    /// on, as a pick in Control Center is kept.
    private func keepPicks(_ roles: [DeviceRole]) {
        guard !isManualMode else { return }
        for role in roles {
            if let uid = currentUIDs[role] { keepPick(uid, for: role) }
        }
    }

    /// What a click on a row does: selects a connected device, or connects a
    /// paired Bluetooth one that is off and selects it once it is there.
    func activate(_ device: AudioDevice) {
        DebugLog.shared.write("clicked the row \(logEntry(device))")
        if device.isConnected {
            let currentID = device.role == .input ? currentInputID : currentOutputID
            if linkState(for: device) != .down, currentID != device.platformID {
                selectManually(device)
            } else {
                DebugLog.shared.write("nothing to do: \(currentID == device.platformID ? "already current" : "its Jabra headset is off")")
            }
        } else if canConnect(device) {
            connect(device, selecting: true)
        } else {
            DebugLog.shared.write("nothing to do: not connected and not a paired Bluetooth device")
        }
    }

    /// What Return or Space does on a highlighted panel item. Settings and
    /// the takeover fix open from the panel, which owns the windows.
    func use(_ item: PanelItem) {
        DebugLog.shared.write("keyboard: used \(item)")
        switch item {
        case .automatic: setManualMode(!isManualMode)
        case .profile: _ = adjust(.profile, up: true)
        case .microphoneOrder:
            viewMicrophoneOrder(for: microphoneOrderCategory == .speaker ? .headphone : .speaker)
        case .outputLevel: if isOutputMutable { setOutputMuted(!isActiveOutputMuted) }
        case .microphoneLevel: if isMicrophoneMutable { setMicrophoneMuted(!isMicrophoneMuted) }
        case .showAll:
            showAll.toggle()
            refreshDevices()
        case .device(let id):
            if let device = listedDevices.first(where: { $0.id == id }) { activate(device) }
        case .settings, .takeoverFix: break
        }
    }

    /// Left and Right move a highlighted level by a sixteenth, as the volume
    /// keys do, and step through the profiles or microphone orders. Returns
    /// false when the item has nothing to step.
    func adjust(_ item: PanelItem, up: Bool) -> Bool {
        DebugLog.shared.write("keyboard: \(up ? "right" : "left") on \(item)")
        let step: Float = up ? 1 / 16 : -1 / 16
        switch item {
        case .profile:
            guard profiles.count > 1,
                  let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
                return false
            }
            let offset = up ? 1 : profiles.count - 1
            applyProfile(id: profiles[(index + offset) % profiles.count].id)
        case .microphoneOrder where microphonesFollowOutput:
            viewMicrophoneOrder(for: up ? .headphone : .speaker)
        case .outputLevel where isVolumeControllable:
            setVolume(min(1, max(0, volume + step)))
        case .microphoneLevel where isMicrophoneLevelControllable:
            setMicrophoneLevel(min(1, max(0, microphoneLevel + step)))
        default:
            return false
        }
        return true
    }

    /// A Shortcuts action's pick, which acts like a click on the device's row.
    func selectManually(uid: String, role: DeviceRole) throws(ShortcutError) {
        let known = role == .input ? inputDevices : speakerDevices + headphoneDevices
        guard let device = known.first(where: { $0.uid == uid }) else {
            throw .unknownDevice
        }
        guard device.isConnected else { throw .notConnected(device.name) }
        selectManually(device)
    }

    /// Selects a device with its paired counterpart, regardless of
    /// `selectsPairedDevice`. Output goes first so a failed output
    /// selection, like a plain manual selection, never moves the microphone.
    func selectWithPairedDevice(_ device: AudioDevice) {
        guard let pair = pairedDevice(for: device) else { return }
        let output = device.role == .output ? device : pair
        let input = device.role == .input ? device : pair
        DebugLog.shared.write("picked \(device.logName) with its other half")
        switchedBackAt = [:]
        takeoverUIDs = [:]
        guard select(output) else { return }
        select(input)
        keepPicks([.output, .input])
    }

    /// Selects one device only, regardless of `selectsPairedDevice`. An
    /// output keeps the microphone too, or automatic switching would pair
    /// the output's own one back.
    func selectOnly(_ device: AudioDevice) {
        DebugLog.shared.write("picked \(device.logName) only")
        switchedBackAt = [:]
        takeoverUIDs = [:]
        selectedOnlyOutputUID = device.role == .output ? device.uid : nil
        guard select(device, includesPairedDevice: false) else {
            selectedOnlyOutputUID = nil
            return
        }
        keepPicks(device.role == .output ? [.output, .input] : [.input])
    }

    func setVolume(_ value: Float) {
        guard audio.setOutputVolume(value) else { return }
        volume = value
        logSettledLevel(.output, value)
        if isActiveOutputMuted, value > 0 { setOutputMuted(false) }
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        DebugLog.shared.write("\(device.logName) moved to \(category.rawValue)")
        let playing = activeOutputCategory
        preservingVisibility(movingTo: category, device)
        refreshDevices()
        if !isManualMode { applyHighestPriorityOutput() }
        // Moving the device that plays changes its category without a switch.
        followOutputCategory(from: playing)
    }

    /// Moves a device to a category without changing whether it is hidden:
    /// a hidden device stays hidden in its new list, and a visible one stays
    /// visible rather than inheriting a stale hide flag left over from before
    /// hiding became a single, both-categories command.
    private func preservingVisibility(
        movingTo category: OutputCategory,
        _ device: AudioDevice
    ) {
        let wasHidden = store.isHidden(device)
        store.setCategory(category, for: device)
        if wasHidden {
            store.hide(device, in: category)
        } else {
            store.unhide(device, from: category)
        }
    }

    /// Hides a device everywhere: from Microphones, or from both Speakers and
    /// Headphones, so one command has one meaning regardless of which output
    /// list a device currently sits in.
    func hide(_ device: AudioDevice) {
        DebugLog.shared.write("hid \(device.logName)")
        if device.role == .input {
            store.hide(device)
        } else {
            store.hide(device, in: .speaker)
            store.hide(device, in: .headphone)
        }
        refreshDevices()
        reselect(device.role)
    }

    func unhide(_ device: AudioDevice) {
        DebugLog.shared.write("unhid \(device.logName)")
        if device.role == .input {
            store.unhide(device)
        } else {
            store.unhide(device, from: .speaker)
            store.unhide(device, from: .headphone)
        }
        refreshDevices()
    }

    func isHidden(_ device: AudioDevice) -> Bool {
        store.isHidden(device)
    }

    func isNeverUse(_ device: AudioDevice) -> Bool {
        store.isNeverUse(device)
    }

    func setNeverUse(_ device: AudioDevice, _ enabled: Bool) {
        DebugLog.shared.write("\(device.logName) \(enabled ? "is never" : "can be") chosen automatically")
        store.setNeverUse(device, enabled)
        refreshDevices()
        reselect(device.role)
    }

    func forget(_ device: AudioDevice) {
        DebugLog.shared.write("forgot \(device.logName)")
        store.forget(uid: device.uid, role: device.role)
        refreshDevices()
    }

    func moveInput(from source: IndexSet, to destination: Int) {
        guard source.allSatisfy(inputDevices.indices.contains),
              (0...inputDevices.count).contains(destination) else {
            return
        }
        let before = inputDevices.map(\.name)
        inputDevices.move(fromOffsets: source, toOffset: destination)
        // Saved to the order shown, which may not be the one in use: the
        // reapply then finds the same microphone and changes nothing.
        store.savePriorities(inputDevices, microphonesFor: microphoneOrderCategory)
        DebugLog.shared.write("microphone order with \(microphoneOrderCategory.rawValue) changed from \(before) to \(inputDevices.map(\.name))")
        if !isManualMode { applyHighestPriorityInput() }
    }

    func moveOutput(
        in category: OutputCategory,
        from source: IndexSet,
        to destination: Int
    ) {
        let count = category == .speaker
            ? speakerDevices.count
            : headphoneDevices.count
        guard source.allSatisfy((0..<count).contains),
              (0...count).contains(destination) else {
            return
        }
        let before = (category == .speaker ? speakerDevices : headphoneDevices).map(\.name)
        if category == .speaker {
            speakerDevices.move(fromOffsets: source, toOffset: destination)
            store.savePriorities(speakerDevices, category: .speaker)
        } else {
            headphoneDevices.move(fromOffsets: source, toOffset: destination)
            store.savePriorities(headphoneDevices, category: .headphone)
        }
        DebugLog.shared.write("\(category.rawValue) order changed from \(before) to \((category == .speaker ? speakerDevices : headphoneDevices).map(\.name))")
        if !isManualMode { applyHighestPriorityOutput() }
    }

    func dropDevice(
        _ id: String,
        into category: OutputCategory?,
        at destination: Int
    ) -> Bool {
        if category == nil {
            guard let source = inputDevices.firstIndex(where: {
                $0.id == id
            }) else { return false }
            moveInput(
                from: IndexSet(integer: source),
                to: max(0, min(destination, inputDevices.count))
            )
            return true
        }

        guard let category,
              let device = (speakerDevices + headphoneDevices).first(where: {
                  $0.id == id
              }) else { return false }
        let sourceCategory = store.category(for: device)
        if sourceCategory == category {
            let devices = category == .speaker
                ? speakerDevices
                : headphoneDevices
            guard let source = devices.firstIndex(of: device) else { return false }
            moveOutput(
                in: category,
                from: IndexSet(integer: source),
                to: max(0, min(destination, devices.count))
            )
            return true
        }

        let playing = activeOutputCategory
        DebugLog.shared.write("\(device.logName) dragged to \(category.rawValue)")
        preservingVisibility(movingTo: category, device)
        refreshDevices()
        var devices = category == .speaker
            ? speakerDevices
            : headphoneDevices
        guard let source = devices.firstIndex(where: {
            $0.id == id
        }) else { return false }
        let before = devices.map(\.name)
        let moved = devices.remove(at: source)
        devices.insert(moved, at: max(0, min(destination, devices.count)))
        if category == .speaker {
            speakerDevices = devices
        } else {
            headphoneDevices = devices
        }
        store.savePriorities(devices, category: category)
        DebugLog.shared.write("\(category.rawValue) order changed from \(before) to \(devices.map(\.name))")
        if !isManualMode { applyHighestPriorityOutput() }
        followOutputCategory(from: playing)
        return true
    }

    private func reselect(_ role: DeviceRole) {
        guard !isManualMode else { return }
        if role == .input {
            applyHighestPriorityInput()
        } else {
            applyHighestPriorityOutput()
        }
    }

    /// Switches to a profile, or applies the active one again, and selects its
    /// top devices. Returns false for a profile that no longer exists.
    @discardableResult
    func applyProfile(id: UUID, announces: Bool = false) -> Bool {
        guard let profile = store.profiles.first(where: { $0.id == id }) else { return false }
        DebugLog.shared.write("applying the profile \"\(profile.name)\"")
        store.loadProfile(id)
        useLoadedProfile(announces: announces)
        return true
    }

    /// Adds a copy of the profile in use and switches to it, so the panel
    /// edits the new one, and asks Settings to open its name for editing.
    func addProfile(named name: String = "Untitled") {
        DebugLog.shared.write("adding a profile")
        let added = store.addProfile(named: name)
        applyProfile(id: added.id)
        renamingProfileID = added.id
    }

    func renameProfile(_ id: UUID, to name: String) {
        DebugLog.shared.write("renaming a profile to \"\(name)\"")
        store.renameProfile(id, to: name)
        refreshProfiles()
    }

    func deleteProfile(_ id: UUID) {
        DebugLog.shared.write("deleting a profile")
        if store.deleteProfile(id) {
            useLoadedProfile(announces: false)
        } else {
            refreshProfiles()
        }
    }

    /// A Focus filter turning on, with the profile it names, or off, with nil.
    func applyFocusProfile(_ requested: UUID?) {
        let change = PriorityStore.focusChange(
            requested: requested,
            active: store.activeProfileID,
            before: store.profileBeforeFocus,
            existing: store.profiles.map(\.id)
        )
        DebugLog.shared.write("Focus filter \(requested == nil ? "ended" : "asks for a profile")")
        store.profileBeforeFocus = change.before
        if let id = change.apply { applyProfile(id: id, announces: true) }
    }

    func refreshProfiles() {
        profiles = store.profiles
        activeProfileID = store.activeProfileID
    }

    /// Takes up the lists the store just loaded. Picks made under the old
    /// profile no longer apply, and the top devices are selected once even
    /// when the profile keeps automatic switching off.
    private func useLoadedProfile(announces: Bool) {
        let before = currentUIDs
        keptPicks = [:]
        switchedBackAt = [:]
        takeoverUIDs = [:]
        viewedMicrophoneCategory = nil
        refreshProfiles()
        refreshDevices()
        // Automatic mode alone picks from the lists, so it chooses this once
        // before the profile's own setting takes over.
        isManualMode = false
        applyHighestPriorityDevices()
        isManualMode = store.isManualMode
        guard announces,
              let name = profiles.first(where: { $0.id == activeProfileID })?.name else {
            return
        }
        let after = currentUIDs
        var changed: [AudioDevice] = []
        if after[.output] != before[.output], let output = currentOutputDevice {
            changed.append(output)
        }
        if after[.input] != before[.input], let input = currentInputDevice {
            changed.append(input)
        }
        onProfileApplied?(name, changed)
    }
}
