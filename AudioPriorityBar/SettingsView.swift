import AppKit
import AudioPriorityCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// The tabs of the Settings window, in toolbar order.
enum SettingsPane: CaseIterable {
    case menuBar, devices, profiles, shortcuts, app

    var label: String {
        switch self {
        case .menuBar: "Menu Bar"
        case .devices: "Devices"
        case .profiles: "Profiles"
        case .shortcuts: "Shortcuts"
        case .app: "App"
        }
    }

    var symbol: String {
        switch self {
        case .menuBar: "menubar.rectangle"
        case .devices: "hifispeaker.2"
        case .profiles: "rectangle.stack"
        case .shortcuts: "command"
        case .app: "gearshape"
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

    private static let homePageURL = URL(
        string: "https://github.com/camguillory/Audio-Priority-Bar/"
    )!

    private var version: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
    }

    var body: some View {
        Form {
            switch pane {
            case .menuBar: menuBar
            case .devices: devices
            case .profiles: profiles
            case .shortcuts: shortcuts
            case .app: app
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 460)
        // Each tab is as tall as its content, so the window resizes to fit it.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var menuBar: some View {
        Section { menuBarPreview }

        Section("Icon") {
            Picker("Shows", selection: Binding(
                get: { model.menuBarDevices },
                set: { model.setMenuBarDevices($0) }
            )) {
                Text("Output only").tag(MenuBarDevices.outputOnly)
                Text("Output and microphone").tag(MenuBarDevices.both)
                Text("Output and microphone, labeled").tag(MenuBarDevices.bothLabeled)
            }

            Toggle("Outline", isOn: Binding(
                get: { model.outlinesMenuBarIcon },
                set: { model.setOutlinesMenuBarIcon($0) }
            ))

            Toggle(isOn: Binding(
                get: { model.showsMenuBarVolume },
                set: { model.setShowsMenuBarVolume($0) }
            )) {
                Text("Volume level")
                Text("Shown beside AirPods and other device icons.")
            }

            Toggle("Pulse muted microphone", isOn: Binding(
                get: { model.pulsesMutedMicrophone },
                set: { model.setPulsesMutedMicrophone($0) }
            ))

            Toggle(isOn: Binding(
                get: { model.redIconWhenManual },
                set: { model.setRedIconWhenManual($0) }
            )) {
                Text("Red while automatic switching is off")
                Text("A reminder to turn it back on.")
            }
        }

        Section("Notices") {
            Toggle("Show a notice when switching automatically", isOn: Binding(
                get: { model.showsSwitchNotice },
                set: { model.setShowsSwitchNotice($0) }
            ))

            Toggle("Remind me when an app records while muted", isOn: Binding(
                get: { model.remindsWhenMuted },
                set: { model.setRemindsWhenMuted($0) }
            ))
        }

        Section("Hover preview") {
            LabeledContent {
                if isAccessibilityTrusted {
                    Text("Allowed").foregroundStyle(.secondary)
                } else {
                    Button("Allow…") {
                        AXIsProcessTrustedWithOptions(
                            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        )
                    }
                }
            } label: {
                Text("Show only over the icon")
                Text("Needs Accessibility. Without it, the preview also opens over \(Image(systemName: "chevron.left.2")) when macOS hides the icon.")
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
            Image(systemName: "speaker.wave.2.fill")
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
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
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
            }
            Button("Add Profile") { model.addProfile() }
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a copy of the profile in use (⌘N)")
        } footer: {
            Text("Each profile keeps its own device and microphone orders and whether automatic switching is on. Rearranging the panel changes the profile in use. Click a name to rename it.")
                .foregroundStyle(.secondary)
        }

        Section {
            LabeledContent {
                Button("Open Focus Settings…") {
                    NSWorkspace.shared.open(Self.focusSettingsURL)
                }
            } label: {
                Text("Switch profiles with a Focus")
                Text("In System Settings › Focus, choose a Focus such as Work, click Add Filter, choose Audio Priority Bar, and pick a profile. That profile is used while the Focus is on, and your previous one comes back when it ends.")
            }
        } footer: {
            Text("Or apply a profile from Shortcuts with the Apply Profile action.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var shortcuts: some View {
        Section {
            LabeledContent("Mute microphone") {
                KeyboardShortcuts.Recorder(for: .toggleMicrophoneMute)
            }
        }

        Section {
            ForEach(URLCommand.allCases, id: \.self) { command in
                let url = "\(URLCommand.scheme)://\(command.rawValue)"
                LabeledContent {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    .accessibilityLabel("Copy \(url)")
                } label: {
                    Text(command.title)
                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("URLs")
        } footer: {
            Text("Open them from Shortcuts, Raycast, a Stream Deck or Terminal. Shortcuts also has actions to set the output or microphone.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var app: some View {
        Section {
            Toggle("Open at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
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
                    set: { updates.setAutomaticUpdatesEnabled($0) }
                )) {
                    Text("Install updates automatically")
                    Text("Checks daily and restarts the app after installing.")
                }

                Button("Check for Updates…") { updates.checkForUpdates() }
            } else {
                Text("Updates are off in development builds.")
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("Version \(version)").foregroundStyle(.secondary)
                Link("Home Page", destination: Self.homePageURL)
                Spacer()
                Button("Quit Audio Priority Bar") { NSApp.terminate(nil) }
            }
        }
    }

    @ViewBuilder private var devices: some View {
        Section {
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

            Toggle(isOn: Binding(
                get: { model.hideNewDisplayOutputs },
                set: { model.setHideNewDisplayOutputs($0) }
            )) {
                Text("Hide new HDMI and DisplayPort outputs")
                Text("Find them under “Show hidden and disconnected devices” in the panel.")
            }

            Toggle(isOn: Binding(
                get: { model.mutesSpeakersWhenHeadphonesDisconnect },
                set: { model.setMutesSpeakersWhenHeadphonesDisconnect($0) }
            )) {
                Text("Mute speakers when headphones disconnect")
                Text("Including when they're turned off or run out of battery.")
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

private extension View {
    /// The shape a profile name sits in: a tint under the pointer, an
    /// outline while it is being renamed, and the same size in both so the
    /// row never moves.
    func nameFrame(isHovering: Bool, isRenaming: Bool) -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Color.primary.opacity(isHovering ? 0.1 : 0),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(isRenaming ? 0.8 : 0), lineWidth: 2)
            )
            // Keeps the text where it sits in the rows around it.
            .padding(.leading, -6)
            .contentShape(Rectangle())
    }
}

/// One profile: its name, renamed in place, and the buttons to use or delete it.
private struct ProfileRow: View {
    @Bindable var model: AppModel
    let profile: PriorityProfile
    let isActive: Bool
    let canDelete: Bool
    @State private var name = ""
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var clickMonitor: Any?
    @State private var isConfirmingDelete = false
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .opacity(isActive ? 1 : 0)
                .accessibilityHidden(true)
            nameField
            Spacer(minLength: 8)
            if isActive {
                Text("In Use").foregroundStyle(.secondary)
            } else {
                Button("Use") { model.applyProfile(id: profile.id) }
                    .accessibilityLabel("Use \(profile.name)")
            }
            Button("Delete", role: .destructive) { isConfirmingDelete = true }
                .disabled(!canDelete)
                .help(canDelete ? "Delete this profile" : "The last profile can't be deleted")
                .accessibilityLabel("Delete \(profile.name)")
        }
        .confirmationDialog(
            "Delete \(profile.name)?",
            isPresented: $isConfirmingDelete
        ) {
            // Return deletes and Escape cancels. A destructive role would draw
            // the default button blue at rest and red while pressed.
            Button("Delete") { model.deleteProfile(profile.id) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("Its device and microphone orders are removed. Devices stay as they are in the other profiles.")
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

    /// Plain text at rest, so the list reads cleanly and nothing takes focus
    /// when Settings opens. Under the pointer it shows a field and a pencil;
    /// a click, or Space once Tab has reached it, swaps in a text field with
    /// the name selected, as renaming in place works in Finder. Return or a
    /// click elsewhere saves, Escape cancels.
    @ViewBuilder private var nameField: some View {
        if isRenaming {
            // A grouped form would show a label and push the name right.
            TextField("Profile name", text: $name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .fixedSize()
                .frame(minWidth: 80, alignment: .leading)
                .focused($isEditing)
                .onSubmit(finishRenaming)
                .onExitCommand(perform: cancelRenaming)
                .onChange(of: isEditing) { _, editing in
                    if !editing { finishRenaming() }
                }
                .onAppear(perform: focusField)
                .nameFrame(isHovering: false, isRenaming: true)
                .help("Press Return to save or Escape to cancel")
        } else {
            Button(action: beginRenaming) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .frame(minWidth: 80, alignment: .leading)
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(isHovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .nameFrame(isHovering: isHovering, isRenaming: false)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .help("Click to rename")
            .accessibilityLabel(isActive ? "\(profile.name), in use" : profile.name)
            .accessibilityHint("Renames the profile.")
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
    init(
        model: AppModel,
        launchAtLogin: LaunchAtLoginController,
        updates: UpdateChecker
    ) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(appDisplayName) Settings"
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let hostingController = NSHostingController(
                rootView: SettingsView(
                    model: model,
                    launchAtLogin: launchAtLogin,
                    updates: updates,
                    pane: pane
                )
            )
            // Gives the window its real size before it is ever placed, so the
            // first open on another screen is centered on the actual height.
            hostingController.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hostingController)
            item.label = pane.label
            item.image = NSImage(
                systemSymbolName: pane.symbol,
                accessibilityDescription: nil
            )
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.toolbarStyle = .preference
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
        NSApp.activate(ignoringOtherApps: true)
        if let pane,
           let tabs = window?.contentViewController as? NSTabViewController,
           let index = SettingsPane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = index
        }
        if let window, let screen = screen ?? NSScreen.main,
           let origin = SettingsPlacement.origin(
               forWindow: window.frame,
               screenFrame: screen.frame,
               visibleFrame: screen.visibleFrame
           ) {
            window.setFrameOrigin(origin)
        }
        showWindow(nil)
    }
}
