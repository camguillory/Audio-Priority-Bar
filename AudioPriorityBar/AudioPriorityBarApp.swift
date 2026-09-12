import AppKit
let appDisplayName = "Audio Priority Bar"

@main
enum AudioPriorityBarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: AppRuntime?
    private var settingsController: SettingsWindowController?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] == nil else {
            return
        }
        configureMainMenu()
        let runtime = AppRuntime()
        let settings = SettingsWindowController(
            model: runtime.model,
            launchAtLogin: LaunchAtLoginController()
        )
        self.runtime = runtime
        settingsController = settings
        statusController = StatusItemController(
            model: runtime.model,
            settings: settings
        )
        if !runtime.start() {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Audio monitoring unavailable"
                alert.informativeText = """
                    Audio Priority Bar loaded the current devices but cannot monitor \
                    audio changes. Quit and reopen the app to try again.
                    """
                alert.runModal()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(
            withTitle: "Quit Audio Priority Bar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showSettings() {
        settingsController?.showSettings()
    }
}
