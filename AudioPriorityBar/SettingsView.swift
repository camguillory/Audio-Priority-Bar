import AppKit
import AudioPriorityCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updates: UpdateChecker

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
            Section("Startup") {
                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )) {
                    Text("Open at Login")
                    Text("Open Audio Priority Bar automatically when you log in.")
                }

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

            Section("Devices") {
                Toggle(isOn: Binding(
                    get: { model.selectsPairedDevice },
                    set: { model.setSelectsPairedDevice($0) }
                )) {
                    Text("Select headset input and output together")
                    Text("Choosing either one also selects the other.")
                }

                Toggle(isOn: Binding(
                    get: { model.hideNewDisplayOutputs },
                    set: { model.setHideNewDisplayOutputs($0) }
                )) {
                    Text("Hide new HDMI and DisplayPort outputs")
                    Text("""
                        Monitor and TV speakers stay hidden until you turn on \
                        “Show hidden and disconnected devices” in the panel.
                        """)
                }
            }

            Section("Notices") {
                Toggle(isOn: Binding(
                    get: { model.showsSwitchNotice },
                    set: { model.setShowsSwitchNotice($0) }
                )) {
                    Text("Show a notice when switching automatically")
                    Text("Briefly shows the new device below the menu bar icon.")
                }

                Toggle(isOn: Binding(
                    get: { model.remindsWhenMuted },
                    set: { model.setRemindsWhenMuted($0) }
                )) {
                    Text("Remind me when an app records while muted")
                    Text("""
                        Shows “Microphone muted” below the menu bar icon while \
                        an app uses the muted microphone.
                        """)
                }
            }

            Section("Menu Bar") {
                Toggle(isOn: Binding(
                    get: { model.outlinesMenuBarIcon },
                    set: { model.setOutlinesMenuBarIcon($0) }
                )) {
                    Text("Outline the menu bar icon")
                    Text("Tells it apart from the Sound icon, which shows the same device.")
                }

                Picker(selection: Binding(
                    get: { model.menuBarDevices },
                    set: { model.setMenuBarDevices($0) }
                )) {
                    Text("Output only").tag(MenuBarDevices.outputOnly)
                    Text("Both").tag(MenuBarDevices.both)
                    Text("Both, labeled").tag(MenuBarDevices.bothLabeled)
                } label: {
                    Text("Menu bar icon shows")
                    Text("Both adds the microphone. Labels help when the two icons look alike.")
                }
            }

            Section("Updates") {
                if updates.isAvailable {
                    Toggle(isOn: Binding(
                        get: { updates.automaticUpdatesEnabled },
                        set: { updates.setAutomaticUpdatesEnabled($0) }
                    )) {
                        Text("Install updates automatically")
                        Text("""
                            Checks GitHub daily, installs new versions in the \
                            background, and restarts the app.
                            """)
                    }

                    Button("Check for Updates…") { updates.checkForUpdates() }
                } else {
                    Text("Updates are off in development builds.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appDisplayName).font(.headline)
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Link("Project Home Page", destination: Self.homePageURL)
                    }

                    Spacer()

                    Button("Quit Audio Priority Bar") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 460)
        .onAppear { launchAtLogin.refresh() }
        // Approving in System Settings happens while this window stays open.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in launchAtLogin.refresh() }
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
        let hostingController = NSHostingController(
            rootView: SettingsView(
                model: model,
                launchAtLogin: launchAtLogin,
                updates: updates
            )
        )
        // Gives the window its real size before it is ever placed, so the
        // first open on another screen is centered on the actual height.
        hostingController.sizingOptions = [.preferredContentSize]
        window.contentViewController = hostingController
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
