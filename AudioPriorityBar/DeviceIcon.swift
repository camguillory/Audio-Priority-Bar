import AudioPriorityCore
import CoreAudio

extension AudioDevice {
    /// The SF Symbol for the kind of hardware, like the macOS Sound menu shows.
    /// Names are checked before the transport type, since a webcam or display
    /// usually connects over USB.
    func hardwareIcon(category: OutputCategory?) -> String {
        let name = name.lowercased()

        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if Self.cameraKeywords.contains(where: name.contains) { return "web.camera" }
        if isDisplayOutput || Self.displayKeywords.contains(where: name.contains) {
            return "display"
        }

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
            return role == .input ? "mic" : Self.genericSpeakerIcon
        default:
            break
        }

        if role == .input { return "mic" }
        if category == .headphone || HeadphoneDetection.isHeadphone(self.name) {
            return "headphones"
        }
        if transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE {
            return "hifispeaker"
        }
        return Self.genericSpeakerIcon
    }

    /// Returned for an output with nothing more specific to show, so the
    /// volume control can swap in its level-based speaker instead.
    static let genericSpeakerIcon = "speaker.wave.2"

    private static let cameraKeywords = [
        "camera", "webcam", "brio", "c920", "c922", "kiyo", "facecam", "opal",
    ]
    private static let displayKeywords = ["display", "monitor", "lg ultrafine", "tv"]
}
