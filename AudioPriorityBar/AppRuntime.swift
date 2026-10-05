import AppKit
import AudioPriorityCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Starts as Option-Shift-M, which no call app uses for its own mute.
    @MainActor static let toggleMicrophoneMute = Self(
        "toggleMicrophoneMute",
        initial: .optionShiftM
    )
}

extension KeyboardShortcuts.Shortcut {
    /// Shortcuts store a physical key, so this looks up the key that types M
    /// on the current layout, a different key on AZERTY than on QWERTY.
    @MainActor static var optionShiftM: Self? {
        (0..<128).lazy
            .map { KeyboardShortcuts.Key(rawValue: $0) }
            .first { Self($0).description == "M" }
            .map { Self($0, modifiers: [.option, .shift]) }
    }
}

/// Whether someone is picking a device in Control Center or System Settings
/// right now. CoreAudio never says who changed a default, but Control Center
/// shows a window outside the menu bar's layer only while one of its menus
/// is open. Window owners and layers need no permission to read.
enum SystemSoundPicker {
    static func isInUse() -> Bool {
        isInUse(
            windows: CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] ?? [],
            controlCenterPIDs: Set(NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.controlcenter"
            ).map(\.processIdentifier)),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    static func isInUse(
        windows: [[String: Any]],
        controlCenterPIDs: Set<pid_t>,
        frontmostBundleID: String?
    ) -> Bool {
        guard frontmostBundleID != "com.apple.systempreferences" else { return true }
        let menuBarLayer = Int(CGWindowLevelForKey(.statusWindow))
        return windows.contains {
            controlCenterPIDs.contains($0[kCGWindowOwnerPID as String] as? pid_t ?? -1)
                && ($0[kCGWindowLayer as String] as? Int) != menuBarLayer
        }
    }
}

@MainActor
final class AppRuntime {
    let model: AppModel
    let updates: UpdateChecker
    private let audioObserver: CoreAudioObserver
    private let jabra: JabraHIDMonitor

    init() {
        let audioObserver = CoreAudioObserver()
        let jabra = JabraHIDMonitor()
        self.audioObserver = audioObserver
        self.jabra = jabra
        model = AppModel(
            store: PriorityStore(),
            audio: AudioOperations(
                devices: CoreAudioProperties.devices,
                defaultDevice: CoreAudioProperties.defaultDevice,
                setDefault: { CoreAudioProperties.setDefault($1, role: $0) },
                outputVolume: CoreAudioProperties.outputVolume,
                setOutputVolume: CoreAudioProperties.setOutputVolume,
                isMuted: { CoreAudioProperties.isMuted($1, role: $0) },
                setMute: { CoreAudioProperties.setMute($1, role: $0, $2) },
                canSetMute: { CoreAudioProperties.canSetMute($1, role: $0) },
                inputVolume: CoreAudioProperties.inputVolume,
                setInputVolume: CoreAudioProperties.setInputVolume,
                isRunning: CoreAudioProperties.isRunningSomewhere
            ),
            link: LinkOperations(
                isUsable: { $0.isConnected && jabra.isUsable($0) },
                state: { jabra.monitoredState(for: $0) },
                battery: { jabra.batteryLevel(for: $0) }
            ),
            battery: BluetoothBatteryMonitor(),
            isUserPicking: SystemSoundPicker.isInUse
        )
        updates = UpdateChecker(isIdle: { [weak model] in
            model.map { !$0.isMicrophoneMuted && !$0.isInputRecording } ?? true
        })

        audioObserver.onDevicesChanged = { [weak model] in
            model?.handleDevicesChanged()
        }
        audioObserver.onDefaultChanged = { [weak model] role in
            model?.handleDefaultChanged(role)
        }
        audioObserver.onMuteOrVolumeChanged = { [weak model] in
            model?.handleMuteOrVolumeChanged()
        }
        jabra.onLinkChange = { [weak model] in
            model?.handleLinkChanged()
        }
        jabra.onBatteryChange = { [weak model] in
            model?.handleBatteryChanged()
        }
    }

    @discardableResult
    func start() -> Bool {
        jabra.start()
        let isListening = audioObserver.startListening()
        model.start()
        updates.start()
        KeyboardShortcuts.onKeyUp(for: .toggleMicrophoneMute) { [weak model] in
            model?.perform(.toggleMicMute)
        }
        return isListening
    }

    func stop() {
        // Producers first: once they are down, no callback, timeout or debounce
        // can reach the model and restart work it just tore down.
        jabra.stop()
        audioObserver.stopListening()
        model.stop()
    }
}
