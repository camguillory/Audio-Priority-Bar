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

    func setLinksMicrophone(_ enabled: Bool) {
        linksMicrophone = enabled
        store.linksMicrophone = enabled
        if enabled, let output = currentOutputDevice {
            syncMicrophone(to: output, automatically: !isManualMode)
        } else if !isManualMode {
            applyHighestPriorityInput()
        }
    }

    func selectManually(_ device: AudioDevice) {
        setManualMode(true)
        select(device)
    }

    func setVolume(_ value: Float) {
        guard audio.setOutputVolume(value) else { return }
        volume = value
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        store.setCategory(category, for: device)
        // Without this the device lands in a list that filters it out and
        // vanishes from the panel until Show all is enabled.
        store.unhide(device, from: category)
        refreshDevices()
        if !isManualMode { applyHighestPriorityOutput() }
    }

    func hide(_ device: AudioDevice, category: OutputCategory? = nil) {
        if device.role == .output, let category {
            store.hide(device, in: category)
        } else {
            store.hide(device)
        }
        refreshDevices()
        reselect(device.role)
    }

    func hideEntirely(_ device: AudioDevice) {
        if device.role == .input {
            store.hide(device)
        } else {
            store.hide(device, in: .speaker)
            store.hide(device, in: .headphone)
        }
        refreshDevices()
        reselect(device.role)
    }

    func stopIgnoring(_ device: AudioDevice, category: OutputCategory?) {
        if device.role == .input {
            store.unhide(device)
        } else if let category {
            store.unhide(device, from: category)
        }
        refreshDevices()
    }

    func isIgnored(_ device: AudioDevice, category: OutputCategory? = nil) -> Bool {
        if device.role == .input { return store.isHidden(device) }
        return category.map {
            store.isHidden(device, in: $0)
        } ?? store.isHidden(device)
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

        store.setCategory(category, for: device)
        // Keep the row visible in its destination before applying final order.
        store.unhide(device, from: category)
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
