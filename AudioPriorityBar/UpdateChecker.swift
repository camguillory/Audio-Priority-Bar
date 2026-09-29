import AppKit
import Observation
import Sparkle

/// Keeps the app current through Sparkle: with automatic updates on, a new
/// release is downloaded, verified against `SUPublicEDKey`, installed and
/// relaunched without asking. Turning them off leaves only manual checks.
@MainActor
@Observable
final class UpdateChecker: NSObject {
    /// Keys written by the GitHub API checker that Sparkle replaced.
    private enum LegacyKey {
        static let automaticChecksEnabled = "automaticUpdateChecksEnabled"
        static let lastNotifiedVersion = "lastNotifiedUpdateVersion"
    }

    /// Only release packaging sets a feed, so local builds never replace
    /// themselves with the published release.
    let isAvailable: Bool
    private(set) var automaticUpdatesEnabled = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        isAvailable = !feed.isEmpty
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func start() {
        guard isAvailable else { return }
        let updater = controller.updater
        // Honor an opt-out made before Sparkle, then forget the old keys.
        if defaults.object(forKey: LegacyKey.automaticChecksEnabled) as? Bool == false {
            updater.automaticallyChecksForUpdates = false
        }
        defaults.removeObject(forKey: LegacyKey.automaticChecksEnabled)
        defaults.removeObject(forKey: LegacyKey.lastNotifiedVersion)
        controller.startUpdater()
        automaticUpdatesEnabled = updater.automaticallyChecksForUpdates
            && updater.automaticallyDownloadsUpdates
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        guard isAvailable, enabled != automaticUpdatesEnabled else { return }
        automaticUpdatesEnabled = enabled
        controller.updater.automaticallyChecksForUpdates = enabled
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        // An accessory app is never frontmost on its own, so Sparkle's window
        // would open behind whatever the user is working in.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension UpdateChecker: SPUUpdaterDelegate {
    /// Sparkle would otherwise wait for a quit that a menu bar app rarely
    /// sees, so a downloaded update is installed and relaunched right away.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        immediateInstallHandler()
        return true
    }
}
