import AudioPriorityCore
import AppKit
import CoreAudio
import Foundation
import Observation

struct InputActivity {
    var recording: Set<UInt32> = []
    var uncertain: Set<UInt32> = []

    func mayBeRecording(_ id: UInt32) -> Bool {
        recording.contains(id) || uncertain.contains(id)
    }
}

@MainActor
struct AudioOperations {
    let devices: () -> [AudioDevice]?
    let defaultDevice: (DeviceRole) -> UInt32?
    let setDefault: (DeviceRole, UInt32) -> Bool
    let outputVolume: () -> Float?
    let setOutputVolume: (Float) -> Bool
    let isMuted: (DeviceRole, UInt32) -> Bool
    let setMute: (DeviceRole, UInt32, Bool) -> Bool
    let canSetMute: (DeviceRole, UInt32) -> Bool
    let inputVolume: (UInt32) -> Float?
    let setInputVolume: (UInt32, Float) -> Bool
    let isRunning: (UInt32) -> Bool
    /// The name of an app recording from the microphone, when macOS says.
    var appRecording: (UInt32) -> String? = { _ in nil }
    var inputActivity: (([UInt32]) -> InputActivity)?
}

@MainActor
struct LinkOperations {
    let isUsable: (AudioDevice) -> Bool
    let state: (AudioDevice) -> LinkState?
    var battery: (AudioDevice) -> Int? = { _ in nil }
    var headsetControls: (AudioDevice) -> JabraGNP.HeadsetControls? = { _ in nil }
    var setNoiseMode: (JabraGNP.NoiseMode, AudioDevice) -> Void = { _, _ in }
    var setSidetone: (Bool, AudioDevice) -> Void = { _, _ in }
    var setBusy: (Bool, AudioDevice) -> Void = { _, _ in }
    var endHeadsetCall: (AudioDevice) -> Void = { _ in }
    var refreshHeadsetControls: () -> Void = {}
}

enum OutputSkipReason: Equatable {
    case off
    case neverAutoSelect

    var label: String {
        switch self {
        case .off: "headset off"
        case .neverAutoSelect: "never auto-selected"
        }
    }
}

struct SkippedOutput: Equatable {
    let device: AudioDevice
    let reason: OutputSkipReason
}

struct UncoveredRecording: Equatable {
    /// Nil when macOS cannot say which app, as before macOS 14.2.
    let app: String?
    let microphone: String
    var isConfirmed = true
}

struct SwitchRecord: Equatable {
    let date: Date
    let role: DeviceRole
    let device: String
    let reason: String

    var description: String {
        "\(date.formatted(date: .omitted, time: .standard))  \(role == .input ? "Microphone" : "Output"): \(device), \(reason)"
    }
}

struct AutomaticOutputDecision {
    let target: AudioDevice?
    let skipped: SkippedOutput?
    /// A candidate is still being checked, so no choice should be applied yet.
    var isDeferred = false
}

/// Something in the panel the arrow keys can highlight.
enum PanelItem: Hashable {
    case automatic, profile, takeoverFix, outputLevel, microphoneLevel
    case microphoneOrder, showAll, settings
    case device(String)
}

@MainActor
@Observable
final class AppModel {
    var inputDevices: [AudioDevice] = []
    var speakerDevices: [AudioDevice] = []
    var headphoneDevices: [AudioDevice] = []
    /// The panel's rows from top to bottom.
    var listedDevices: [AudioDevice] { speakerDevices + headphoneDevices + inputDevices }
    /// What the arrow keys walk through, in the panel's order.
    var panelItems: [PanelItem] {
        var items: [PanelItem] = [.automatic]
        if profiles.count > 1 { items.append(.profile) }
        if takeoverDevice?.isBluetooth == true { items.append(.takeoverFix) }
        items.append(.outputLevel)
        if currentInputID != nil { items.append(.microphoneLevel) }
        items += (speakerDevices + headphoneDevices).map { .device($0.id) }
        if microphonesFollowOutput { items.append(.microphoneOrder) }
        items += inputDevices.map { .device($0.id) }
        return items + [.showAll, .settings]
    }
    var hiddenSpeakerDevices: [AudioDevice] = []
    var hiddenHeadphoneDevices: [AudioDevice] = []
    var currentInputID: UInt32?
    var currentOutputID: UInt32?
    var volume: Float = 0
    var isVolumeControllable = true
    /// The current output has a settable mute property. Some, like TVs and
    /// audio interfaces, have neither a volume nor a mute.
    var isOutputMutable = true
    /// The current microphone's input level. While it is muted by zeroing,
    /// this is the level unmuting will restore rather than zero.
    var microphoneLevel: Float = 0
    var isMicrophoneLevelControllable = false
    /// The current microphone can be muted, by its mute property or by
    /// zeroing its level.
    var isMicrophoneMutable = false
    var showAll = false
    var isManualMode: Bool
    var selectsPairedDevice: Bool
    var microphonesFollowOutput: Bool
    /// The microphone order the panel shows when the user picks the one not in
    /// use. Nil shows the order for the output playing.
    var viewedMicrophoneCategory: OutputCategory?
    var profiles: [PriorityProfile] = []
    var activeProfileID: UUID?
    /// A profile just added, whose name Settings opens for editing.
    var renamingProfileID: UUID?
    /// The panel item the arrow keys have moved to.
    var keyboardItem: PanelItem?
    /// A device whose row should open its actions menu, asked for from the
    /// keyboard. The row clears it.
    var actionsMenuDeviceID: String?
    var hideNewDisplayOutputs: Bool
    var isActiveOutputMuted = false
    var isActiveInputMuted = false
    var micFlashState = false
    /// The microphone mute the user asked for, on every physical microphone
    /// the app can mute.
    var isMicrophoneMuted = false
    /// Some app is recording from the current microphone.
    var isInputRecording = false
    private(set) var currentInputMayBeRecording = false
    private(set) var anyInputMayBeRecording = false
    /// While muted, an app recording from a microphone the mute could not
    /// cover, such as a Bluetooth headset that is not the current input.
    var uncoveredRecording: UncoveredRecording?
    var showsSwitchNotice: Bool
    var remindsWhenMuted: Bool
    var mutesSpeakersWhenHeadphonesDisconnect: Bool
    var lightsBusylightWhileRecording: Bool
    var outlinesMenuBarIcon: Bool
    var menuBarDevices: MenuBarDevices
    var showsMenuBarVolume: Bool
    var pulsesMutedMicrophone: Bool
    var redIconWhenManual: Bool
    var keepsDebugLog: Bool
    /// The menu bar icon's reminder that automatic switching is off.
    var showsRedIconBackground: Bool { redIconWhenManual && isManualMode }
    /// Bluetooth addresses with a connection attempt in flight, each tagged so
    /// a finished attempt cannot end a newer one.
    var connectingBluetoothAttempts: [String: UUID] = [:]
    /// The address of a Bluetooth device clicked while off, selected as soon
    /// as CoreAudio adds it.
    var selectingBluetoothAddress: String?
    /// Called with the devices Automatic mode just switched to because the
    /// hardware changed, output first. Never for the user's own choices.
    var onAutomaticSwitch: (([AudioDevice]) -> Void)?
    /// Called when a Focus or a shortcut applies a profile, with its name and
    /// the devices that changed.
    var onProfileApplied: ((String, [AudioDevice]) -> Void)?
    /// The last switches of output or microphone, newest first, for
    /// Settings and Copy Diagnostics. Kept in memory only.
    var recentSwitches: [SwitchRecord] = []
    /// Why the next `select` happens, when its caller knows better than
    /// "automatic" or "picked".
    var switchReason: String?

    let store: PriorityStore
    let audio: AudioOperations
    let link: LinkOperations
    let battery: BluetoothBatteryMonitor
    private let reduceMotion: () -> Bool
    private var mutedRoles: Set<String> = []
    /// The microphones carrying `isMicrophoneMuted`, by UID.
    private var mutedInputUIDs: Set<String> = []
    private var connectedInputs: [AudioDevice] = []
    private(set) var hasCurrentDeviceSnapshot = false
    private var inventoryRetry: Task<Void, Never>?
    var speakerMuteFailure: AudioDevice?
    private var failedMicRestores: Set<String> = []
    var microphonesAwaitingRestore: [String] {
        guard !isMicrophoneMuted else { return [] }
        return connectedInputs.filter { failedMicRestores.contains($0.uid) }.map(\.name)
    }
    /// The headphones last seen as the current output, by UID.
    private var playingHeadphonesUID: String?
    private var unresolvedUSBUIDs = Set<String>()
    private var usbIdentityRetry: Task<Void, Never>?
    private var connectedInputUIDs: Set<String> = []
    private var connectedOutputUIDs: Set<String> = []
    private var connectedUIDsByID: [DeviceRole: [UInt32: String]] = [:]
    /// The output category the panel's microphone order was last shown for.
    private var microphoneOrderShownFor: OutputCategory?
    private var recentlyAddedUIDs: [DeviceRole: Set<String>] = [:]
    private var topologyChangedAt: [DeviceRole: TimeInterval] = [:]
    private var micFlashTimer: Timer?
    private var muteVolumeRefreshTask: Task<Void, Never>?
    private var hasStarted = false
    /// Keeps "Output only" intact when CoreAudio echoes our own default change.
    /// Held by UID because platform IDs are recycled across devices.
    var selectedOnlyOutputUID: String?
    /// Devices picked in the panel, Control Center or Sound Settings, or that
    /// macOS keeps switching to, by role and UID. Automatic mode keeps them
    /// until they leave or the list would use a device that connects later.
    var keptPicks: [DeviceRole: String] = [:]
    /// A system input change between devices already present. Core Audio does
    /// not identify its author, so this also covers a call app or ear detection.
    var externalInputUID: String? {
        didSet {
            restoreExternalInputOnLaunch = false
            store.externalMicrophoneUID = externalInputUID
        }
    }
    private var restoreExternalInputOnLaunch = true
    /// The UIDs connected when each role's pick was kept that are still
    /// connected, so a device outside them connected after the pick.
    private var connectedAtPick: [DeviceRole: Set<String>] = [:]
    /// When the app last switched each role back after macOS or another app
    /// moved it.
    var switchedBackAt: [DeviceRole: TimeInterval] = [:]
    /// The device macOS moved each role to again soon after a switch back, by
    /// UID. The app leaves it there and names it in the panel.
    var takeoverUIDs: [DeviceRole: String] = [:]
    /// Retakes of the microphone in a row, each within a second of a switch
    /// back.
    private var fastMicrophoneRetakes = 0
    /// The microphone picked with automatic switching off that the hold
    /// switches back to: the last one the app selected, or current when
    /// automatic switching turned off, when the held one left, or when
    /// picked in Control Center.
    var heldInputUID: String?
    private var microphoneHoldResume: Task<Void, Never>?
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private let isUserPicking: () -> Bool
    /// Bumped on every Jabra link verdict so `linkState(for:)` is part of the
    /// Observation graph. `link.state` itself lives outside `@Observable`, so
    /// without this a row only redraws its badge when something else
    /// (like hover) forces its body to re-run.
    private var linkRevision = 0
    /// Headset busylights the app lit for a recording, by output UID, true
    /// once the headset shows it lit.
    private var litBusylights: [String: Bool] = [:]
    /// Lit for a recording and cleared by the wearer, so left off until the
    /// recording stops.
    private var declinedBusylights: Set<String> = []
    private var busylightTask: Task<Void, Never>?
    /// A slider drag sets the level many times a second, so the log gets the
    /// level it settles on.
    var levelLogTasks: [DeviceRole: Task<Void, Never>] = [:]
    /// Headset rows with the microphone line open, by output UID, and those
    /// whose line opened with no app recording, so by the call button.
    private var openLineUIDs: Set<String> = []
    private var headsetCallUIDs: Set<String> = []

    init(
        store: PriorityStore = PriorityStore(),
        audio: AudioOperations,
        link: LinkOperations,
        battery: BluetoothBatteryMonitor = BluetoothBatteryMonitor(read: { nil }),
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        isUserPicking: @escaping () -> Bool = { false }
    ) {
        self.store = store
        self.audio = audio
        self.link = link
        self.battery = battery
        self.reduceMotion = reduceMotion
        self.isUserPicking = isUserPicking
        isManualMode = store.isManualMode
        selectsPairedDevice = store.selectsPairedDevice
        microphonesFollowOutput = store.microphonesFollowOutput
        hideNewDisplayOutputs = store.hideNewDisplayOutputs
        showsSwitchNotice = store.showsSwitchNotice
        remindsWhenMuted = store.remindsWhenMuted
        mutesSpeakersWhenHeadphonesDisconnect = store.mutesSpeakersWhenHeadphonesDisconnect
        lightsBusylightWhileRecording = store.lightsBusylightWhileRecording
        outlinesMenuBarIcon = store.outlinesMenuBarIcon
        menuBarDevices = store.menuBarDevices
        showsMenuBarVolume = store.showsMenuBarVolume
        pulsesMutedMicrophone = store.pulsesMutedMicrophone
        redIconWhenManual = store.redIconWhenManual
        keepsDebugLog = store.keepsDebugLog
        profiles = store.profiles
        activeProfileID = store.activeProfileID
        battery.onPairedAudioChange = { [weak self] in self?.refreshDevices() }
    }

    func start() {
        guard !hasStarted else { return }
        refreshDevices()
        refreshVolume()
        battery.refresh()
        if !isManualMode {
            applyHighestPriorityDevices()
        } else {
            heldInputUID = currentUIDs[.input]
            refreshMute()
        }
        hasStarted = true
    }

    func stop() {
        inventoryRetry?.cancel()
        inventoryRetry = nil
        usbIdentityRetry?.cancel()
        usbIdentityRetry = nil
        unresolvedUSBUIDs.removeAll()
        muteVolumeRefreshTask?.cancel()
        muteVolumeRefreshTask = nil
        microphoneHoldResume?.cancel()
        microphoneHoldResume = nil
        busylightTask?.cancel()
        busylightTask = nil
        micFlashTimer?.invalidate()
        micFlashTimer = nil
        micFlashState = false
        // The muted indicator leaves with the app, so the mute must too.
        for uid in store.appliedMicrophoneMutes.keys {
            restoreMicrophone(uid)
        }
        mutedInputUIDs = []
        isMicrophoneMuted = false
        hasStarted = false
    }

    func handleDevicesChanged() {
        let before = currentUIDs
        let oldInputs = connectedInputUIDs
        let oldOutputs = connectedOutputUIDs
        guard refreshDevices() else { return }
        if connectedInputUIDs != oldInputs || connectedOutputUIDs != oldOutputs {
            battery.refresh()
        }
        if hasStarted, let address = selectingBluetoothAddress,
           let device = allOutputs.first(where: {
               $0.isConnected && bluetoothAddress(of: $0) == address
           }) {
            selectingBluetoothAddress = nil
            selectManually(device)
            refreshMute()
            return
        }
        guard !isManualMode, hasStarted else {
            if hasStarted {
                holdMicrophone()
            }
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
        // Both roles, because the refresh below reads both defaults: macOS
        // moves the output and microphone to AirPods a few milliseconds apart,
        // so by the microphone's own event it no longer looks moved.
        let previousUIDs = before
        let previousDevices: [DeviceRole: AudioDevice] = [
            .input: currentInputDevice,
            .output: currentOutputDevice,
        ].compactMapValues { $0 }
        let previousConnectedUIDs: [DeviceRole: Set<String>] = [
            .input: connectedInputUIDs,
            .output: connectedOutputUIDs,
        ]
        guard refreshDevices() else { return }
        refreshVolume()
        let currentID = role == .input ? currentInputID : currentOutputID
        let currentUID = currentID.flatMap { connectedUIDsByID[role]?[$0] }
        guard hasStarted else {
            refreshMute()
            return
        }
        // CoreAudio does not report whether a default changed because of the
        // user or topology; disappearing and newly-current devices identify topology.
        func topologyExplainsChange(_ role: DeviceRole) -> Bool {
            let connectedUIDs = role == .input
                ? connectedInputUIDs
                : connectedOutputUIDs
            let currentUID = currentUIDs[role]
            return previousUIDs[role].map { !connectedUIDs.contains($0) } == true
                || currentUID.map {
                    previousConnectedUIDs[role]?.contains($0) == false
                } == true
                || currentUID.map {
                    recentlyAddedUIDs[role]?.contains($0) == true
                        && uptime() - (topologyChangedAt[role] ?? 0) < 2
                } == true
        }
        if isManualMode {
            var switchedBack = false
            if !topologyExplainsChange(.output),
               let previousDevice = previousDevices[.output],
               let currentUID = currentUIDs[.output],
               previousDevice.uid != currentUID,
               connectedOutputUIDs.contains(previousDevice.uid),
               !isUserPicking(),
               shouldSwitchBack(.output, from: currentUID) {
                // macOS or another app moved it, as when AirPods in the ears
                // take the output back, so the user's own pick wins.
                DebugLog.shared.write("switching output back to \(previousDevice.logName): macOS or another app moved it while automatic switching is off")
                withSwitchReason("switched back") {
                    select(previousDevice, includesPairedDevice: false)
                }
                switchedBack = true
            }
            // After the output, so a microphone that is the other half of an
            // output just switched back is no longer taken for its pair.
            if holdMicrophone() { switchedBack = true }
            if switchedBack {
                refreshMute()
                return
            }
            if role == .output {
                let output = currentOutputDevice
                if output?.uid != selectedOnlyOutputUID {
                    selectedOnlyOutputUID = nil
                    if let output, externalInputUID == nil { selectPairedDevice(of: output) }
                }
            }
            refreshMute()
            return
        }
        if topologyExplainsChange(role) {
            DebugLog.shared.write("the \(role.rawValue) change follows a device connecting or leaving, so the list decides")
            applyHighestPriorityDevices()
            announceAutomaticSwitches(since: before)
            return
        }
        if let target = automaticTarget(for: role),
           target.platformID != currentID,
           let currentUID {
            let isPicking = !connectedMomentsAgo(currentUID, role) && isUserPicking()
            guard isPicking || !shouldSwitchBack(role, from: currentUID) else {
                // macOS or another app moved it, as when AirPods take the
                // microphone on ear detection, so the list wins.
                DebugLog.shared.write("macOS or another app moved the \(role.rawValue), switching back to the list")
                let moved = currentUIDs
                withSwitchReason("switched back to the list") { applyHighestPriority(role) }
                refreshMute()
                announceAutomaticSwitches(since: moved)
                return
            }
            if isPicking {
                DebugLog.shared.write("the \(role.rawValue) was picked in Control Center or Sound Settings")
            }
            // A temporary yield during a hardware handover expires on its timer.
            // Turning that yield into a pick would make the timeout select it again.
            if role == .output || takeoverUIDs[.input] == nil {
                keepPick(currentUID, for: role)
            }
        }
        if role == .output, let output = currentOutputDevice {
            selectPairedDevice(of: output, automatically: !isManualMode)
            // An output picked elsewhere still brings its own microphone.
            let moved = currentUIDs
            followOutputCategory(
                from: previousDevices[.output].map(store.category(for:))
            )
            announceAutomaticSwitches(since: moved)
        }
        refreshMute()
    }

    /// Logs and lists each role macOS or another app moved since
    /// `previousUIDs`. Both roles, since one refresh can reveal both moves.
    private func noteOutsideMoves(from previousUIDs: [DeviceRole: String]) {
        for role in DeviceRole.allCases where previousUIDs[role] != currentUIDs[role] {
            DebugLog.shared.write("default \(role.rawValue) changed outside the app: \(previousUIDs[role].map { logName($0, role) } ?? "none") to \(currentUIDs[role].map { logName($0, role) } ?? "none")")
            if let device = role == .input ? currentInputDevice : currentOutputDevice {
                recordSwitch(role, device.name, "by macOS, Control Center or another app")
                if role == .input, let previous = previousUIDs[.input],
                   connectedInputUIDs.contains(previous), !connectedMomentsAgo(device.uid, .input) {
                    externalInputUID = device.uid
                    heldInputUID = device.uid
                    keptPicks[.input] = nil
                    takeoverUIDs[.input] = nil
                    microphoneHoldResume?.cancel()
                    microphoneHoldResume = nil
                }
            }
        }
    }

    /// With automatic switching off, puts the held microphone back whenever
    /// another one is current, whatever event shows it: AirPods take it both
    /// when they connect and on ear detection, and the order of CoreAudio's
    /// events can hide either move. The current one is held instead when it
    /// is the other half of the output with halves together, when the held
    /// one is gone, or when it was picked in Control Center.
    @discardableResult
    private func holdMicrophone() -> Bool {
        guard isManualMode, let current = currentUIDs[.input], current != heldInputUID else {
            return false
        }
        let isOutputsHalf = currentOutputDevice.map {
            selectsHalvesTogether($0) && pairedDevice(for: $0)?.uid == current
        } ?? false
        let held = connectedInputs.first { $0.uid == heldInputUID }
        var reason: String?
        if externalInputUID == nil, isOutputsHalf {
            reason = "the other half of the output"
        } else if held == nil {
            reason = "the held one is gone"
        } else if !connectedMomentsAgo(current, .input), isUserPicking() {
            reason = "picked in Control Center or Sound Settings"
        }
        if let reason {
            DebugLog.shared.write("holding the microphone \(logName(current, .input)): \(reason)")
            heldInputUID = current
            return false
        }
        guard let held, shouldSwitchBack(.input, from: current) else { return false }
        DebugLog.shared.write("switching input back to \(held.logName): macOS or another app moved it while automatic switching is off")
        withSwitchReason("switched back") { select(held, includesPairedDevice: false) }
        return true
    }

    /// Whether `uid` joined moments ago, so a move to it is macOS following
    /// the connection and not a pick, even while a Control Center window is
    /// open. AirPods Pro took the default 1.6 s after their microphone
    /// appeared (macOS 26.6.2).
    private func connectedMomentsAgo(_ uid: String, _ role: DeviceRole) -> Bool {
        // ponytail: a fixed 5 s window; a slower handover reads as a pick.
        recentlyAddedUIDs[role]?.contains(uid) == true
            && uptime() - (topologyChangedAt[role] ?? 0) < 5
    }

    /// Whether to switch `role` back from `uid`. AirPods Smart Routing ignores
    /// a default set through CoreAudio and retries every few seconds, so once
    /// the output is taken again soon after a switch back, the app stops
    /// rather than fight it: an audible flip between speakers and AirPods is
    /// worse than leaving them. The microphone is held instead, since a call
    /// on the AirPods microphone is worse than a moment on it. Smart Routing
    /// waits 2 s before taking it and retried every 4.4 s on AirPods Pro
    /// (macOS 26.6.2), so only a retake within 1 s of a switch back, three
    /// in a row, means another app is fighting, and pauses the hold for 30 s.
    private func shouldSwitchBack(_ role: DeviceRole, from uid: String) -> Bool {
        guard takeoverUIDs[role] != uid else { return false }
        let now = uptime()
        if role == .input {
            let isFast = switchedBackAt[.input].map { now - $0 < 1 } ?? false
            fastMicrophoneRetakes = isFast ? fastMicrophoneRetakes + 1 : 0
            if fastMicrophoneRetakes >= 3 {
                DebugLog.shared.write("\(logName(uid, role)) took the microphone back three times within a second of each switch back, pausing the hold for 30 s")
                takeoverUIDs[.input] = uid
                fastMicrophoneRetakes = 0
                microphoneHoldResume?.cancel()
                microphoneHoldResume = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.resumeMicrophoneHold()
                }
                return false
            }
            switchedBackAt[.input] = now
            return true
        }
        // ponytail: a fixed 30 s window. A retry slower than that still loops,
        // at its own pace; counting retries per pick would close that.
        if let last = switchedBackAt[role], now - last < 30 {
            DebugLog.shared.write("\(logName(uid, role)) took the \(role.rawValue) again within 30 s of a switch back, leaving it there")
            takeoverUIDs[role] = uid
            return false
        }
        switchedBackAt[role] = now
        return true
    }

    /// Ends a paused microphone hold and takes the microphone back, unless a
    /// pick, a profile or a device coming or going already started over:
    /// to the list, or to the pick with automatic switching off.
    func resumeMicrophoneHold() {
        microphoneHoldResume = nil
        guard let uid = takeoverUIDs[.input] else { return }
        DebugLog.shared.write("resuming the microphone hold after a pause on \(logName(uid, .input))")
        takeoverUIDs[.input] = nil
        // A fight still going on pauses again after three more fast retakes.
        switchedBackAt[.input] = uptime()
        withSwitchReason("switched back after a pause") {
            if !isManualMode {
                applyHighestPriorityInput()
            } else if let held = inputDevices.first(where: { $0.uid == heldInputUID && $0.isConnected }) {
                select(held, includesPairedDevice: false)
                refreshMute()
            }
        }
    }

    /// The device macOS keeps switching to, while it is still current, output
    /// first.
    var takeoverDevice: AudioDevice? {
        if let output = currentOutputDevice, takeoverUIDs[.output] == output.uid {
            return output
        }
        if let input = currentInputDevice, takeoverUIDs[.input] == input.uid {
            return input
        }
        return nil
    }

    func handleMuteOrVolumeChanged() {
        guard muteVolumeRefreshTask == nil else { return }
        muteVolumeRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            muteVolumeRefreshTask = nil
            // The app updates these itself before CoreAudio echoes its own
            // changes, so a difference here came from outside.
            let before = (volume: volume, microphone: microphoneLevel, isMuted: isActiveOutputMuted)
            refreshMute()
            refreshVolume()
            if (before.volume * 100).rounded() != (volume * 100).rounded() {
                logSettledLevel(.output, volume, outside: true)
            }
            if (before.microphone * 100).rounded() != (microphoneLevel * 100).rounded() {
                logSettledLevel(.input, microphoneLevel, outside: true)
            }
            if before.isMuted != isActiveOutputMuted {
                DebugLog.shared.write("output \(isActiveOutputMuted ? "muted" : "unmuted") outside the app")
            }
        }
    }

    /// The audio driver may announce a device before its USB descriptors.
    /// Give each newly unresolved set one follow-up read, without polling or
    /// treating the identity refresh as another automatic route change.
    private func retryUnresolvedUSBDevices(_ devices: [AudioDevice]) {
        let unresolved = Set(devices.lazy.filter(\.hasUnresolvedUSBIdentity).map(\.uid))
        guard unresolved != unresolvedUSBUIDs else { return }
        unresolvedUSBUIDs = unresolved
        usbIdentityRetry?.cancel()
        usbIdentityRetry = nil
        guard !unresolved.isEmpty else { return }
        usbIdentityRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refreshDevices()
        }
    }

    private func retryDeviceInventory() {
        guard inventoryRetry == nil else { return }
        inventoryRetry = Task { @MainActor [weak self] in
            for milliseconds in [250, 1000, 4000] {
                do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
                guard let self else { return }
                handleDevicesChanged()
                if hasCurrentDeviceSnapshot { return }
            }
            self?.inventoryRetry = nil
        }
    }

    @discardableResult
    func refreshDevices() -> Bool {
        guard let connected = audio.devices() else {
            // A failed HAL read is different from a successful empty list.
            // Keep the visible state and preferences, but stop using stale IDs.
            hasCurrentDeviceSnapshot = false
            anyInputMayBeRecording = true
            retryDeviceInventory()
            return false
        }
        hasCurrentDeviceSnapshot = true
        inventoryRetry?.cancel()
        inventoryRetry = nil
        let previous = currentUIDs
        retryUnresolvedUSBDevices(connected)
        connectedInputs = connected.filter { $0.role == .input }
        if !connectingBluetoothAttempts.isEmpty {
            for address in connected.compactMap(bluetoothAddress(of:)) {
                connectingBluetoothAttempts[address] = nil
            }
        }
        let inputUIDs = Set(connected.lazy.filter { $0.role == .input }.map(\.uid))
        let outputUIDs = Set(connected.lazy.filter { $0.role == .output }.map(\.uid))
        if inputUIDs != connectedInputUIDs || outputUIDs != connectedOutputUIDs {
            switchedBackAt = [:]
            takeoverUIDs = [:]
            // Any refresh can be the first to see a device join, such as the
            // one a default change makes, so the joins are noted here.
            if hasStarted {
                for (role, added) in [
                    (DeviceRole.input, inputUIDs.subtracting(connectedInputUIDs)),
                    (.output, outputUIDs.subtracting(connectedOutputUIDs)),
                ] where !added.isEmpty {
                    recentlyAddedUIDs[role] = added
                    topologyChangedAt[role] = uptime()
                }
            }
            if DebugLog.shared.isEnabled {
                logConnections(connected, inputs: inputUIDs, outputs: outputUIDs)
            }
        }
        connectedInputUIDs = inputUIDs
        if let externalInputUID, !inputUIDs.contains(externalInputUID) {
            self.externalInputUID = nil
        }
        connectedOutputUIDs = outputUIDs
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
        if restoreExternalInputOnLaunch, let current = currentUIDs[.input] {
            restoreExternalInputOnLaunch = false
            if let saved = store.externalMicrophoneUID {
                // During a relaunch another app may have changed the default.
                // Only resume a choice that the system is still using.
                externalInputUID = store.currentUID(for: saved, role: .input) == current ? current : nil
            }
        }

        var inputs = connectedInputs
        var outputs = connected.filter { $0.role == .output }
        // Every paired Bluetooth speaker and headphones that is off is listed
        // at its rank, dimmed, so it can be connected where it stands. A
        // connected one with an unfamiliar UID can match an unambiguous paired name.
        let connectedAddresses = Set(outputs.compactMap(bluetoothAddress(of:)))
        let pairedOff = battery.report.pairedAudio.filter {
            !connectedAddresses.contains($0.address) && !store.isForgotten(uid: $0.device.uid)
        }.map(\.device)
        let pairedOffUIDs = Set(pairedOff.map(\.uid))
        if showAll {
            for stored in store.knownDevices {
                let connectedUIDs = stored.role == .input
                    ? connectedInputUIDs
                    : connectedOutputUIDs
                guard !connectedUIDs.contains(stored.uid),
                      !pairedOffUIDs.contains(stored.uid) else { continue }
                if stored.role == .input {
                    inputs.append(stored.disconnectedDevice())
                } else {
                    outputs.append(stored.disconnectedDevice())
                }
            }
        }
        for paired in pairedOff {
            var device = store.storedDevice(uid: paired.uid, role: .output)?
                .disconnectedDevice() ?? paired
            // The class of device beats a remembered claim, which may predate
            // ignoring a Bluetooth headphones terminal.
            device.declaredCategory = paired.declaredCategory
            device.transportType = kAudioDeviceTransportTypeBluetooth
            outputs.append(device)
        }
        (speakerDevices, hiddenSpeakerDevices) = split(outputs, .speaker)
        (headphoneDevices, hiddenHeadphoneDevices) = split(outputs, .headphone)
        // After the outputs, whose category picks the microphone order.
        // Hiding the active microphone would leave no way to see which one is
        // in use, so it stays listed and shows as hidden, matching outputs.
        resetViewedMicrophoneOrderIfOutputMoved()
        inputDevices = store.sorted(
            inputs.filter {
                showAll
                    || !store.isHidden($0)
                    || ($0.isConnected && $0.platformID == currentInputID)
            },
            microphonesFor: microphoneOrderCategory
        )
        if hasStarted { noteOutsideMoves(from: previous) }
        endOvertakenPicks()
        return true
    }

    /// Devices that connected or left since the last refresh, read before
    /// the connected sets are replaced.
    private func logConnections(
        _ connected: [AudioDevice],
        inputs: Set<String>,
        outputs: Set<String>
    ) {
        for device in connected where !(device.role == .input
            ? connectedInputUIDs
            : connectedOutputUIDs).contains(device.uid) {
            DebugLog.shared.write("connected \(device.role.rawValue): \(logEntry(device))")
        }
        for (role, left) in [
            (DeviceRole.input, connectedInputUIDs.subtracting(inputs)),
            (.output, connectedOutputUIDs.subtracting(outputs)),
        ] {
            for uid in left.sorted() {
                DebugLog.shared.write("disconnected \(role.rawValue): \(logName(uid, role))")
            }
        }
    }

    func logName(_ uid: String, _ role: DeviceRole) -> String {
        store.storedDevice(uid: uid, role: role)?.disconnectedDevice().logName ?? "[\(uid)]"
    }

    /// Keeps `uid` for `role` until it leaves or the list would use a device
    /// that connects after it.
    func keepPick(_ uid: String, for role: DeviceRole) {
        DebugLog.shared.write("keeping the \(role.rawValue) pick \(logName(uid, role)) until it leaves or a newer device outranks it")
        keptPicks[role] = uid
        connectedAtPick[role] = role == .input ? connectedInputUIDs : connectedOutputUIDs
    }

    /// Drops a pick whose device left, and ends every pick once the list
    /// would use a device that connected after it, as a headset plugged in
    /// mid-call. Other devices coming or going leave picks alone.
    private func endOvertakenPicks() {
        guard !keptPicks.isEmpty else { return }
        for role in DeviceRole.allCases {
            let connected = role == .input ? connectedInputUIDs : connectedOutputUIDs
            if let uid = keptPicks[role], !connected.contains(uid) {
                DebugLog.shared.write("the \(role.rawValue) pick \(logName(uid, role)) ended: it left")
                keptPicks[role] = nil
            }
            connectedAtPick[role]?.formIntersection(connected)
        }
        let overtaken = keptPicks.keys.contains { role in
            automaticTarget(for: role, honoringPicks: false)
                .map { connectedAtPick[role]?.contains($0.uid) == false } ?? false
        }
        if overtaken {
            DebugLog.shared.write("picks ended: a device that connected after them now ranks first")
            keptPicks = [:]
        }
    }

    /// The category whose microphone order the panel shows and edits.
    var microphoneOrderCategory: OutputCategory {
        viewedMicrophoneCategory ?? activeOutputCategory ?? .speaker
    }

    /// A different output category playing brings the panel back to its
    /// microphone order.
    private func resetViewedMicrophoneOrderIfOutputMoved() {
        let active = activeOutputCategory
        guard active != microphoneOrderShownFor else { return }
        microphoneOrderShownFor = active
        viewedMicrophoneCategory = nil
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
        guard hasCurrentDeviceSnapshot else { return }
        if let current = audio.outputVolume() {
            volume = current
            isVolumeControllable = true
        } else {
            volume = 0
            isVolumeControllable = false
        }
        isOutputMutable = currentOutputID.map { audio.canSetMute(.output, $0) } ?? false
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
        isMicrophoneMutable = isMicrophoneLevelControllable
            || currentInputID.map { audio.canSetMute(.input, $0) } ?? false
    }

    func refreshMute() {
        guard hasCurrentDeviceSnapshot else { return }
        muteSpeakersIfHeadphonesLeft()
        reconcileMicrophoneMute()
        let connected = inputDevices + speakerDevices + headphoneDevices
        mutedRoles = Set(connected.lazy.filter {
            $0.isConnected && self.isHardwareMuted($0)
        }.map(\.roleIdentifier))
        isActiveOutputMuted = currentOutputID.map {
            self.audio.isMuted(.output, $0)
        } ?? false
        if isActiveOutputMuted { speakerMuteFailure = nil }
        // The current microphone is always listed, even when hidden.
        isActiveInputMuted = currentInputDevice.map {
            mutedRoles.contains($0.roleIdentifier)
        } ?? false
        let inputIDs = connectedInputs.map(\.platformID)
        let activity = audio.inputActivity?(inputIDs)
            ?? InputActivity(recording: Set(inputIDs.filter(audio.isRunning)))
        let isRecording = currentInputID.map(activity.recording.contains) ?? false
        currentInputMayBeRecording = currentInputID.map(activity.mayBeRecording) ?? false
        anyInputMayBeRecording = !activity.recording.isEmpty || !activity.uncertain.isEmpty
        if isRecording != isInputRecording {
            DebugLog.shared.write("an app \(isRecording ? "started" : "stopped") recording from \(currentInputDevice?.logName ?? "the microphone")")
        }
        isInputRecording = isRecording
        let uncovered = findUncoveredRecording(activity)
        if uncovered != uncoveredRecording, let uncovered {
            DebugLog.shared.write("activity on \(uncovered.microphone), which the mute does not cover; recording confirmed: \(uncovered.isConfirmed)")
        }
        uncoveredRecording = uncovered
        updateMicFlash()
        scheduleAutomaticBusylights()
    }

    /// Headphones that run out of battery or drop out leave the sound on the
    /// speakers, so the speaker that takes over starts muted. A Jabra headset
    /// behind a Link dongle never leaves the device list, it only stops being
    /// usable. The tracked headphones survive a moment with no known output,
    /// since the device list and the default can change in either order.
    private func muteSpeakersIfHeadphonesLeft() {
        guard let output = currentOutputDevice else { return }
        let category = store.category(for: output)
        if speakerMuteFailure?.uid != output.uid || !mutesSpeakersWhenHeadphonesDisconnect {
            speakerMuteFailure = nil
        }
        if mutesSpeakersWhenHeadphonesDisconnect,
           let uid = playingHeadphonesUID,
           !(allOutputs.first { $0.uid == uid && $0.isConnected }.map(link.isUsable) ?? false),
           category == .speaker {
            if audio.isMuted(.output, output.platformID) || audio.setMute(.output, output.platformID, true) {
                DebugLog.shared.write("muted \(output.logName) after the headphones disconnected")
                speakerMuteFailure = nil
            } else {
                speakerMuteFailure = output
                DebugLog.shared.write("could not mute \(output.logName) after the headphones disconnected")
            }
        }
        playingHeadphonesUID = category == .headphone ? output.uid : nil
    }

    /// Keeps the microphone mute on every microphone it covers, so an app
    /// recording from one that is not the current input hears silence too,
    /// and follows mutes and unmutes of the current one made outside the
    /// app, like System Settings or a headset's mute button. A microphone
    /// muted before the mute started is left alone, and stays muted after it.
    private func reconcileMicrophoneMute() {
        let current = currentInputDevice
        if let current {
            let muted = isHardwareMuted(current)
            if mutedInputUIDs.contains(current.uid), !muted {
                DebugLog.shared.write("\(current.logName) was unmuted outside the app")
                isMicrophoneMuted = false
                mutedInputUIDs.remove(current.uid)
                store.appliedMicrophoneMutes[current.uid] = nil
            } else if mutedInputUIDs.isEmpty, muted, !isMicrophoneMuted,
                      store.appliedMicrophoneMutes[current.uid] == nil {
                DebugLog.shared.write("\(current.logName) was muted outside the app")
                isMicrophoneMuted = true
                mutedInputUIDs.insert(current.uid)
            }
        }
        if isMicrophoneMuted {
            for uid in mutedInputUIDs {
                guard let device = connectedInputs.first(where: { $0.uid == uid }) else {
                    // Its saved state brings the mute back on reconnect, below.
                    mutedInputUIDs.remove(uid)
                    continue
                }
                if !isCoveredByMute(device) {
                    restoreMicrophone(uid)
                    mutedInputUIDs.remove(uid)
                }
            }
        } else {
            for uid in mutedInputUIDs { restoreMicrophone(uid) }
            mutedInputUIDs = []
        }
        // Anything else still recorded was muted before a crash, or while it
        // was unplugged, and must not come back silently dead.
        for uid in store.appliedMicrophoneMutes.keys where !mutedInputUIDs.contains(uid) {
            // A previously muted mic can reconnect under a new HAL ID while
            // the global mute is still on. Keep its original undo record.
            if isMicrophoneMuted, let device = connectedInputs.first(where: { $0.uid == uid }),
               isCoveredByMute(device) { continue }
            restoreMicrophone(uid)
        }
        guard isMicrophoneMuted else { return }
        for device in connectedInputs where isCoveredByMute(device) {
            if isHardwareMuted(device) {
                if store.appliedMicrophoneMutes[device.uid] != nil { mutedInputUIDs.insert(device.uid) }
            } else if applyMicrophoneMute(device) {
                mutedInputUIDs.insert(device.uid)
            } else {
                mutedInputUIDs.remove(device.uid)
            }
        }
        if let current, !mutedInputUIDs.contains(current.uid), !isHardwareMuted(current) {
            // The microphone in use could not be muted, so nothing is.
            for uid in mutedInputUIDs { restoreMicrophone(uid) }
            mutedInputUIDs = []
            isMicrophoneMuted = false
        }
    }

    /// The current microphone, and every other physical one. Virtual and
    /// aggregate inputs are left alone so routing and recording setups keep
    /// working. A Bluetooth microphone that is not the current input is left
    /// too: muting it might move its headphones to call quality, unmeasured,
    /// so it gets the reminder instead.
    private func isCoveredByMute(_ device: AudioDevice) -> Bool {
        device.isConnected
            && (device.platformID == currentInputID || (!device.isVirtual && !device.isBluetooth))
    }

    /// While muted, an app recording from a connected physical microphone the
    /// mute does not hold. A virtual input records from a physical one, which
    /// the mute already holds.
    private func findUncoveredRecording(_ activity: InputActivity) -> UncoveredRecording? {
        guard isMicrophoneMuted else { return nil }
        let uncovered = connectedInputs.filter {
            !$0.isVirtual && activity.mayBeRecording($0.platformID) && !isHardwareMuted($0)
        }
        if let device = uncovered.first(where: { activity.recording.contains($0.platformID) }) {
            return UncoveredRecording(app: audio.appRecording(device.platformID), microphone: device.name)
        }
        return uncovered.first.map { UncoveredRecording(app: nil, microphone: $0.name, isConfirmed: false) }
    }

    /// Mutes through the device's mute property, or by zeroing its input
    /// volume when it has none. Recorded before touching the hardware, so a
    /// crash in between still leaves something to restore.
    private func applyMicrophoneMute(_ device: AudioDevice) -> Bool {
        let id = device.platformID
        if let original = store.appliedMicrophoneMutes[device.uid] {
            // A secondary mic may have been unmuted by another process.
            // Reapply the original method without overwriting its undo record.
            return original == PriorityStore.mutedByProperty
                ? audio.setMute(.input, id, true)
                : audio.setInputVolume(id, 0)
        }
        store.appliedMicrophoneMutes[device.uid] = PriorityStore.mutedByProperty
        if audio.setMute(.input, id, true) {
            DebugLog.shared.write("muted \(device.logName) by its mute property")
            return true
        }
        if let level = audio.inputVolume(id) {
            store.appliedMicrophoneMutes[device.uid] = Double(level)
            if audio.setInputVolume(id, 0) {
                DebugLog.shared.write("muted \(device.logName) by zeroing its level, from \(level)")
                return true
            }
        }
        store.appliedMicrophoneMutes[device.uid] = nil
        DebugLog.shared.write("could not mute \(device.logName)")
        return false
    }

    /// Undoes a mute the same way it was applied. A disconnected microphone
    /// stays recorded and is restored once it reconnects.
    private func restoreMicrophone(_ uid: String) {
        guard hasCurrentDeviceSnapshot else { return }
        let level = store.appliedMicrophoneMutes[uid] ?? PriorityStore.mutedByProperty
        guard let device = connectedInputs.first(where: { $0.uid == uid }) else { return }
        let restored = level == PriorityStore.mutedByProperty
            ? audio.setMute(.input, device.platformID, false)
            : audio.setInputVolume(device.platformID, Float(level))
        if restored {
            failedMicRestores.remove(uid)
            store.appliedMicrophoneMutes[uid] = nil
            DebugLog.shared.write("restored \(device.logName) after microphone mute")
        } else {
            failedMicRestores.insert(uid)
            store.appliedMicrophoneMutes[uid] = level
            DebugLog.shared.write("could not restore \(device.logName); keeping its saved mute state")
        }
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
        return audio.inputVolume(device.platformID) == 0
    }

    var currentInputDevice: AudioDevice? {
        inputDevices.first { $0.isConnected && $0.platformID == currentInputID }
    }

    var currentUIDs: [DeviceRole: String] {
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

    /// AirPods battery levels, read again when devices come or go and
    /// whenever the panel opens, or a Jabra headset's, which it reports itself.
    func batteryLevels(for device: AudioDevice) -> BatteryLevels? {
        _ = linkRevision
        if let levels = battery.levels(for: device) { return levels }
        guard device.isConnected else { return nil }
        return link.battery(device).map { BatteryLevels(headset: $0) }
    }

    /// A Jabra headset reported a new battery level or control value.
    func handleHeadsetChanged() {
        linkRevision &+= 1
        classifyOpenLines()
        scheduleAutomaticBusylights()
    }

    /// Decides once, as the line opens, whether the headset or an app opened
    /// it. A line an app opened can stay open a few seconds after it stops
    /// recording, which must not turn it into a call.
    func classifyOpenLines() {
        for output in speakerDevices + headphoneDevices {
            let uid = output.uid
            guard link.headsetControls(output)?.isLineOpen == true else {
                openLineUIDs.remove(uid)
                headsetCallUIDs.remove(uid)
                continue
            }
            guard openLineUIDs.insert(uid).inserted else { continue }
            let isRecording = pairedDevice(for: output).map { audio.isRunning($0.platformID) } == true
            if !isRecording { headsetCallUIDs.insert(uid) }
        }
    }

    /// An app starting or stopping a recording can close and reopen the
    /// microphone for a moment, 0.4s seen with Voice Memos, so the busylight
    /// follows it only once it has held for a second.
    private func scheduleAutomaticBusylights() {
        busylightTask?.cancel()
        guard lightsBusylightWhileRecording || !litBusylights.isEmpty || !declinedBusylights.isEmpty else {
            busylightTask = nil
            return
        }
        busylightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            busylightTask = nil
            updateAutomaticBusylights()
        }
    }

    /// Lights a Jabra headset's busylight while an app records from its
    /// microphone, for calls in apps that never signal one, and clears it
    /// when the recording stops unless something else had lit it.
    /// ponytail: any app recording counts, dictation too; asking which
    /// processes record (macOS 14.2+) would keep it to calling apps.
    func updateAutomaticBusylights() {
        for output in speakerDevices + headphoneDevices {
            guard let isBusy = link.headsetControls(output)?.isBusy else { continue }
            let uid = output.uid
            let isRecording = lightsBusylightWhileRecording
                && pairedDevice(for: output).map { audio.isRunning($0.platformID) } == true
            switch (isRecording, litBusylights[uid]) {
            case (false, let lit):
                litBusylights[uid] = nil
                declinedBusylights.remove(uid)
                if lit != nil, isBusy {
                    DebugLog.shared.write("busylight off on \(output.logName): the recording stopped")
                    link.setBusy(false, output)
                }
            case (true, nil):
                guard !isBusy, !declinedBusylights.contains(uid) else { continue }
                DebugLog.shared.write("busylight on for \(output.logName): an app records from its microphone")
                litBusylights[uid] = false
                link.setBusy(true, output)
            case (true, false?):
                if isBusy { litBusylights[uid] = true }
            case (true, true?):
                guard !isBusy else { continue }
                DebugLog.shared.write("busylight on \(output.logName) cleared by the wearer, left off until the recording stops")
                litBusylights[uid] = nil
                declinedBusylights.insert(uid)
            }
        }
    }

    /// Clears the busylights the app lit, while the headset can still hear.
    func releaseAutomaticBusylights() {
        busylightTask?.cancel()
        for output in speakerDevices + headphoneDevices where litBusylights[output.uid] != nil {
            link.setBusy(false, output)
        }
        litBusylights.removeAll()
    }

    /// A Jabra headset's noise mode and sidetone, shown once on its Link
    /// dongle's output row rather than on the microphone row too.
    func headsetControls(for device: AudioDevice) -> JabraGNP.HeadsetControls? {
        _ = linkRevision
        guard device.role == .output, device.isConnected else { return nil }
        var controls = link.headsetControls(device)
        controls?.isHeadsetCall = headsetCallUIDs.contains(device.uid)
        return controls
    }

    func setNoiseMode(_ mode: JabraGNP.NoiseMode, for device: AudioDevice) {
        DebugLog.shared.write("clicked noise mode \(mode) on \(device.logName)")
        link.setNoiseMode(mode, device)
    }

    func setSidetone(_ isOn: Bool, for device: AudioDevice) {
        DebugLog.shared.write("clicked sidetone \(isOn ? "on" : "off") on \(device.logName)")
        link.setSidetone(isOn, device)
    }

    func setBusy(_ isBusy: Bool, for device: AudioDevice) {
        DebugLog.shared.write("clicked busylight \(isBusy ? "on" : "off") on \(device.logName)")
        link.setBusy(isBusy, device)
    }

    /// Only a call the headset's call button started: another app's call
    /// is that app's to end.
    func endHeadsetCall(for device: AudioDevice) {
        DebugLog.shared.write("clicked end call on \(device.logName)")
        guard headsetControls(for: device)?.isHeadsetCall == true else { return }
        link.endHeadsetCall(device)
    }

    func refreshHeadsetControls() {
        link.refreshHeadsetControls()
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
        outputDecision(honoringPicks: true)
    }

    private func outputDecision(honoringPicks: Bool, excluding rejected: Set<String> = []) -> AutomaticOutputDecision {
        guard !isManualMode else {
            return AutomaticOutputDecision(target: nil, skipped: nil)
        }
        if honoringPicks, let uid = keptPicks[.output], !rejected.contains(uid),
           let kept = allOutputs.first(where: { $0.uid == uid && $0.isConnected }) {
            return AutomaticOutputDecision(target: kept, skipped: nil)
        }
        var skipped: SkippedOutput?
        for device in headphoneDevices + speakerDevices {
            let category = store.category(for: device)
            guard device.isConnected, !rejected.contains(device.uid),
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
        guard hasCurrentDeviceSnapshot else { return }
        // Deferral covers both roles: picking a microphone now could pair it
        // with an output we are about to change.
        guard !automaticOutputDecision.isDeferred else {
            DebugLog.shared.write("automatic \(role.rawValue): waiting for a Jabra link check before choosing")
            return
        }
        let category = activeOutputCategory
        var rejected: Set<String> = []
        while let candidate = automaticTarget(for: role, excluding: rejected) {
            if candidate.platformID != (role == .input ? currentInputID : currentOutputID) {
                DebugLog.shared.write("automatic \(role.rawValue): \(candidate.logName), \(automaticReason(for: candidate, forDebugLog: true))")
            }
            if select(candidate, automatically: true) { break }
            rejected.insert(candidate.uid)
        }
        if role == .output { followOutputCategory(from: category) }
    }

    private func automaticReason(for device: AudioDevice, forDebugLog: Bool = false) -> String {
        if device.role == .input, externalInputUID == device.uid { return "kept the system microphone choice" }
        if keptPicks[device.role] == device.uid { return "kept your selection" }
        if device.role == .input, preferredPairedMicrophone?.id == device.id {
            return "paired with the selected output"
        }
        guard device.role == .output,
              let skipped = automaticOutputDecision.skipped else { return "selected by priority" }
        let name = forDebugLog ? skipped.device.logName : "\"\(skipped.device.name)\""
        return "skipped \(name) (\(skipped.reason.label))"
    }

    /// Once the output has moved to the other category, moves the microphone
    /// to the top of that category's order. Read after the output is applied,
    /// so the order always belongs to the device now playing.
    func followOutputCategory(from previous: OutputCategory?) {
        guard microphonesFollowOutput, activeOutputCategory != previous else { return }
        resetViewedMicrophoneOrderIfOutputMoved()
        inputDevices = store.sorted(inputDevices, microphonesFor: microphoneOrderCategory)
        if !isManualMode { applyHighestPriority(.input) }
    }

    private func automaticTarget(
        for role: DeviceRole,
        honoringPicks: Bool = true,
        excluding rejected: Set<String> = []
    ) -> AudioDevice? {
        if role == .input {
            if honoringPicks, let uid = externalInputUID, !rejected.contains(uid),
               let external = connectedInputs.first(where: { $0.uid == uid }) {
                return external
            }
            if honoringPicks, let uid = keptPicks[.input], !rejected.contains(uid),
               let kept = inputDevices.first(where: { $0.uid == uid && $0.isConnected }) {
                return kept
            }
            if let paired = preferredPairedMicrophone, !rejected.contains(paired.uid) { return paired }
            // The panel may be showing the other category's order.
            return store.firstSelectable(
                in: store.sorted(inputDevices, microphonesFor: activeOutputCategory),
                isUsable: { !rejected.contains($0.uid) && self.link.isUsable($0) }
            )
        }
        return outputDecision(honoringPicks: honoringPicks, excluding: rejected).target
    }

    private var preferredPairedMicrophone: AudioDevice? {
        guard let output = currentOutputDevice,
              automaticOutputDecision.target?.id == output.id,
              selectsHalvesTogether(output),
              let paired = pairedDevice(for: output),
              !store.isNeverUse(paired),
              link.isUsable(paired) else { return nil }
        return paired
    }

    @discardableResult
    func select(
        _ device: AudioDevice,
        automatically: Bool = false,
        includesPairedDevice: Bool = true
    ) -> Bool {
        guard hasCurrentDeviceSnapshot || refreshDevices(),
              connectedUIDsByID[device.role]?[device.platformID] == device.uid else { return false }
        let currentID = device.role == .input ? currentInputID : currentOutputID
        if currentID != device.platformID {
            guard audio.setDefault(device.role, device.platformID) else {
                DebugLog.shared.write("could not set the \(device.role.rawValue) to \(device.logName)")
                return false
            }
            DebugLog.shared.write("set the \(device.role.rawValue) to \(device.logName)")
            recordSwitch(device.role, device.name, switchReason
                ?? (automatically ? automaticReason(for: device) : "picked"))
            if device.role == .input {
                currentInputID = device.platformID
            } else {
                currentOutputID = device.platformID
            }
        }
        if device.role == .input {
            heldInputUID = device.uid
            if !automatically, externalInputUID != device.uid { externalInputUID = nil }
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
        if automatically, device.role == .output, externalInputUID != nil { return }
        // Output only holds while automatic switching keeps or switches back
        // to that output.
        if automatically, device.uid == selectedOnlyOutputUID { return }
        selectedOnlyOutputUID = nil
        guard selectsHalvesTogether(device), let partner = pairedDevice(for: device) else { return }
        guard device.role == .output || !automatically else { return }
        let partnerCurrentID = partner.role == .input ? currentInputID : currentOutputID
        guard partner.platformID != partnerCurrentID else { return }
        guard !automatically
            || (!store.isNeverUse(partner) && link.isUsable(partner)) else { return }
        let reason = device.role == .output ? "paired with the selected output" : "paired with the selected microphone"
        withSwitchReason(reason) { select(partner) }
    }

    func withSwitchReason(_ reason: String, _ body: () -> Void) {
        let outer = switchReason
        switchReason = reason
        body()
        switchReason = outer
    }

    private func recordSwitch(_ role: DeviceRole, _ device: String, _ reason: String) {
        recentSwitches.insert(SwitchRecord(date: Date(), role: role, device: device, reason: reason), at: 0)
        if recentSwitches.count > 20 { recentSwitches.removeLast() }
    }

    /// Whether choosing `device` selects its other half too: the global
    /// setting, unless this device was set apart from its row.
    func selectsHalvesTogether(_ device: AudioDevice) -> Bool {
        selectsPairedDevice && store.selectsHalvesTogether(device)
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
        if isActiveInputMuted, reduceMotion() || !pulsesMutedMicrophone {
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
