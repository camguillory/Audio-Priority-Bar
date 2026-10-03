import AudioPriorityCore
import CoreAudio

extension AudioDevice {
    /// The SF Symbol for the kind of hardware, like the macOS Sound menu shows.
    /// Names are checked before the transport type, since a webcam or display
    /// usually connects over USB. `category` is the user's choice, so it
    /// decides headphones over any guess from the name or transport.
    func hardwareIcon(category: OutputCategory?) -> String {
        let name = name.lowercased()

        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if category == .headphone, name.contains("beats") { return "beats.headphones" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if Self.cameraKeywords.contains(where: name.contains) { return "web.camera" }
        if isDisplayOutput || Self.displayKeywords.contains(where: name.contains) {
            return "display"
        }

        if category == .headphone { return "headphones" }

        switch transportType {
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return "waveform"
        case kAudioDeviceTransportTypeBuiltIn:
            // macOS names the Mac's own mic and speakers after the model, like
            // "MacBook Air Microphone". A headphone jack device is also built
            // in but named "External", so it falls through to the role.
            if let mac = Self.macIcons.first(where: { name.contains($0.keyword) }) {
                return mac.icon
            }
            return role == .input ? "mic" : Self.genericSpeakerIcon
        default:
            break
        }

        if role == .input { return "mic" }
        if transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE {
            return "hifispeaker"
        }
        return Self.genericSpeakerIcon
    }

    /// The menu bar shows the Mac's own mic and speakers by role, so the two
    /// stay apart when both are shown and the speaker keeps its volume level.
    func menuBarIcon(category: OutputCategory?) -> String {
        let icon = hardwareIcon(category: category)
        guard Self.macIcons.contains(where: { $0.icon == icon }) else { return icon }
        return role == .input ? "mic" : Self.genericSpeakerIcon
    }

    /// Returned for an output with nothing more specific to show, so the
    /// volume control can swap in its level-based speaker instead.
    static let genericSpeakerIcon = "speaker.wave.2"

    /// Every symbol `menuBarIcon` can return, so the menu bar can reserve
    /// room for the widest one.
    static let hardwareIcons = [
        "airpodsmax", "airpodspro", "airpods", "beats.headphones", "iphone",
        "ipad", "web.camera", "display", "airplayaudio", "waveform", "mic",
        "headphones", "hifispeaker", genericSpeakerIcon,
    ]

    /// Checked in order, so "macbook" wins before any shorter Mac name.
    private static let macIcons: [(keyword: String, icon: String)] = [
        ("macbook", "laptopcomputer"),
        ("imac", "desktopcomputer"),
        ("mac mini", "macmini"),
        ("mac studio", "macstudio"),
        ("mac pro", "macpro.gen3"),
    ]

    private static let cameraKeywords = [
        "camera", "webcam", "brio", "c920", "c922", "kiyo", "facecam", "opal",
    ]

    /// Keywords for displays that use USB.
    /// Note that `isDisplayOutput` covers HDMI and DisplayPort.
    /// This list does not include "monitor" because studio monitors are speakers.
    private static let displayKeywords = ["display", "lg ultrafine"]
}
