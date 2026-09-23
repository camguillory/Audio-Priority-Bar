import Foundation
import Testing
@testable import AudioPriorityBar

@Test
func applicationIdentityIsStable() {
    #expect(Bundle.main.bundleIdentifier == "app.audioprioritybar")
    #expect(appDisplayName == "Audio Priority Bar")
}

@Test
@MainActor
func newerStableVersionIsFoundOnlyForNewerStableTags() {
    #expect(
        UpdateChecker.newerStableVersion(inTag: "v2.10.0", than: "2.9.0") == "2.10.0"
    )
    #expect(UpdateChecker.newerStableVersion(inTag: "v2.2.0", than: "2.2.0") == nil)
    #expect(UpdateChecker.newerStableVersion(inTag: "v2.1.0", than: "2.2.0") == nil)
    #expect(
        UpdateChecker.newerStableVersion(inTag: "v2.3.0-rc.1", than: "2.2.0") == nil
    )
    #expect(UpdateChecker.newerStableVersion(inTag: "latest", than: "2.2.0") == nil)
}

@Test
@MainActor
func releaseDecodingPicksTheArchiveAndFallsBackWithoutAssets() throws {
    let withAssets = try #require("""
        {
          "tag_name": "v2.3.0",
          "html_url": "https://github.com/camguillory/Audio-Priority-Bar/releases/tag/v2.3.0",
          "assets": [
            {
              "name": "AudioPriorityBar.zip.sha256",
              "browser_download_url": "https://github.com/camguillory/Audio-Priority-Bar/releases/download/v2.3.0/AudioPriorityBar.zip.sha256"
            },
            {
              "name": "AudioPriorityBar.zip",
              "browser_download_url": "https://github.com/camguillory/Audio-Priority-Bar/releases/download/v2.3.0/AudioPriorityBar.zip"
            }
          ]
        }
        """.data(using: .utf8))
    let release = try UpdateChecker.LatestRelease.release(from: withAssets)
    #expect(release.downloadURL == URL(
        string: "https://github.com/camguillory/Audio-Priority-Bar/releases/download/v2.3.0/AudioPriorityBar.zip"
    ))

    let withoutAssets = try #require("""
        {
          "tag_name": "v2.3.0",
          "html_url": "https://github.com/camguillory/Audio-Priority-Bar/releases/tag/v2.3.0",
          "assets": []
        }
        """.data(using: .utf8))
    let fallback = try UpdateChecker.LatestRelease.release(from: withoutAssets)
    #expect(fallback.downloadURL == URL(
        string: "https://github.com/camguillory/Audio-Priority-Bar/releases/tag/v2.3.0"
    ))
}

@Test
@MainActor
func launchAtLoginShowsApprovalAndRegistrationErrors() {
    let approval = LaunchAtLoginController(
        status: { .requiresApproval },
        register: {},
        unregister: {}
    )
    #expect(approval.isEnabled)
    #expect(approval.requiresApproval)
    approval.setEnabled(false)
    #expect(!approval.isEnabled)
    #expect(!approval.requiresApproval)

    enum TestError: Error { case failed }
    var registered = false
    let failure = LaunchAtLoginController(
        status: { registered ? .enabled : .notRegistered },
        register: { throw TestError.failed },
        unregister: {}
    )
    failure.setEnabled(true)
    #expect(failure.errorMessage != nil)

    registered = true
    failure.refresh()
    #expect(failure.errorMessage == nil)
}
