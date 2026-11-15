import Testing
@testable import AudioPriorityCore

private func redacted(_ text: String, names: [String] = []) -> String {
    var redactor = Redactor(deviceNames: names)
    return redactor.redact(text)
}

@Test
func anOwnerNameIsTaggedAndTheModelAndApostropheStay() {
    #expect(redacted("\"Alex’s AirPods Pro\"") == "\"owner1’s AirPods Pro\"")
    #expect(redacted("\"Alex's iPhone 16 Pro Microphone\"") == "\"owner1's iPhone 16 Pro Microphone\"")
    #expect(redacted("\"AirPods Max de Léa\"") == "\"AirPods Max de owner1\"")
    #expect(redacted("\"Kopfhörer von Jonas\"") == "\"Kopfhörer von owner1\"")
}

@Test
func namesWithoutAnOwnerPassThrough() {
    for name in ["Haut-parleurs MacBook Pro", "Micro de l’iPhone", "Écouteurs de MacBook Air",
                 "Scarlett Solo USB", "Jabra Link 380", "MacBook Air Speakers"] {
        #expect(redacted("\"\(name)\"") == "\"\(name)\"")
    }
}

@Test
func aKnownNameIsTaggedWholeWhereverItStands() {
    let line = "Output: Mary Jane’s AirPods Pro, picked"
    #expect(redacted(line, names: ["Mary Jane’s AirPods Pro"]) == "Output: owner1’s AirPods Pro, picked")
    // Unknown and unquoted, only the word before the possessive is caught.
    #expect(redacted(line) == "Output: Mary owner1’s AirPods Pro, picked")
}

@Test
func aBluetoothAddressGetsOneTagInEitherForm() {
    let text = "[AA-11-22-33-44-01:output] [AA-11-22-33-44-01:input] aa:11:22:33:44:01 AA-11-22-33-44-02"
    #expect(redacted(text) == "[bt1:output] [bt1:input] bt1 bt2")
}

@Test
func aUSBSerialGoesAndTheVendorModelAndChannelStay() {
    #expect(redacted("[AppleUSBAudioEngine:Focusrite:Scarlett Solo USB:Y7XK9QF0123456:1]")
        == "[AppleUSBAudioEngine:Focusrite:Scarlett Solo USB:serial1:1]")
}

@Test
func aJabraSerialGetsOneTagInEveryCase() {
    let text = """
        Jabra serial:a1b2c3d4e5f6 attached: Jabra Link 380, serial A1B2C3D4E5F6, management true
        "Jabra Link 380" [AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:A1B2C3D4E5F6:2]
        Jabra product:9030/location:336592896 battery 50%
        """
    #expect(redacted(text) == """
        Jabra serial:serial1 attached: Jabra Link 380, serial serial1, management true
        "Jabra Link 380" [AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:serial1:2]
        Jabra product:9030/location:336592896 battery 50%
        """)
}

@Test
func aDisplayUUIDGetsOneTagAcrossItsStreams() {
    let uuid = "4C2D1A0B-9E8F-4A3B-B2C1-0D9E8F7A6B5C"
    #expect(redacted("[\(uuid)] [\(uuid)_00000030] [\(uuid.lowercased())_00000000]")
        == "[uuid1] [uuid1_00000030] [uuid1_00000000]")
}

@Test
func tagsCountPerKindAndStartOverInANewReport() {
    var redactor = Redactor(deviceNames: [])
    #expect(redactor.redact("\"Alex’s AirPods\" \"Sam’s AirPods\"") == "\"owner1’s AirPods\" \"owner2’s AirPods\"")
    #expect(redactor.redact("\"Sam’s AirPods\" AA-11-22-33-44-01") == "\"owner2’s AirPods\" bt1")
    #expect(redacted("\"Sam’s AirPods\"") == "\"owner1’s AirPods\"")
}

@Test
func aLogExcerptKeepsWhatDebuggingNeeds() {
    let log = """
        2026-11-13T14:02:11.204+0100 headphones: "Alex’s AirPods Pro" [AA-11-22-33-44-01:output] (blue, headphone, declares headphone); "Jabra Link 380" [AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:A1B2C3D4E5F6:1] (usb , headphone, link up)
        2026-11-13T14:02:11.205+0100 microphones: "Scarlett Solo USB" [AppleUSBAudioEngine:Focusrite:Scarlett Solo USB:Y7XK9QF0123456:1] (usb ); "Alex's iPhone 16 Pro Microphone" [6F1E2D3C-4B5A-4968-8776-A5B4C3D2E1F0] (cont)
        2026-11-13T14:02:11.206+0100 speakers: "LG HDR 4K" [4C2D1A0B-9E8F-4A3B-B2C1-0D9E8F7A6B5C_00000030] (hdmi, speaker, display)
        2026-11-13T14:02:11.207+0100 current: output "Alex’s AirPods Pro" [AA-11-22-33-44-01:output], microphone "Scarlett Solo USB" [AppleUSBAudioEngine:Focusrite:Scarlett Solo USB:Y7XK9QF0123456:1]
        2026-11-13T14:02:12.880+0100 paired Bluetooth audio: "Alex’s AirPods Pro" AA-11-22-33-44-01 headphone; "Kitchen speaker" BB-22-33-44-55-02 speaker
        2026-11-13T14:02:13.016+0100 Jabra serial:a1b2c3d4e5f6 attached: Jabra Link 380, serial A1B2C3D4E5F6, management true, profile link380
        2026-11-13T14:02:13.402+0100 Jabra serial:a1b2c3d4e5f6 link up, from pairing true and legacy unknown
        2026-11-13T14:02:20.114+0100 disconnected output: "Alex’s AirPods Pro" [AA-11-22-33-44-01:output]
        2026-11-13T14:02:20.120+0100 automatic output: "Jabra Link 380" [AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:A1B2C3D4E5F6:1], first connected headphones
        2026-11-13T14:02:20.131+0100 switch notice shown for ["Jabra Link 380"]
        """
    let expected = """
        2026-11-13T14:02:11.204+0100 headphones: "owner1’s AirPods Pro" [bt1:output] (blue, headphone, declares headphone); "Jabra Link 380" [AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:serial1:1] (usb , headphone, link up)
        2026-11-13T14:02:11.205+0100 microphones: "Scarlett Solo USB" [AppleUSBAudioEngine:Focusrite:Scarlett Solo USB:serial2:1] (usb ); "owner1's iPhone 16 Pro Microphone" [uuid1] (cont)
        2026-11-13T14:02:11.206+0100 speakers: "LG HDR 4K" [uuid2_00000030] (hdmi, speaker, display)
        2026-11-13T14:02:11.207+0100 current: output "owner1’s AirPods Pro" [bt1:output], microphone "Scarlett Solo USB" [AppleUSBAudioEngine:Focusrite:Scarlett Solo USB:serial2:1]
        2026-11-13T14:02:12.880+0100 paired Bluetooth audio: "owner1’s AirPods Pro" bt1 headphone; "Kitchen speaker" bt2 speaker
        2026-11-13T14:02:13.016+0100 Jabra serial:serial1 attached: Jabra Link 380, serial serial1, management true, profile link380
        2026-11-13T14:02:13.402+0100 Jabra serial:serial1 link up, from pairing true and legacy unknown
        2026-11-13T14:02:20.114+0100 disconnected output: "owner1’s AirPods Pro" [bt1:output]
        2026-11-13T14:02:20.120+0100 automatic output: "Jabra Link 380" [AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:serial1:1], first connected headphones
        2026-11-13T14:02:20.131+0100 switch notice shown for ["Jabra Link 380"]
        """
    let result = redacted(log, names: ["Alex’s AirPods Pro", "Scarlett Solo USB"])
    #expect(result == expected)
    for original in ["Alex", "AA-11", "BB-22", "A1B2C3D4E5F6", "a1b2c3d4e5f6", "Y7XK9QF0123456", "4C2D1A0B", "6F1E2D3C"] {
        #expect(!result.contains(original))
    }
}
