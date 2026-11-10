import AppKit
import AudioPriorityCore
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
    /// Update checkers such as Latest poll `SUFeedURL`, so the app polls its own
    /// copy and download counts tell running copies apart from them.
    private let appFeed: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isIdle: () -> Bool
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        isIdle: @escaping () -> Bool = { true }
    ) {
        self.defaults = defaults
        self.isIdle = isIdle
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        isAvailable = !feed.isEmpty
        appFeed = Self.appFeed(from: feed)
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

    /// Quitting releases any microphone mute the app applied, so a restart
    /// waits until the microphone is neither muted nor recording.
    func installWhenIdle(_ install: @escaping () -> Void) {
        pendingInstall = install
        idleTask?.cancel()
        // ponytail: polls once a minute rather than observing the model, so
        // an update can land up to a minute after a call ends.
        idleTask = Task { @MainActor [weak self] in
            while let self, self.pendingInstall != nil, !Task.isCancelled {
                self.installPendingUpdateIfIdle()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func installPendingUpdateIfIdle() {
        guard let install = pendingInstall, isIdle() else { return }
        DebugLog.shared.write("installing the update and relaunching")
        pendingInstall = nil
        install()
    }

    /// The release workflow uploads `appcast-app.xml` next to `appcast.xml`.
    nonisolated static func appFeed(from feed: String) -> String? {
        guard !feed.isEmpty, let url = URL(string: feed) else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("appcast-app.xml").absoluteString
    }
}

extension UpdateChecker: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        appFeed
    }

    /// Sparkle would otherwise wait for a quit that a menu bar app rarely
    /// sees, so a downloaded update is installed and relaunched once idle.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        DebugLog.shared.write("update \(item.displayVersionString) ready, installing once the microphone is neither muted nor recording")
        installWhenIdle(immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DebugLog.shared.write("update check found \(item.displayVersionString)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DebugLog.shared.write("update check found nothing newer")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        DebugLog.shared.write("update \(item.displayVersionString) downloaded")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        DebugLog.shared.write("installing update \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        DebugLog.shared.write("update stopped: \(error.localizedDescription)")
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        DebugLog.shared.write("update check (\(updateCheck == .updatesInBackground ? "background" : "asked for")) finished\(error.map { ": \($0.localizedDescription)" } ?? "")")
    }
}
