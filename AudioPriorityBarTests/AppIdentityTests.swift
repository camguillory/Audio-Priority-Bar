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
