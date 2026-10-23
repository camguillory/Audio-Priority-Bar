import AppKit
import AudioPriorityCore
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
    /// A URL that launched the app can arrive before the runtime exists.
    private var pendingCommands: [URLCommand] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] == nil else {
            return
        }
        configureMainMenu()
        let runtime = AppRuntime()
        IntentTarget.model = runtime.model
        let settings = SettingsWindowController(
            model: runtime.model,
            launchAtLogin: LaunchAtLoginController(),
            updates: runtime.updates
        )
        self.runtime = runtime
        settingsController = settings
        statusController = StatusItemController(
            model: runtime.model,
            settings: settings,
            updates: runtime.updates
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
        pendingCommands.forEach(runtime.model.perform)
        pendingCommands = []
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let commands = urls.compactMap(URLCommand.init(url:))
        guard let model = runtime?.model else {
            pendingCommands += commands
            return
        }
        commands.forEach(model.perform)
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

        // Text fields take Undo, Copy, Paste and Select All from these items.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

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
