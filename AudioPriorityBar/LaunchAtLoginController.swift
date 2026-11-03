import AudioPriorityCore
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
    @ObservationIgnored private var loggedStatus: SMAppService.Status?

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
        if current != loggedStatus {
            loggedStatus = current
            DebugLog.shared.write("Open at Login: \(Self.describe(current))")
        }
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
            DebugLog.shared.write("Open at Login could not \(enabled ? "register" : "unregister"): \(error.localizedDescription)")
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

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "off"
        case .enabled: "on"
        case .requiresApproval: "waiting for approval in Login Items"
        case .notFound: "not found"
        @unknown default: "status \(status.rawValue)"
        }
    }
}
