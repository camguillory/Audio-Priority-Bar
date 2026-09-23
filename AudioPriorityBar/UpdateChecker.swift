import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class UpdateChecker {
    enum ManualCheckResult: Equatable {
        case checking
        case upToDate
        case failed
    }

    /// Key for the download URL string in a notification's `userInfo`, read by
    /// `AppDelegate` when the user clicks the notification.
    static let notificationDownloadURLKey = "downloadURL"

    private enum Key {
        static let automaticChecksEnabled = "automaticUpdateChecksEnabled"
        static let lastNotifiedVersion = "lastNotifiedUpdateVersion"
    }

    struct LatestRelease: Decodable {
        let tagName: String
        let htmlUrl: URL
        let assets: [Asset]

        /// The release archive itself, so a click downloads it directly; falls back to the release page if a release ships without one.
        var downloadURL: URL {
            assets.first { $0.name == "AudioPriorityBar.zip" }?.browserDownloadUrl ?? htmlUrl
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        static func release(from data: Data) throws -> LatestRelease {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(LatestRelease.self, from: data)
        }
    }

    private static let releaseAPIURL = URL(
        string: "https://api.github.com/repos/camguillory/Audio-Priority-Bar/releases/latest"
    )!
    private static let checkInterval: Duration = .seconds(24 * 60 * 60)

    var availableVersion: String?
    var downloadURL: URL?
    var manualCheckResult: ManualCheckResult?
    private(set) var automaticChecksEnabled: Bool

    private let defaults: UserDefaults
    private let currentVersion: String
    private var automaticTask: Task<Void, Never>?
    /// In memory only: dismissing quiets this run, but the next launch checks fresh.
    private var dismissedVersion: String?

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        automaticChecksEnabled =
            defaults.object(forKey: Key.automaticChecksEnabled) as? Bool ?? true
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard enabled != automaticChecksEnabled else { return }
        automaticChecksEnabled = enabled
        defaults.set(enabled, forKey: Key.automaticChecksEnabled)
        if enabled {
            scheduleAutomaticChecks()
        } else {
            cancelAutomaticChecks()
        }
    }

    func start() {
        guard automaticChecksEnabled else { return }
        scheduleAutomaticChecks()
    }

    func stop() {
        cancelAutomaticChecks()
    }

    func checkManually() {
        manualCheckResult = .checking
        Task { @MainActor [weak self] in
            await self?.check(manual: true)
        }
    }

    /// Dismissing quiets this run's automatic checks for this version; a manual check still reports the truth.
    func dismissThisVersion() {
        guard let version = availableVersion else { return }
        dismissedVersion = version
        availableVersion = nil
        downloadURL = nil
    }

    private func scheduleAutomaticChecks() {
        cancelAutomaticChecks()
        // Task.sleep's clock advances through system sleep, so a missed day resumes on wake.
        automaticTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.check(manual: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    private func cancelAutomaticChecks() {
        automaticTask?.cancel()
        automaticTask = nil
    }

    private func check(manual: Bool) async {
        do {
            let release = try await Self.fetchLatestRelease()
            guard let newer = Self.newerStableVersion(
                inTag: release.tagName,
                than: currentVersion
            ), manual || newer != dismissedVersion else {
                availableVersion = nil
                downloadURL = nil
                if manual { manualCheckResult = .upToDate }
                return
            }
            availableVersion = newer
            downloadURL = release.downloadURL
            manualCheckResult = nil
            if !manual {
                await notifyOnce(about: newer, url: release.downloadURL)
            }
        } catch {
            // Automatic failures, offline or rate limited, retry tomorrow without
            // surfacing anything; only a user-initiated check reports failure.
            if manual { manualCheckResult = .failed }
        }
    }

    private func notifyOnce(about version: String, url: URL) async {
        guard defaults.string(forKey: Key.lastNotifiedVersion) != version else { return }
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]),
              granted else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(appDisplayName) update available"
        content.body = "Version \(version) is ready. Click to download."
        content.userInfo = [Self.notificationDownloadURLKey: url.absoluteString]
        let request = UNNotificationRequest(
            identifier: "update-available-\(version)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            // Only recorded once delivery actually succeeds, so a denial or
            // delivery error lets the next automatic check try again.
            defaults.set(version, forKey: Key.lastNotifiedVersion)
        } catch {
            // Leave lastNotifiedVersion unset; see the comment above.
        }
    }

    /// The newer stable `vMAJOR.MINOR.PATCH` version from `tag`, or nil if it isn't newer, isn't stable, or carries a prerelease suffix like `-rc.1`.
    static func newerStableVersion(inTag tag: String, than currentVersion: String) -> String? {
        guard tag.hasPrefix("v") else { return nil }
        let candidate = String(tag.dropFirst())
        guard isStableVersion(candidate), isStableVersion(currentVersion) else { return nil }
        guard candidate.compare(currentVersion, options: .numeric) == .orderedDescending else {
            return nil
        }
        return candidate
    }

    private static func isStableVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".")
        return components.count == 3
            && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func fetchLatestRelease() async throws -> LatestRelease {
        var request = URLRequest(url: releaseAPIURL)
        request.setValue("AudioPriorityBar-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try LatestRelease.release(from: data)
    }
}
