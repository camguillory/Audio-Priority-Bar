import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    var isEnabled = false
    var requiresApproval = false
    var errorMessage: String?

    private let status: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(
        status: @escaping () -> SMAppService.Status = {
            SMAppService.mainApp.status
        },
        register: @escaping () throws -> Void = {
            try SMAppService.mainApp.register()
        },
        unregister: @escaping () throws -> Void = {
            try SMAppService.mainApp.unregister()
        }
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
        refresh()
    }

    func refresh() {
        let current = status()
        isEnabled = current == .enabled || current == .requiresApproval
        requiresApproval = current == .requiresApproval
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try enabled ? register() : unregister()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
            return
        }
        if enabled {
            refresh()
        } else {
            isEnabled = false
            requiresApproval = false
            errorMessage = nil
        }
    }
}
