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
                .foregroundStyle(.primary)
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
        } footer: {
            Text("Each profile keeps its own device and microphone orders and whether automatic switching is on. Rearranging the panel changes the profile in use.")
                .foregroundStyle(.secondary)
        }

        Section {
            LabeledContent {
                Button("Open Focus Settings") {
                    NSWorkspace.shared.open(Self.focusSettingsURL)
                }
            } label: {
                Text("Apply one with a Focus")
                Text("Add Audio Priority Bar under Focus filters. The profile from before returns when the Focus ends. Shortcuts also has an Apply Profile action.")
            }
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

/// One profile: its name, edited in place, and the buttons to use or delete it.
private struct ProfileRow: View {
    @Bindable var model: AppModel
    let profile: PriorityProfile
    let isActive: Bool
    let canDelete: Bool
    @State private var name = ""
    @State private var isConfirmingDelete = false
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .opacity(isActive ? 1 : 0)
                .accessibilityHidden(true)
            // A grouped form would show a label and push the name to the right.
            TextField("Profile name", text: $name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .focused($isEditing)
                .onSubmit(commit)
                .onChange(of: isEditing) { _, editing in if !editing { commit() } }
                .accessibilityLabel(isActive ? "\(profile.name), in use" : profile.name)
            Spacer()
            Button("Use") { model.applyProfile(id: profile.id) }
                .disabled(isActive)
            Button("Delete", role: .destructive) { isConfirmingDelete = true }
                .disabled(!canDelete)
                .accessibilityLabel("Delete \(profile.name)")
        }
        .confirmationDialog(
            "Delete \(profile.name)?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) { model.deleteProfile(profile.id) }
        } message: {
            Text("Its device and microphone orders are removed. Devices stay as they are in the other profiles.")
        }
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { _, new in name = new }
    }

    private func commit() {
        guard name != profile.name else { return }
        model.renameProfile(profile.id, to: name)
        name = model.profiles.first { $0.id == profile.id }?.name ?? name
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
    func showSettings(on screen: NSScreen? = nil) {
        NSApp.activate(ignoringOtherApps: true)
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
