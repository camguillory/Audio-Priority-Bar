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

            Toggle(
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open at Login")
                    Text("Open Audio Priority Bar automatically when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

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

            Toggle(
                isOn: Binding(
                    get: { model.linksMicrophone },
                    set: { model.setLinksMicrophone($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Move microphone with output")
                    Text("When an output has its own microphone, switch both together.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

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
        .frame(width: 380)
        .onAppear { launchAtLogin.refresh() }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel, launchAtLogin: LaunchAtLoginController) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(appDisplayName) Settings"
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                model: model,
                launchAtLogin: launchAtLogin
            )
        )
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}
