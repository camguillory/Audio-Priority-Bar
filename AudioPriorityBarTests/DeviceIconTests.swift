import AudioPriorityCore
import CoreAudio
import Testing
@testable import AudioPriorityBar

struct IconCase: Sendable, CustomTestStringConvertible {
    let name: String
    let role: DeviceRole
    let transport: UInt32
    var isDisplayOutput = false
    let category: OutputCategory?
    let expected: String

    var testDescription: String {
        "\(name) (\(role), \(category.map(\.rawValue) ?? "no category"))"
    }

    var device: AudioDevice {
        AudioDevice(
            platformID: 1,
            uid: name,
            name: name,
            role: role,
            isDisplayOutput: isDisplayOutput,
            transportType: transport
        )
    }

    static func output(
        _ name: String,
        _ transport: UInt32,
        _ category: OutputCategory?,
        isDisplayOutput: Bool = false,
        _ expected: String
    ) -> IconCase {
        IconCase(
            name: name,
            role: .output,
            transport: transport,
            isDisplayOutput: isDisplayOutput,
            category: category,
            expected: expected
        )
    }

    static func input(
        _ name: String,
        _ transport: UInt32,
        _ expected: String
    ) -> IconCase {
        IconCase(
            name: name,
            role: .input,
            transport: transport,
            category: nil,
            expected: expected
        )
    }
}

private let usb = kAudioDeviceTransportTypeUSB
private let bluetooth = kAudioDeviceTransportTypeBluetooth
private let builtIn = kAudioDeviceTransportTypeBuiltIn

/// Devices seen on a real Mac, with the transport each one reports.
private let realDevices: [IconCase] = [
    .input("Razer Kiyo", usb, "web.camera"),
    .output("DELL U3419W", kAudioDeviceTransportTypeHDMI, .speaker, isDisplayOutput: true, "display"),
    .output("DECIMATOR", kAudioDeviceTransportTypeDisplayPort, .speaker, isDisplayOutput: true, "display"),
    .output("AirPods Pro", bluetooth, .headphone, "airpodspro"),
    // Some AirPods report a lowercase "p", so matching must ignore case.
    .input("Airpods Pro", bluetooth, "airpodspro"),
    .input("iPhone 16 Pro Microphone", kAudioDeviceTransportTypeContinuityCaptureWireless, "iphone"),
    .output("PowerConf", usb, .speaker, "speaker.wave.2"),
    .output("Scarlett 2i2 USB", usb, .speaker, "speaker.wave.2"),
    .output("Microsoft Teams Audio", kAudioDeviceTransportTypeVirtual, .speaker, "waveform"),
    .input("MacBook Air Microphone", builtIn, "mic"),
    .output("MacBook Air Speakers", builtIn, .speaker, "speaker.wave.2"),
]

/// One case for each remaining branch of `hardwareIcon`.
private let branches: [IconCase] = [
    .output("AirPods Max", bluetooth, .headphone, "airpodsmax"),
    .output("AirPods", bluetooth, .headphone, "airpods"),
    .output("Beats Studio Pro", bluetooth, .headphone, "beats.headphones"),
    // Beats makes speakers too, so only the Headphones section gets the logo.
    .output("Beats Pill", bluetooth, .speaker, "hifispeaker"),
    .output("iPad", 0, .speaker, "ipad"),
    .output("Studio Display Speakers", usb, .speaker, "display"),
    .output("Living Room", kAudioDeviceTransportTypeAirPlay, .speaker, "airplayaudio"),
    .input("Desk Mic", kAudioDeviceTransportTypeContinuityCaptureWired, "iphone"),
    .output("Multi-Output Device", kAudioDeviceTransportTypeAggregate, .speaker, "waveform"),
    .output("Auto Aggregate", kAudioDeviceTransportTypeAutoAggregate, .speaker, "waveform"),
    .input("USB Audio Device", usb, "mic"),
    // The section is the user's choice, so a headset brand's name decides nothing.
    .output("Jabra Speak 510 USB", usb, .speaker, "speaker.wave.2"),
    .output("Jabra Evolve2 65", usb, nil, "speaker.wave.2"),
    .output("Jabra Evolve2 65", usb, .headphone, "headphones"),
    // Studio monitors are speakers, not displays.
    .output("KRK Studio Monitor", usb, .speaker, "speaker.wave.2"),
    .output("SoundLink Flex", kAudioDeviceTransportTypeBluetoothLE, .speaker, "hifispeaker"),
]

@Test(arguments: realDevices + branches)
func hardwareIconMatchesTheDevice(_ icon: IconCase) {
    #expect(icon.device.hardwareIcon(category: icon.category) == icon.expected)
}

@Test
func headphoneJackShowsHeadphones() {
    let jack = IconCase.output("External Headphones", builtIn, .headphone, "headphones")
    withKnownIssue("Built-in outputs return the speaker icon before checking the category") {
        #expect(jack.device.hardwareIcon(category: jack.category) == jack.expected)
    }
}
