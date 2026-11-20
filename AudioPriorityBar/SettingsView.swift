import AppKit
import AudioPriorityCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

enum SettingsPane: CaseIterable {
    case devices, profiles, menuBar, shortcuts, activity, diagnostics, app

    var label: String {
        switch self {
        case .menuBar: "Menu Bar"
        case .devices: "Devices"
        case .profiles: "Profiles"
        case .shortcuts: "Shortcuts"
        case .activity: "Switch History"
        case .diagnostics: "Diagnostics"
        case .app: "General"
        }
    }

    var symbol: String {
        switch self {
        case .menuBar: "menubar.rectangle"
        case .devices: "hifispeaker.2"
        case .profiles: "rectangle.stack"
        case .shortcuts: "command"
        case .activity: "clock.arrow.circlepath"
        case .diagnostics: "stethoscope"
        case .app: "gearshape"
        }
    }
}

@MainActor
@Observable
private final class SettingsNavigation {
    var pane: SettingsPane = .devices
}

private struct SettingsWindowContent: View {
    @Bindable var navigation: SettingsNavigation
    let model: AppModel
    let launchAtLogin: LaunchAtLoginController
    let updates: UpdateChecker

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $navigation.pane) {
                Section("Audio") {
                    destinations([.devices, .profiles, .activity])
                }
                Section("Preferences") {
                    destinations([.menuBar, .shortcuts, .app, .diagnostics])
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Settings categories")
            .frame(width: 166)

            Divider()
            SettingsView(model: model, launchAtLogin: launchAtLogin, updates: updates, pane: navigation.pane)
                .id(navigation.pane)
        }
        .frame(minWidth: 638, minHeight: 340)
    }

    private func destinations(_ panes: [SettingsPane]) -> some View {
        ForEach(panes, id: \.self) { pane in
            Label(pane.label, systemImage: pane.symbol).tag(pane)
        }
    }
}

private extension URLCommand {
    var title: String {
        switch self {
        case .toggleMicMute: "Toggle microphone mute"
        case .muteMic: "Mute microphone"
        case .unmuteMic: "Unmute microphone"
        case .toggleAutomatic: "Toggle automatic switching"
        case .enableAutomatic: "Turn automatic switching on"
        case .disableAutomatic: "Turn automatic switching off"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updates: UpdateChecker
    let pane: SettingsPane
    @State private var isAccessibilityTrusted = false
    @State private var isConfirmingClear = false
    @State private var copiedText: String?
    @State private var isExporting = false
    @State private var exportError: String?
    /// Bumped by Clear, so the size shows zero at once.
    @State private var logRevision = 0

    private static let homePageURL = URL(
        string: "https://github.com/anazaryan-krisp/Audio-Priority-Bar/"
    )!

    private var version: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pane.label)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 4)

            ScrollViewReader { proxy in
                Form {
                    switch pane {
                    case .menuBar: menuBar
                    case .devices: devices
                    case .profiles: profiles
                    case .shortcuts: shortcuts
                    case .activity: activity
                    case .diagnostics: diagnostics
                    case .app: app
                    }
                }
                .formStyle(.grouped)
                .toggleStyle(.switch)
                .onChange(of: model.renamingProfileID) { _, id in
                    if pane == .profiles, let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: copiedText) {
            guard copiedText != nil else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copiedText = nil
            } catch {}
        }
    }

    @ViewBuilder private var menuBar: some View {
        Section("Live preview") { menuBarPreview }

        Section("Icon") {
            Picker("Devices shown", selection: Binding(
                get: { model.menuBarDevices },
                set: { model.setMenuBarDevices($0) }
            )) {
                Text("Output only").tag(MenuBarDevices.outputOnly)
                Text("Output and microphone").tag(MenuBarDevices.both)
                Text("Output and microphone, labeled").tag(MenuBarDevices.bothLabeled)
            }

            Toggle("Outline the menu bar icon", isOn: Binding(
                get: { model.outlinesMenuBarIcon },
                set: { model.setOutlinesMenuBarIcon($0) }
            ))

            Toggle(isOn: Binding(
                get: { model.showsMenuBarVolume },
                set: { model.setShowsMenuBarVolume($0) }
            )) {
                Text("Show volume beside the output icon")
                Text("Available for device icons with adjustable volume.")
            }

            Toggle("Pulse the microphone icon when muted", isOn: Binding(
                get: { model.pulsesMutedMicrophone },
                set: { model.setPulsesMutedMicrophone($0) }
            ))

            Toggle(isOn: Binding(
                get: { model.redIconWhenManual },
                set: { model.setRedIconWhenManual($0) }
            )) {
                Text("Use a red background in manual mode")
            }
        }

        Section("Notifications") {
            Toggle("Show a notice when switching automatically", isOn: Binding(
                get: { model.showsSwitchNotice },
                set: { model.setShowsSwitchNotice($0) }
            ))

            Toggle("Remind me when an app records while muted", isOn: Binding(
                get: { model.remindsWhenMuted },
                set: { model.setRemindsWhenMuted($0) }
            ))
        }

        Section("Hover behavior") {
            LabeledContent {
                if isAccessibilityTrusted {
                    Label("Allowed", systemImage: "checkmark").foregroundStyle(.secondary)
                } else {
                    Button("Allow Access…") {
                        DebugLog.shared.write("clicked Allow for Accessibility")
                        AXIsProcessTrustedWithOptions(
                            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        )
                    }
                }
            } label: {
                Text("Limit preview to the audio icon")
                Text("Allow Accessibility access to keep the preview closed when you hover over the menu bar overflow button.")
            }
        }
        .onAppear { isAccessibilityTrusted = AXIsProcessTrusted() }
        // Allowing it in System Settings happens while this window stays open.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in isAccessibilityTrusted = AXIsProcessTrusted() }
    }

    /// The real menu bar icon between the system items it sits beside, so
    /// the icon options show their effect instead of describing it.
    private var menuBarPreview: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            Image(systemName: "switch.2")
            StatusLabel(model: model)
                .foregroundStyle(model.showsRedIconBackground ? Color.white : Color.primary)
                .background {
                    if model.showsRedIconBackground {
                        ManualBackgroundShape().fill(Color(nsColor: StatusItemController.manualBackground))
                    }
                }
            Text(Date.now, format: .dateTime.weekday().hour().minute())
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 8)
        .frame(height: 32)
        .accessibilityHidden(true)
    }

    private static let focusSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Focus-Settings.extension"
    )!

    @ViewBuilder private var profiles: some View {
        Section {
            ForEach(model.profiles) { profile in
                ProfileRow(
                    model: model,
                    profile: profile,
                    isActive: profile.id == model.activeProfileID,
                    canDelete: model.profiles.count > 1
                )
                .id(profile.id)
            }
            Button("Add Profile", systemImage: "plus") { model.addProfile() }
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a copy of the profile in use (⌘N)")
        } header: {
            Text("Your profiles")
        } footer: {
            Text("A new profile starts with a copy of the current one. Changing device priorities or switching mode in the panel updates the profile in use.")
                .foregroundStyle(.secondary)
        }

        Section {
            LabeledContent {
                Button("Focus Settings…") {
                    DebugLog.shared.write("clicked Open Focus Settings")
                    NSWorkspace.shared.open(Self.focusSettingsURL)
                }
            } label: {
                Text("Use a profile during a Focus")
                Text("Choose a Focus, add the Audio Priority Bar filter and pick a profile. Your previous profile returns when the Focus ends.")
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("In Shortcuts, use the Apply Profile action to switch profiles.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var shortcuts: some View {
        Section("Keyboard shortcut") {
            LabeledContent("Toggle microphone mute") {
                KeyboardShortcuts.Recorder(for: .toggleMicrophoneMute)
                    .accessibilityLabel("Shortcut to toggle microphone mute")
            }
        }

        Section {
            ForEach(URLCommand.allCases, id: \.self) { command in
                let url = "\(URLCommand.scheme)://\(command.rawValue)"
                LabeledContent {
                    Button(copiedText == url ? "Copied" : "Copy") {
                        DebugLog.shared.write("copied \(url)")
                        copy(url, identifier: url)
                    }
                    .accessibilityLabel(copiedText == url ? "Copied \(command.title)" : "Copy URL to \(command.title.lowercased())")
                } label: {
                    Text(command.title)
                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Command URLs")
        } footer: {
            Text("Open them from Shortcuts, Raycast, a Stream Deck or Terminal. Shortcuts also has actions to set the output or microphone.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var app: some View {
        Section("Startup") {
            Toggle("Open at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: {
                    DebugLog.shared.write("setting Open at Login = \($0)")
                    launchAtLogin.setEnabled($0)
                }
            ))

            if launchAtLogin.requiresApproval {
                LabeledContent("Approval needed in Login Items") {
                    Button("Open Login Items") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
            if let error = launchAtLogin.errorMessage {
                Text("Open at Login failed: \(error)")
                    .foregroundStyle(.red)
            }
        }
        .onAppear { launchAtLogin.refresh() }
        // Approving in System Settings happens while this window stays open.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in launchAtLogin.refresh() }

        Section("Updates") {
            if updates.isAvailable {
                Toggle(isOn: Binding(
                    get: { updates.automaticUpdatesEnabled },
                    set: {
                        DebugLog.shared.write("setting automatic updates = \($0)")
                        updates.setAutomaticUpdatesEnabled($0)
                    }
                )) {
                    Text("Install updates automatically")
                    Text("Checks daily and restarts the app after installing.")
                }

                Button("Check for Updates…") {
                    DebugLog.shared.write("clicked Check for Updates in Settings")
                    updates.checkForUpdates()
                }
            } else {
                LabeledContent("Update method", value: "Manual")
                Text("Install a new build to update this copy of Audio Priority Bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        Section("About") {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Priority Bar").fontWeight(.medium)
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
                Spacer()
                Link("Project on GitHub", destination: Self.homePageURL)
            }
            Button("Quit Audio Priority Bar") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder private var activity: some View {
        if model.recentSwitches.isEmpty {
            ContentUnavailableView(
                "No switches yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("When the output or microphone changes, its new device and the reason appear here.")
            )
            .frame(maxWidth: .infinity, minHeight: 230)
        } else {
            Section {
                ForEach(Array(model.recentSwitches.enumerated()), id: \.offset) { _, record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: record.role == .input ? "mic" : "speaker.wave.2")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(record.role == .input ? "Microphone" : "Output")
                                    .font(.subheadline)
                                Spacer(minLength: 4)
                                Text(record.date.formatted(
                                    date: Calendar.current.isDateInToday(record.date) ? .omitted : .abbreviated,
                                    time: .standard
                                ))
                                .font(.subheadline.monospacedDigit())
                            }
                            .foregroundStyle(.secondary)
                            Text(record.device).fontWeight(.semibold)
                            Text(record.reason)
                                .foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Recent changes")
            } footer: {
                Text("The most recent 20 switches since launch appear here, newest first.")
            }
        }
    }

    @ViewBuilder private var diagnostics: some View {
        Section {
            LabeledContent {
                Button(copiedText == "diagnostics" ? "Copied" : "Copy Diagnostics") {
                    DebugLog.shared.write("clicked Copy Diagnostics")
                    copy(model.diagnostics, identifier: "diagnostics")
                }
            } label: {
                Text("Diagnostic summary")
                Text("Copy the version, settings, devices and recent switches for a bug report. Names and identifiers are replaced with short tags.")
            }
        }
        Section("Debug log") {
            Toggle(isOn: Binding(
                get: { model.keepsDebugLog },
                set: { model.setKeepsDebugLog($0) }
            )) {
                Text("Keep a debug log on this Mac")
                Text("Records device changes, switches and clicks.")
            }

            TimelineView(.periodic(from: .now, by: 5)) { _ in
                let _ = logRevision
                let log = DebugLog.shared
                let size = log.totalSize
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Saved logs", value: size == 0 ? "None yet" : size.formatted(.byteCount(style: .file)))
                    Text("Logs are kept for \(log.keptDays) days. A redacted export replaces names and identifiers with short tags and is saved to Downloads.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(isExporting ? "Exporting…" : "Export Redacted Log") { exportLog() }
                            .disabled(isExporting)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([log.files.last ?? log.directory])
                        }
                        Spacer()
                        Button("Clear…", role: .destructive) { isConfirmingClear = true }
                            .disabled(isExporting)
                    }
                    .disabled(size == 0)
                }
                .padding(.vertical, 2)
            }
        }
        .alert("Delete all saved logs?", isPresented: $isConfirmingClear) {
            Button("Delete Logs", role: .destructive) {
                model.clearDebugLog()
                logRevision += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved log file from this Mac.")
        }
        .alert("Couldn't export the log", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func copy(_ text: String, identifier: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            copiedText = identifier
        }
    }

    private func exportLog() {
        let log = DebugLog.shared
        log.write("clicked Export Redacted Log")
        let files = log.files
        let names = model.knownDeviceNames
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let url = try await Task.detached {
                    try DebugLog.exportRedacted(files: files, deviceNames: names, to: .downloadsDirectory)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                log.write("could not export the redacted log: \(error)")
                exportError = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var devices: some View {
        Section("Microphone selection") {
            Toggle("Select headset input and output together", isOn: Binding(
                get: { model.selectsPairedDevice },
                set: { model.setSelectsPairedDevice($0) }
            ))

            Toggle(isOn: Binding(
                get: { model.microphonesFollowOutput },
                set: { model.setMicrophonesFollowOutput($0) }
            )) {
                Text("Microphones follow the output")
                Text("Speakers and headphones each keep their own microphone order.")
            }
        }

        Section("Speakers and displays") {
            Toggle(isOn: Binding(
                get: { model.hideNewDisplayOutputs },
                set: { model.setHideNewDisplayOutputs($0) }
            )) {
                Text("Hide new HDMI and DisplayPort outputs")
                Text("To show one again, reveal hidden devices in the menu bar panel.")
            }

            Toggle(isOn: Binding(
                get: { model.mutesSpeakersWhenHeadphonesDisconnect },
                set: { model.setMutesSpeakersWhenHeadphonesDisconnect($0) }
            )) {
                Text("Mute speakers when headphones disconnect")
                Text("Also applies when headphones power off or run out of battery.")
            }
        }

        Section("Jabra headsets") {
            Toggle(isOn: Binding(
                get: { model.lightsBusylightWhileRecording },
                set: { model.setLightsBusylightWhileRecording($0) }
            )) {
                Text("Turn on the busy light when the headset mic is in use")
                Text("Works with browser calls in apps such as Meet and Teams.")
            }
        }
    }
}

enum SettingsPlacement {
    /// Where to move a window so it lands centered on a screen, or nil when it
    /// is already on that screen and whatever the user did with it should be
    /// left alone.
    static func origin(
        forWindow frame: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard !screenFrame.contains(center) else { return nil }
        return NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
    }
}

/// One profile: its name, renamed in place, and the buttons to use or delete it.
private struct ProfileRow: View {
    @Bindable var model: AppModel
    let profile: PriorityProfile
    let isActive: Bool
    let canDelete: Bool
    @State private var name = ""
    @State private var isRenaming = false
    @State private var clickMonitor: Any?
    @State private var isConfirmingDelete = false
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 8) {
            nameField
            Spacer(minLength: 6)
            if isActive {
                Label("In use", systemImage: "checkmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") { model.applyProfile(id: profile.id) }
                    .accessibilityLabel("Use \(profile.name)")
            }
            Menu {
                Button("Rename…") { beginRenaming() }
                Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                    .disabled(!canDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for \(profile.name)")
            .accessibilityLabel("Actions for \(profile.name)")
        }
        .alert("Delete \(profile.name)?", isPresented: $isConfirmingDelete) {
            Button("Delete Profile", role: .destructive) { model.deleteProfile(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes its device priorities. Other profiles keep their settings.")
        }
        .onAppear {
            if model.renamingProfileID == profile.id { startRenaming() }
        }
        .onChange(of: isRenaming) { _, renaming in
            if renaming { saveOnClickOutside() } else { stopWatchingClicks() }
        }
        // Moving to another app or closing Settings keeps what was typed.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification
        )) { _ in finishRenaming() }
        .onDisappear {
            finishRenaming()
            stopWatchingClicks()
        }
        .onChange(of: model.renamingProfileID) { _, id in
            if id == profile.id { startRenaming() }
        }
    }

    @ViewBuilder private var nameField: some View {
        if isRenaming {
            TextField("Profile name", text: $name)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($isEditing)
                .onSubmit(finishRenaming)
                .onExitCommand(perform: cancelRenaming)
                .onChange(of: isEditing) { _, editing in
                    if !editing { finishRenaming() }
                }
                .onAppear(perform: focusField)
                .help("Press Return to save or Escape to cancel")
        } else {
            Button(action: beginRenaming) {
                Text(profile.name)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename \(profile.name)")
            .accessibilityLabel("Rename \(profile.name)")
        }
    }

    /// Opens a profile just added for naming.
    private func startRenaming() {
        model.renamingProfileID = nil
        beginRenaming()
    }

    private func beginRenaming() {
        name = profile.name
        isRenaming = true
    }

    /// Focuses the field once it exists, with the name selected so typing
    /// replaces it.
    private func focusField() {
        DispatchQueue.main.async {
            isEditing = true
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        if name != profile.name { model.renameProfile(profile.id, to: name) }
    }

    private func cancelRenaming() {
        name = profile.name
        isRenaming = false
    }

    /// AppKit leaves a text field focused when a click lands on a button or
    /// on empty space, so a click anywhere outside the field ends the rename
    /// and saves it. The click still goes on to whatever it landed on.
    private func saveOnClickOutside() {
        stopWatchingClicks()
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            if let window = event.window,
               let editor = window.firstResponder as? NSTextView,
               let field = editor.delegate as? NSTextField,
               !field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let navigation = SettingsNavigation()

    init(
        model: AppModel,
        launchAtLogin: LaunchAtLoginController,
        updates: UpdateChecker
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 742, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(appDisplayName) Settings"
        let hosting = NSHostingController(rootView: SettingsWindowContent(
            navigation: navigation, model: model, launchAtLogin: launchAtLogin, updates: updates
        ))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 742, height: 510))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Opens on the screen whose menu bar was used, rather than reappearing
    /// wherever it was last left, which on a multi-screen desk is usually the
    /// wrong one.
    func showSettings(on screen: NSScreen? = nil, pane: SettingsPane? = nil) {
        DebugLog.shared.write("Settings opened\(pane.map { " on \($0.label)" } ?? "")")
        NSApp.activate(ignoringOtherApps: true)
        if let pane { navigation.pane = pane }
        if let window, let screen = screen ?? NSScreen.main,
           let origin = SettingsPlacement.origin(
               forWindow: window.frame,
               screenFrame: screen.frame,
               visibleFrame: screen.visibleFrame
           ) {
            // A window enlarged on an external monitor must still fit the laptop display.
            let centered = NSRect(origin: origin, size: window.frame.size)
            window.setFrame(centered.intersection(screen.visibleFrame), display: false)
        }
        showWindow(nil)
    }
}
