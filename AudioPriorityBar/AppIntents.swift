import AppIntents
import AudioPriorityCore

/// The running app's model, set once the runtime exists. macOS may launch the
/// app to run an action before that.
@MainActor
enum IntentTarget {
    static var model: AppModel?

    static func requireModel() throws(ShortcutError) -> AppModel {
        guard let model else { throw .starting }
        return model
    }

    static func devices(_ role: DeviceRole) -> [AudioDevice] {
        guard let model else { return [] }
        let devices = role == .input
            ? model.inputDevices
            : model.speakerDevices + model.headphoneDevices
        return devices.filter { !model.isHidden($0) }
    }
}

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case starting
    case unknownDevice
    case notConnected(String)
    case unknownProfile

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .starting: "Audio Priority Bar is still starting. Try again in a moment."
        case .unknownDevice: "Audio Priority Bar doesn't know this device. Choose it again in the action."
        case .notConnected(let name): "\(name) isn't connected."
        case .unknownProfile: "This profile no longer exists. Choose another in the action."
        }
    }
}

// ponytail: no AppShortcutsProvider, so no Siri phrases or Spotlight tiles.
// Every action is in the Shortcuts editor, and Siri runs any shortcut by its
// name. Add a provider if users ask for zero-setup phrases.

struct OutputDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Output"
    static let defaultQuery = OutputDeviceQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct OutputDeviceQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [OutputDeviceEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [OutputDeviceEntity] {
        IntentTarget.devices(.output).map { OutputDeviceEntity(id: $0.uid, name: $0.name) }
    }
}

struct MicrophoneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Microphone"
    static let defaultQuery = MicrophoneQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct MicrophoneQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MicrophoneEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MicrophoneEntity] {
        IntentTarget.devices(.input).map { MicrophoneEntity(id: $0.uid, name: $0.name) }
    }
}

struct SetOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Output"
    static let description = IntentDescription(
        "Switches the sound to an output, like picking it in the panel."
    )

    @Parameter(title: "Output")
    var device: OutputDeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set output to \(\.$device)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentTarget.requireModel().selectManually(uid: device.id, role: .output)
        return .result()
    }
}

struct SetMicrophoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Microphone"
    static let description = IntentDescription(
        "Switches to a microphone, like picking it in the panel."
    )

    @Parameter(title: "Microphone")
    var device: MicrophoneEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set microphone to \(\.$device)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentTarget.requireModel().selectManually(uid: device.id, role: .input)
        return .result()
    }
}

enum SwitchAction: String, AppEnum {
    case toggle, on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static let caseDisplayRepresentations: [SwitchAction: DisplayRepresentation] = [
        .toggle: "Toggle",
        .on: "Turn On",
        .off: "Turn Off",
    ]
}

struct MicrophoneMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Microphone Mute"
    static let description = IntentDescription("Mutes or unmutes the current microphone.")

    @Parameter(title: "Mute", default: .toggle)
    var action: SwitchAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) microphone mute")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let command: URLCommand = switch action {
        case .toggle: .toggleMicMute
        case .on: .muteMic
        case .off: .unmuteMic
        }
        try IntentTarget.requireModel().perform(command)
        return .result()
    }
}

struct PriorityProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    static let defaultQuery = PriorityProfileQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PriorityProfileQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PriorityProfileEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PriorityProfileEntity] {
        (IntentTarget.model?.profiles ?? []).map {
            PriorityProfileEntity(id: $0.id, name: $0.name)
        }
    }
}

struct ApplyPriorityProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Profile"
    static let description = IntentDescription(
        "Switches to a profile's device orders and automatic switching, and selects its top devices."
    )

    @Parameter(title: "Profile")
    var profile: PriorityProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard try IntentTarget.requireModel().applyProfile(id: profile.id, announces: true) else {
            throw ShortcutError.unknownProfile
        }
        return .result()
    }
}

/// Set in System Settings › Focus. macOS runs it with the chosen profile when
/// the Focus turns on, and with no profile when it ends.
struct ProfileFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Audio Profile"
    static let description: IntentDescription? = IntentDescription(
        "Applies a profile while this Focus is on, and returns to the previous one when it ends."
    )

    @Parameter(title: "Profile")
    var profile: PriorityProfileEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(profile?.name ?? "No profile")")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentTarget.requireModel().applyFocusProfile(profile?.id)
        return .result()
    }
}

struct AutomaticSwitchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Automatic Switching"
    static let description = IntentDescription(
        "Turns automatic switching on, which selects your top devices at once, or off."
    )

    @Parameter(title: "Automatic Switching", default: .toggle)
    var action: SwitchAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) automatic switching")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let command: URLCommand = switch action {
        case .toggle: .toggleAutomatic
        case .on: .enableAutomatic
        case .off: .disableAutomatic
        }
        try IntentTarget.requireModel().perform(command)
        return .result()
    }
}
