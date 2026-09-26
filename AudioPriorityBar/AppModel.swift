import AudioPriorityCore
import AppKit
import Foundation
import Observation

@MainActor
struct AudioOperations {
    let devices: () -> [AudioDevice]
    let defaultDevice: (DeviceRole) -> UInt32?
    let setDefault: (DeviceRole, UInt32) -> Bool
    let outputVolume: () -> Float?
    let setOutputVolume: (Float) -> Bool
    let isMuted: (DeviceRole, UInt32) -> Bool
    let setMute: (DeviceRole, UInt32, Bool) -> Bool
    let inputVolume: (UInt32) -> Float?
    let setInputVolume: (UInt32, Float) -> Bool
    let isRunning: (UInt32) -> Bool
}

@MainActor
struct LinkOperations {
    let isUsable: (AudioDevice) -> Bool
    let state: (AudioDevice) -> LinkState?
}

enum OutputSkipReason: Equatable {
    case off
    case neverAutoSelect
}

struct SkippedOutput: Equatable {
    let device: AudioDevice
    let reason: OutputSkipReason
}

struct AutomaticOutputDecision {
    let target: AudioDevice?
    let skipped: SkippedOutput?
    /// A candidate is still being checked, so no choice should be applied yet.
    var isDeferred = false
}

@MainActor
@Observable
final class AppModel {
    var inputDevices: [AudioDevice] = []
    var speakerDevices: [AudioDevice] = []
    var headphoneDevices: [AudioDevice] = []
    var hiddenSpeakerDevices: [AudioDevice] = []
    var hiddenHeadphoneDevices: [AudioDevice] = []
    var currentInputID: UInt32?
    var currentOutputID: UInt32?
    var volume: Float = 0
    var isVolumeControllable = true
    /// The current microphone's input level. While it is muted by zeroing,
    /// this is the level unmuting will restore rather than zero.
    var microphoneLevel: Float = 0
    var isMicrophoneLevelControllable = false
    var showAll = false
    var isManualMode: Bool
    var selectsPairedDevice: Bool
    var hideNewDisplayOutputs: Bool
    var isActiveOutputMuted = false
    var isActiveInputMuted = false
    var micFlashState = false
    /// The microphone mute the user asked for, carried to whichever microphone
    /// is current.
    var isMicrophoneMuted = false
    /// Some app is recording from the current microphone.
    var isInputRecording = false
    var showsSwitchNotice: Bool
    var remindsWhenMuted: Bool
    /// Called with the devices Automatic mode just switched to because the
    /// hardware changed, output first. Never for the user's own choices.
    var onAutomaticSwitch: (([AudioDevice]) -> Void)?

    let store: PriorityStore
    let audio: AudioOperations
    let link: LinkOperations
    private let reduceMotion: () -> Bool
    private var mutedRoles: Set<String> = []
    /// The microphone currently carrying `isMicrophoneMuted`, by UID.
    private var mutedInputUID: String?
    private var connectedInputUIDs: Set<String> = []
    private var connectedOutputUIDs: Set<String> = []
    private var connectedUIDsByID: [DeviceRole: [UInt32: String]] = [:]
    private var recentlyAddedUIDs: [DeviceRole: Set<String>] = [:]
    private var topologyChangedAt: [DeviceRole: TimeInterval] = [:]
    private var micFlashTimer: Timer?
    private var muteVolumeRefreshTask: Task<Void, Never>?
    private var hasStarted = false
    /// Keeps "Output only" intact when CoreAudio echoes our own default change.
    /// Held by UID because platform IDs are recycled across devices.
    var selectedOnlyOutputUID: String?
    /// Bumped on every Jabra link verdict so `linkState(for:)` is part of the
    /// Observation graph. `link.state` itself lives outside `@Observable`, so
    /// without this a row only redraws its badge when something else
    /// (like hover) forces its body to re-run.
    private var linkRevision = 0

    init(
        store: PriorityStore = PriorityStore(),
        audio: AudioOperations,
        link: LinkOperations,
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.store = store
        self.audio = audio
        self.link = link
        self.reduceMotion = reduceMotion
        isManualMode = store.isManualMode
        selectsPairedDevice = store.selectsPairedDevice
        hideNewDisplayOutputs = store.hideNewDisplayOutputs
        showsSwitchNotice = store.showsSwitchNotice
        remindsWhenMuted = store.remindsWhenMuted
    }

    func start() {
        guard !hasStarted else { return }
        refreshDevices()
        refreshVolume()
        if !isManualMode {
            applyHighestPriorityDevices()
        } else {
            refreshMute()
        }
        hasStarted = true
    }

    func stop() {
        muteVolumeRefreshTask?.cancel()
        muteVolumeRefreshTask = nil
        micFlashTimer?.invalidate()
        micFlashTimer = nil
        micFlashState = false
        // The muted indicator leaves with the app, so the mute must too.
        for uid in store.appliedMicrophoneMutes.keys {
            restoreMicrophone(uid)
        }
        mutedInputUID = nil
        isMicrophoneMuted = false
        hasStarted = false
    }

    func handleDevicesChanged() {
        let before = currentUIDs
        let oldInputs = connectedInputUIDs
        let oldOutputs = connectedOutputUIDs
        refreshDevices()
        let additions: [DeviceRole: Set<String>] = [
            .input: connectedInputUIDs.subtracting(oldInputs),
            .output: connectedOutputUIDs.subtracting(oldOutputs),
        ]
        for (role, added) in additions where !added.isEmpty {
            recentlyAddedUIDs[role] = added
            topologyChangedAt[role] = ProcessInfo.processInfo.systemUptime
        }
        guard !isManualMode, hasStarted else {
            refreshMute()
            return
        }
        applyHighestPriorityDevices()
        announceAutomaticSwitches(since: before)
    }

    /// The Jabra monitor reached a new verdict for some dongle. Bumping the
    /// revision first means every view reading `linkState(for:)` invalidates
    /// immediately rather than waiting for an unrelated redraw.
    func handleLinkChanged() {
        linkRevision &+= 1
        handleDevicesChanged()
    }

    func handleDefaultChanged(_ role: DeviceRole) {
        let before = currentUIDs
        let previousID = role == .input ? currentInputID : currentOutputID
        let previousUID = previousID.flatMap { connectedUIDsByID[role]?[$0] }
        let previousUIDs = role == .input
            ? connectedInputUIDs
            : connectedOutputUIDs
        refreshDevices()
        refreshVolume()
        let connectedUIDs = role == .input
            ? connectedInputUIDs
            : connectedOutputUIDs
        let currentID = role == .input ? currentInputID : currentOutputID
        let currentUID = currentID.flatMap { connectedUIDsByID[role]?[$0] }
        guard hasStarted else {
            refreshMute()
            return
        }
        if isManualMode {
            if role == .output {
                let output = currentOutputDevice
                if output?.uid != selectedOnlyOutputUID {
                    selectedOnlyOutputUID = nil
                    if let output { selectPairedDevice(of: output) }
                }
            }
            refreshMute()
            return
        }
        // CoreAudio does not report whether a default changed because of the
        // user or topology; disappearing and newly-current devices identify topology.
        let topologyExplainsChange =
            previousUID.map { !connectedUIDs.contains($0) } == true
            || currentUID.map { !previousUIDs.contains($0) } == true
            || currentUID.map {
                recentlyAddedUIDs[role]?.contains($0) == true
                    && ProcessInfo.processInfo.systemUptime
                        - (topologyChangedAt[role] ?? 0) < 2
            } == true
        if topologyExplainsChange {
            applyHighestPriorityDevices()
            announceAutomaticSwitches(since: before)
            return
        }
        if let target = automaticTarget(for: role),
           target.platformID != currentID {
            setManualMode(true)
        }
        if role == .output, let output = currentOutputDevice {
            selectPairedDevice(of: output, automatically: !isManualMode)
        }
        refreshMute()
    }

    func handleMuteOrVolumeChanged() {
        guard muteVolumeRefreshTask == nil else { return }
        muteVolumeRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            muteVolumeRefreshTask = nil
            refreshMute()
            refreshVolume()
        }
    }

    func refreshDevices() {
        let connected = audio.devices()
        connectedInputUIDs = Set(
            connected.lazy.filter { $0.role == .input }.map(\.uid)
        )
        connectedOutputUIDs = Set(
            connected.lazy.filter { $0.role == .output }.map(\.uid)
        )
        connectedUIDsByID = Dictionary(grouping: connected, by: \.role)
            .mapValues {
                Dictionary($0.map {
                    ($0.platformID, $0.uid)
                }, uniquingKeysWith: { first, _ in first })
            }
        store.remember(connected)
        // Read before the lists are split, because splitting keeps whatever is
        // playing visible even when it is hidden.
        currentInputID = audio.defaultDevice(.input)
        currentOutputID = audio.defaultDevice(.output)

        var inputs = connected.filter { $0.role == .input }
        var outputs = connected.filter { $0.role == .output }
        if showAll {
            for stored in store.knownDevices {
                let connectedUIDs = stored.role == .input
                    ? connectedInputUIDs
                    : connectedOutputUIDs
                guard !connectedUIDs.contains(stored.uid) else { continue }
                if stored.role == .input {
                    inputs.append(stored.disconnectedDevice())
                } else {
                    outputs.append(stored.disconnectedDevice())
                }
            }
        }
        // Hiding the active microphone would leave no way to see which one is
        // in use, so it stays listed and shows as hidden, matching outputs.
        inputDevices = store.sorted(
            inputs.filter {
                showAll
                    || !store.isHidden($0)
                    || ($0.isConnected && $0.platformID == currentInputID)
            },
            role: .input
        )
        (speakerDevices, hiddenSpeakerDevices) = split(outputs, .speaker)
        (headphoneDevices, hiddenHeadphoneDevices) = split(outputs, .headphone)
    }

    /// Splits one output category into the list the panel shows and the list it
    /// hides. `showAll` collapses the two by leaving the hidden list empty.
    private func split(
        _ outputs: [AudioDevice],
        _ category: OutputCategory
    ) -> (visible: [AudioDevice], hidden: [AudioDevice]) {
        let members = outputs.filter { store.category(for: $0) == category }
        // Hiding whatever is currently playing would leave no way to see where
        // the sound is going, so it stays listed and shows as hidden.
        func isVisible(_ device: AudioDevice) -> Bool {
            showAll
                || !store.isHidden(device, in: category)
                || (device.isConnected && device.platformID == currentOutputID)
        }
        return (
            store.sorted(members.filter(isVisible), category: category),
            members.filter { !isVisible($0) }
        )
    }

    func refreshVolume() {
        if let current = audio.outputVolume() {
            volume = current
            isVolumeControllable = true
        } else {
            volume = 0
            isVolumeControllable = false
        }
        if let id = currentInputID, let level = audio.inputVolume(id) {
            let uid = connectedUIDsByID[.input]?[id]
            let saved = uid.flatMap { store.appliedMicrophoneMutes[$0] }
                .flatMap { $0 == PriorityStore.mutedByProperty ? nil : Float($0) }
            microphoneLevel = saved ?? level
            isMicrophoneLevelControllable = true
        } else {
            microphoneLevel = 0
            isMicrophoneLevelControllable = false
        }
    }

    func refreshMute() {
        reconcileMicrophoneMute()
        let connected = inputDevices + speakerDevices + headphoneDevices
        mutedRoles = Set(connected.lazy.filter {
            $0.isConnected && self.isHardwareMuted($0)
        }.map(\.roleIdentifier))
        isActiveOutputMuted = currentOutputID.map {
            self.audio.isMuted(.output, $0)
        } ?? false
        // The current microphone is always listed, even when hidden.
        isActiveInputMuted = currentInputDevice.map {
            mutedRoles.contains($0.roleIdentifier)
        } ?? false
        isInputRecording = currentInputID.map(audio.isRunning) ?? false
        updateMicFlash()
    }

    /// Keeps the microphone mute on whichever microphone is current, and
    /// follows mutes and unmutes made outside the app, like System Settings
    /// or a headset's mute button.
    private func reconcileMicrophoneMute() {
        let current = currentInputDevice
        if let current {
            let muted = isHardwareMuted(current)
            if current.uid == mutedInputUID, !muted {
                isMicrophoneMuted = false
                mutedInputUID = nil
                store.appliedMicrophoneMutes[current.uid] = nil
            } else if mutedInputUID == nil, muted, !isMicrophoneMuted,
                      store.appliedMicrophoneMutes[current.uid] == nil {
                isMicrophoneMuted = true
                mutedInputUID = current.uid
            }
        }
        if isMicrophoneMuted, let current, current.uid != mutedInputUID {
            if let previous = mutedInputUID { restoreMicrophone(previous) }
            mutedInputUID = applyMicrophoneMute(current) ? current.uid : nil
            isMicrophoneMuted = mutedInputUID != nil
        } else if !isMicrophoneMuted, let previous = mutedInputUID {
            restoreMicrophone(previous)
            mutedInputUID = nil
        }
        // Anything else still recorded was muted before a crash, or while it
        // was unplugged, and must not come back silently dead.
        for uid in store.appliedMicrophoneMutes.keys where uid != mutedInputUID {
            restoreMicrophone(uid)
        }
    }

    /// Mutes through the device's mute property, or by zeroing its input
    /// volume when it has none. Recorded before touching the hardware, so a
    /// crash in between still leaves something to restore.
    private func applyMicrophoneMute(_ device: AudioDevice) -> Bool {
        let id = device.platformID
        store.appliedMicrophoneMutes[device.uid] = PriorityStore.mutedByProperty
        if audio.setMute(.input, id, true) { return true }
        if let level = audio.inputVolume(id) {
            store.appliedMicrophoneMutes[device.uid] = Double(level)
            if audio.setInputVolume(id, 0) { return true }
        }
        store.appliedMicrophoneMutes[device.uid] = nil
        return false
    }

    /// Undoes a mute the same way it was applied. A disconnected microphone
    /// stays recorded and is restored once it reconnects.
    private func restoreMicrophone(_ uid: String) {
        let level = store.appliedMicrophoneMutes[uid]
        guard let id = connectedUIDsByID[.input]?.first(where: {
            $0.value == uid
        })?.key else {
            if level == nil {
                store.appliedMicrophoneMutes[uid] = PriorityStore.mutedByProperty
            }
            return
        }
        if let level, level != PriorityStore.mutedByProperty {
            _ = audio.setInputVolume(id, Float(level))
        } else {
            _ = audio.setMute(.input, id, false)
        }
        store.appliedMicrophoneMutes[uid] = nil
    }

    /// A zeroed input only counts as muted when this app zeroed it: some
    /// virtual microphones, like ZoomAudioDevice, rest at zero volume.
    private func isHardwareMuted(_ device: AudioDevice) -> Bool {
        if audio.isMuted(device.role, device.platformID) { return true }
        guard device.role == .input,
              let level = store.appliedMicrophoneMutes[device.uid],
              level != PriorityStore.mutedByProperty else {
            return false
        }
        return (audio.inputVolume(device.platformID) ?? 1) < 0.01
    }

    var currentInputDevice: AudioDevice? {
        inputDevices.first { $0.isConnected && $0.platformID == currentInputID }
    }

    private var currentUIDs: [DeviceRole: String] {
        var uids: [DeviceRole: String] = [:]
        uids[.input] = currentInputID.flatMap { connectedUIDsByID[.input]?[$0] }
        uids[.output] = currentOutputID.flatMap { connectedUIDsByID[.output]?[$0] }
        return uids
    }

    /// Our own selection updates the current IDs immediately, so CoreAudio's
    /// echo of it finds nothing new and cannot announce the same switch twice.
    private func announceAutomaticSwitches(since before: [DeviceRole: String]) {
        guard hasStarted, !isManualMode, let onAutomaticSwitch else { return }
        let after = currentUIDs
        var switched: [AudioDevice] = []
        if after[.output] != before[.output], let output = currentOutputDevice {
            switched.append(output)
        }
        if after[.input] != before[.input], let input = currentInputDevice {
            switched.append(input)
        }
        if !switched.isEmpty { onAutomaticSwitch(switched) }
    }

    func isMuted(_ device: AudioDevice) -> Bool {
        mutedRoles.contains(device.roleIdentifier)
    }

    func linkState(for device: AudioDevice) -> LinkState? {
        _ = linkRevision
        return device.isConnected ? link.state(device) : nil
    }

    var activeOutputCategory: OutputCategory? {
        guard let currentOutputID,
              let output = allOutputs.first(where: {
                  $0.platformID == currentOutputID
              }) else { return nil }
        return store.category(for: output)
    }

    var currentOutputDevice: AudioDevice? {
        guard let currentOutputID else { return nil }
        return allOutputs.first { $0.platformID == currentOutputID }
    }

    /// Audio is routed to a device we know cannot play it. Automatic switching
    /// moves away on its own, so this only persists in manual mode or when
    /// there is nothing better to fall back to.
    var isActiveOutputLinkDown: Bool {
        guard let output = currentOutputDevice else { return false }
        return linkState(for: output) == .down
    }

    var automaticOutputDecision: AutomaticOutputDecision {
        guard !isManualMode else {
            return AutomaticOutputDecision(target: nil, skipped: nil)
        }
        var skipped: SkippedOutput?
        for device in headphoneDevices + speakerDevices {
            let category = store.category(for: device)
            guard device.isConnected,
                  !store.isHidden(device, in: category) else { continue }
            if store.isNeverUse(device) {
                skipped = skipped ?? SkippedOutput(
                    device: device,
                    reason: .neverAutoSelect
                )
                continue
            }
            // Waiting a moment beats routing audio to this device and then
            // immediately moving away from it once the answer arrives.
            if linkState(for: device) == .checking {
                return AutomaticOutputDecision(
                    target: nil,
                    skipped: skipped,
                    isDeferred: true
                )
            }
            if !link.isUsable(device) {
                skipped = skipped ?? SkippedOutput(
                    device: device,
                    reason: .off
                )
                continue
            }
            return AutomaticOutputDecision(target: device, skipped: skipped)
        }
        return AutomaticOutputDecision(target: nil, skipped: skipped)
    }

    private var allOutputs: [AudioDevice] {
        speakerDevices + headphoneDevices
            + hiddenSpeakerDevices + hiddenHeadphoneDevices
    }

    func applyHighestPriorityDevices() {
        applyHighestPriority(.output)
        applyHighestPriority(.input)
        refreshMute()
    }

    func applyHighestPriorityInput() {
        applyHighestPriority(.input)
        refreshMute()
    }

    func applyHighestPriorityOutput() {
        applyHighestPriority(.output)
        refreshMute()
    }

    private func applyHighestPriority(_ role: DeviceRole) {
        // Deferral covers both roles: picking a microphone now could pair it
        // with an output we are about to change.
        guard !automaticOutputDecision.isDeferred else { return }
        if let first = automaticTarget(for: role) {
            select(first, automatically: true)
        }
    }

    private func automaticTarget(for role: DeviceRole) -> AudioDevice? {
        if role == .input {
            if let output = currentOutputDevice,
               automaticOutputDecision.target?.id == output.id,
               selectsPairedDevice,
               let paired = pairedDevice(for: output),
               !store.isNeverUse(paired),
               link.isUsable(paired) {
                return paired
            }
            return store.firstSelectable(
                in: inputDevices,
                isUsable: link.isUsable
            )
        }
        return automaticOutputDecision.target
    }

    @discardableResult
    func select(
        _ device: AudioDevice,
        automatically: Bool = false,
        includesPairedDevice: Bool = true
    ) -> Bool {
        let currentID = device.role == .input ? currentInputID : currentOutputID
        if currentID != device.platformID {
            guard audio.setDefault(device.role, device.platformID) else {
                return false
            }
            if device.role == .input {
                currentInputID = device.platformID
            } else {
                currentOutputID = device.platformID
            }
        }
        if includesPairedDevice {
            selectPairedDevice(of: device, automatically: automatically)
        }
        return true
    }

    /// Selects the paired counterpart of `device`, when `selectsPairedDevice`
    /// covers both. Reaching from a microphone to its output only happens on
    /// a direct pick (`automatically == false`): automatic mode already
    /// anchors microphone selection to the current output above, so letting
    /// a priority-ranked microphone reach back here would fight that
    /// output's own decision. The already-current guard below is what stops
    /// an output-to-mic-to-output cycle.
    func selectPairedDevice(of device: AudioDevice, automatically: Bool = false) {
        selectedOnlyOutputUID = nil
        guard selectsPairedDevice, let partner = pairedDevice(for: device) else { return }
        guard device.role == .output || !automatically else { return }
        let partnerCurrentID = partner.role == .input ? currentInputID : currentOutputID
        guard partner.platformID != partnerCurrentID else { return }
        guard !automatically
            || (!store.isNeverUse(partner) && link.isUsable(partner)) else { return }
        select(partner)
    }

    /// The connected counterpart of `device` that shares its physical
    /// identity (`AudioDevice.pairingKey`), if any: the input half for an
    /// output, or the output half for an input. Not gated by
    /// `selectsPairedDevice`, that setting only governs the automatic
    /// selection in `selectPairedDevice` above; the explicit
    /// `selectWithPairedDevice`/`selectOnly` actions use this directly.
    func pairedDevice(for device: AudioDevice) -> AudioDevice? {
        guard !device.isVirtual else { return nil }
        let candidates = device.role == .output
            ? inputDevices
            : speakerDevices + headphoneDevices
        return candidates.first {
            $0.pairingKey == device.pairingKey
                && $0.isConnected
                && !$0.isVirtual
                && !store.isHidden($0)
        }
    }

    private func updateMicFlash() {
        if isActiveInputMuted, reduceMotion() {
            micFlashTimer?.invalidate()
            micFlashTimer = nil
            micFlashState = true
        } else if isActiveInputMuted, micFlashTimer == nil {
            micFlashTimer = Timer.scheduledTimer(
                withTimeInterval: 0.7,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.micFlashState.toggle()
                }
            }
        } else if !isActiveInputMuted {
            micFlashTimer?.invalidate()
            micFlashTimer = nil
            micFlashState = false
        }
    }
}
