import AudioPriorityCore
import SwiftUI

extension AppModel {
    func setManualMode(_ enabled: Bool) {
        isManualMode = enabled
        store.isManualMode = enabled
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

    func setHideNewDisplayOutputs(_ enabled: Bool) {
        hideNewDisplayOutputs = enabled
        store.hideNewDisplayOutputs = enabled
    }

    func selectManually(_ device: AudioDevice) {
        setManualMode(true)
        select(device)
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
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        preservingVisibility(movingTo: category, device)
        refreshDevices()
        if !isManualMode { applyHighestPriorityOutput() }
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
        store.savePriorities(inputDevices, role: .input)
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
}
