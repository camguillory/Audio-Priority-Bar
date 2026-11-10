import AppKit
import AudioPriorityCore
import CoreBluetooth
import IOKit.hid
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
                isRunning: CoreAudioProperties.isRunningSomewhere,
                appRecording: CoreAudioProperties.appRecording
            ),
            link: LinkOperations(
                isUsable: { $0.isConnected && jabra.isUsable($0) },
                state: { jabra.monitoredState(for: $0) },
                battery: { jabra.batteryLevel(for: $0) },
                headsetControls: { jabra.headsetControls(for: $0) },
                setNoiseMode: { jabra.setNoiseMode($0, for: $1) },
                setSidetone: { jabra.setSidetone($0, for: $1) },
                setBusy: { jabra.setBusy($0, for: $1) },
                endHeadsetCall: { jabra.endHeadsetCall(for: $0) },
                refreshHeadsetControls: { jabra.refreshHeadsetControls() }
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
        jabra.onHeadsetChange = { [weak model] in
            model?.handleHeadsetChanged()
        }

        // Turned on before Settings and the menu bar item exist, so their
        // first lines are kept too.
        let previous = DebugLog.shared.lastMessage
        DebugLog.shared.isEnabled = model.keepsDebugLog
        if let previous, ![Self.quitMessage, "debug log turned off"].contains(previous) {
            DebugLog.shared.write("the previous run ended without quitting: it crashed, was stopped, or the Mac lost power")
        }
        DebugLog.shared.write("started")
    }

    @discardableResult
    func start() -> Bool {
        observeSystem()
        jabra.start()
        let isListening = audioObserver.startListening()
        if !isListening { DebugLog.shared.write("CoreAudio listeners failed to start") }
        model.start()
        model.logSnapshot()
        updates.start()
        KeyboardShortcuts.onKeyUp(for: .toggleMicrophoneMute) { [weak model] in
            DebugLog.shared.write("pressed the mute shortcut")
            model?.perform(.toggleMicMute)
        }
        return isListening
    }

    func stop() {
        DebugLog.shared.write("quitting")
        model.releaseAutomaticBusylights()
        // Producers first: once they are down, no callback, timeout or debounce
        // can reach the model and restart work it just tore down.
        jabra.stop()
        audioObserver.stopListening()
        model.stop()
        DebugLog.shared.write(Self.quitMessage)
    }

    /// The last line of a run that quit, so the next start can tell a crash.
    private static let quitMessage = "quit cleanly"

    private var loggedPermissions = Permissions.summary()

    /// Sleep, wake, the screen and the user session, around which devices
    /// often come and go, and permissions changed in System Settings.
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, message) in [
            (NSWorkspace.willSleepNotification, "the Mac is going to sleep"),
            (NSWorkspace.didWakeNotification, "the Mac woke up"),
            (NSWorkspace.screensDidSleepNotification, "the displays slept"),
            (NSWorkspace.screensDidWakeNotification, "the displays woke"),
            (NSWorkspace.sessionDidResignActiveNotification, "switched to another user"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "switched back to this user"),
        ] {
            _ = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    DebugLog.shared.write(message)
                    self?.logPermissionChanges()
                }
            }
        }
        for (name, message) in [
            ("com.apple.screenIsLocked", "the screen locked"),
            ("com.apple.screenIsUnlocked", "the screen unlocked"),
        ] {
            _ = DistributedNotificationCenter.default().addObserver(
                forName: .init(name), object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { DebugLog.shared.write(message) }
            }
        }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.logPermissionChanges() }
        }
    }

    private func logPermissionChanges() {
        let current = Permissions.summary()
        guard current != loggedPermissions else { return }
        loggedPermissions = current
        DebugLog.shared.write("permissions changed: \(current)")
    }
}

/// What the app is allowed to do, read without asking for anything.
enum Permissions {
    static func summary() -> String {
        let inputMonitoring = switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: "allowed"
        case kIOHIDAccessTypeDenied: "denied"
        default: "not asked"
        }
        let bluetooth = switch CBManager.authorization {
        case .allowedAlways: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked"
        @unknown default: "unknown"
        }
        return "Input Monitoring \(inputMonitoring), Accessibility \(AXIsProcessTrusted() ? "allowed" : "not allowed"), Bluetooth \(bluetooth)"
    }
}
