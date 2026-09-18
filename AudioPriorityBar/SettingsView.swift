import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var launchAtLogin: LaunchAtLoginController

    private var version: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Startup")
                .font(.headline)

            SettingSwitch(
                title: "Open at Login",
                explanation: "Open Audio Priority Bar automatically when you log in.",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )

            if launchAtLogin.requiresApproval {
                Text("Approval required in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = launchAtLogin.errorMessage {
                Text("Open at Login failed: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            Text("Devices")
                .font(.headline)

            SettingSwitch(
                title: "Select headset input and output together",
                explanation: "Choosing either one also selects the other.",
                isOn: Binding(
                    get: { model.selectsPairedDevice },
                    set: { model.setSelectsPairedDevice($0) }
                )
            )

            SettingSwitch(
                title: "Hide new HDMI and DisplayPort outputs",
                explanation: """
                    A monitor or TV's speakers are rarely what you want, so \
                    these stay hidden until shown from Show hidden and \
                    disconnected devices.
                    """,
                isOn: Binding(
                    get: { model.hideNewDisplayOutputs },
                    set: { model.setHideNewDisplayOutputs($0) }
                )
            )

            Divider()

            Text("About")
                .font(.headline)

            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appDisplayName).font(.headline)
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Quit Audio Priority Bar") { NSApp.terminate(nil) }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420)
        .onAppear { launchAtLogin.refresh() }
    }
}

/// A switch whose explanation wraps instead of being squeezed into whatever
/// room is left beside the control, which truncated the longer descriptions.
private struct SettingSwitch: View {
    let title: String
    let explanation: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The switch carries both strings, so reading them again here
            // would announce everything twice.
            .accessibilityHidden(true)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityHint(explanation)
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

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel, launchAtLogin: LaunchAtLoginController) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(appDisplayName) Settings"
        let hostingController = NSHostingController(
            rootView: SettingsView(
                model: model,
                launchAtLogin: launchAtLogin
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
