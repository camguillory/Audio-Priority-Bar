import AudioPriorityCore
import IOBluetooth
import SwiftUI

extension AppModel {
    func setManualMode(_ enabled: Bool) {
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
        selectsPairedDevice = enabled
        store.selectsPairedDevice = enabled
        if enabled, let output = currentOutputDevice {
            selectPairedDevice(of: output, automatically: !isManualMode)
        } else if !isManualMode {
            applyHighestPriorityInput()
        }
    }

    func setMicrophonesFollowOutput(_ enabled: Bool) {
        microphonesFollowOutput = enabled
        store.microphonesFollowOutput = enabled
        viewedMicrophoneCategory = nil
        refreshDevices()
        if !isManualMode { applyHighestPriorityInput() }
    }

    /// Shows the other category's microphone order, or the one in use again.
    func viewMicrophoneOrder(for category: OutputCategory) {
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
        hideNewDisplayOutputs = enabled
        store.hideNewDisplayOutputs = enabled
    }

    func setShowsSwitchNotice(_ enabled: Bool) {
        showsSwitchNotice = enabled
        store.showsSwitchNotice = enabled
    }

    func setRemindsWhenMuted(_ enabled: Bool) {
        remindsWhenMuted = enabled
        store.remindsWhenMuted = enabled
    }

    func setMutesSpeakersWhenHeadphonesDisconnect(_ enabled: Bool) {
        mutesSpeakersWhenHeadphonesDisconnect = enabled
        store.mutesSpeakersWhenHeadphonesDisconnect = enabled
    }

    func setOutlinesMenuBarIcon(_ enabled: Bool) {
        outlinesMenuBarIcon = enabled
        store.outlinesMenuBarIcon = enabled
    }

    func setMenuBarDevices(_ devices: MenuBarDevices) {
        menuBarDevices = devices
        store.menuBarDevices = devices
    }

    func setShowsMenuBarVolume(_ enabled: Bool) {
        showsMenuBarVolume = enabled
        store.showsMenuBarVolume = enabled
    }

    func setPulsesMutedMicrophone(_ enabled: Bool) {
        pulsesMutedMicrophone = enabled
        store.pulsesMutedMicrophone = enabled
        refreshMute()
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
        Task {
            if await bluetooth(address, { $0.openConnection() }) {
                // Covers the gap before CoreAudio adds the device, which
                // ends the spinner sooner through refreshDevices.
                try? await Task.sleep(for: .seconds(10))
            } else {
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
        Task {
            if await !bluetooth(address, { $0.closeConnection() }) { NSSound.beep() }
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
        isMicrophoneMuted = muted
        refreshMute()
        refreshVolume()
    }

    func perform(_ command: URLCommand) {
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
    }

    func setOutputMuted(_ muted: Bool) {
        guard let id = currentOutputID, audio.setMute(.output, id, muted) else {
            return
        }
        refreshMute()
    }

    func selectManually(_ device: AudioDevice) {
        setManualMode(true)
        select(device)
    }

    /// What a click on a row does: selects a connected device, or connects a
    /// paired Bluetooth one that is off and selects it once it is there.
    func activate(_ device: AudioDevice) {
        if device.isConnected {
            let currentID = device.role == .input ? currentInputID : currentOutputID
            if linkState(for: device) != .down, currentID != device.platformID {
                selectManually(device)
            }
        } else if canConnect(device) {
            connect(device, selecting: true)
        }
    }

    /// What Return or Space does on a highlighted panel item. Settings and
    /// the takeover fix open from the panel, which owns the windows.
    func use(_ item: PanelItem) {
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
        setManualMode(true)
        guard select(output) else { return }
        select(input)
    }

    /// Selects one device only, regardless of `selectsPairedDevice`.
    func selectOnly(_ device: AudioDevice) {
        setManualMode(true)
        selectedOnlyOutputUID = device.role == .output ? device.uid : nil
        if !select(device, includesPairedDevice: false) {
            selectedOnlyOutputUID = nil
        }
    }

    func setVolume(_ value: Float) {
        guard audio.setOutputVolume(value) else { return }
        volume = value
        if isActiveOutputMuted, value > 0 { setOutputMuted(false) }
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
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
        store.setNeverUse(device, enabled)
        refreshDevices()
        reselect(device.role)
    }

    func forget(_ device: AudioDevice) {
        store.forget(uid: device.uid, role: device.role)
        refreshDevices()
    }

    func moveInput(from source: IndexSet, to destination: Int) {
        guard source.allSatisfy(inputDevices.indices.contains),
              (0...inputDevices.count).contains(destination) else {
            return
        }
        inputDevices.move(fromOffsets: source, toOffset: destination)
        // Saved to the order shown, which may not be the one in use: the
        // reapply then finds the same microphone and changes nothing.
        store.savePriorities(inputDevices, microphonesFor: microphoneOrderCategory)
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
        if category == .speaker {
            speakerDevices.move(fromOffsets: source, toOffset: destination)
            store.savePriorities(speakerDevices, category: .speaker)
        } else {
            headphoneDevices.move(fromOffsets: source, toOffset: destination)
            store.savePriorities(headphoneDevices, category: .headphone)
        }
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
        preservingVisibility(movingTo: category, device)
        refreshDevices()
        var devices = category == .speaker
            ? speakerDevices
            : headphoneDevices
        guard let source = devices.firstIndex(where: {
            $0.id == id
        }) else { return false }
        let moved = devices.remove(at: source)
        devices.insert(moved, at: max(0, min(destination, devices.count)))
        if category == .speaker {
            speakerDevices = devices
        } else {
            headphoneDevices = devices
        }
        store.savePriorities(devices, category: category)
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
        guard store.profiles.contains(where: { $0.id == id }) else { return false }
        store.loadProfile(id)
        useLoadedProfile(announces: announces)
        return true
    }

    /// Adds a copy of the profile in use and switches to it, so the panel
    /// edits the new one, and asks Settings to open its name for editing.
    func addProfile(named name: String = "Untitled") {
        let added = store.addProfile(named: name)
        applyProfile(id: added.id)
        renamingProfileID = added.id
    }

    func renameProfile(_ id: UUID, to name: String) {
        store.renameProfile(id, to: name)
        refreshProfiles()
    }

    func deleteProfile(_ id: UUID) {
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
