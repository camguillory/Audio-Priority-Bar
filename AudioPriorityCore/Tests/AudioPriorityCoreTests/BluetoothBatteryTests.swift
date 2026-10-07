import Foundation
import Testing
@testable import AudioPriorityCore

private let sample = Data("""
{"SPBluetoothDataType": [{
  "device_connected": [
    {"Dave’s AirPods Pro": {
      "device_address": "70:AE:2A:5E:21:CD",
      "device_batteryLevelCase": "73%",
      "device_batteryLevelLeft": "100%",
      "device_batteryLevelRight": "95%",
      "device_vendorID": "0x004C"
    }},
    {"AirPods Max": {
      "device_address": "11:22:33:44:55:66",
      "device_batteryLevelMain": "40%",
      "device_vendorID": "0x004C"
    }},
    {"Other Headset": {
      "device_address": "AA:BB:CC:DD:EE:FF",
      "device_batteryLevelMain": "50%",
      "device_vendorID": "0x0A12"
    }},
    {"Magic Keyboard": {
      "device_address": "12:34:56:78:9A:BC",
      "device_vendorID": "0x004C"
    }}
  ],
  "device_not_connected": [
    {"Old AirPods": {
      "device_address": "E4:90:FD:64:D9:70",
      "device_batteryLevelCase": "10%",
      "device_vendorID": "0x004C"
    }}
  ]
}]}
""".utf8)

@Test
func batteryParsingKeepsConnectedAppleDevicesWithLevels() {
    let report = BluetoothBattery.parse(sample)
    #expect(report.byAddress == [
        "70AE2A5E21CD": BatteryLevels(left: 100, right: 95, case: 73),
        "112233445566": BatteryLevels(main: 40),
    ])
    #expect(report.byName["AirPods Max"] == BatteryLevels(main: 40))
}

@Test
func batteryLevelsMatchCoreAudioBluetoothUIDs() {
    let report = BluetoothBattery.parse(sample)
    let output = AudioDevice(
        platformID: 1, uid: "70-AE-2A-5E-21-CD:output", name: "Renamed", role: .output
    )
    let input = AudioDevice(
        platformID: 2, uid: "70-AE-2A-5E-21-CD:input", name: "Renamed", role: .input
    )
    #expect(report.levels(for: output)?.case == 73)
    #expect(report.levels(for: input)?.left == 100)
}

@Test
func batteryLevelsFallBackToNameAndIgnoreOtherDevices() {
    let report = BluetoothBattery.parse(sample)
    let byName = AudioDevice(platformID: 1, uid: "odd-uid", name: "AirPods Max", role: .output)
    let builtIn = AudioDevice(
        platformID: 2, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", role: .output
    )
    #expect(report.levels(for: byName) == BatteryLevels(main: 40))
    #expect(report.levels(for: builtIn) == nil)
}

@Test
func batteryParsingToleratesUnexpectedOutput() {
    #expect(BluetoothBattery.parse(Data("not json".utf8)) == BluetoothBatteryReport())
    #expect(BluetoothBattery.parse(Data("{}".utf8)) == BluetoothBatteryReport())
}

@Test
func batteryBadgesShowDifferingEarbudsSeparatelyThenTheCase() {
    let badges = BatteryLevels(left: 90, right: 100, case: 73).badges
    #expect(badges.map(\.text) == ["L 90% R 100%", "73%"])
    #expect(badges.map(\.icon) == ["airpods", "airpods.chargingcase"])
    #expect(badges.map(\.spokenText) == ["Left earbud 90%, Right earbud 100%", "Case 73%"])
}

@Test
func batteryBadgesShowMatchingEarbudsAsOneNumber() {
    let badges = BatteryLevels(left: 100, right: 100, case: 73).badges
    #expect(badges.map(\.text) == ["100%", "73%"])
    #expect(badges.first?.spokenText == "Earbuds 100%")
}

@Test
func batteryBadgesShowWhicheverEarbudReports() {
    #expect(BatteryLevels(left: 90).badges.map(\.text) == ["L 90%"])
    #expect(BatteryLevels(right: 85, case: 40).badges.map(\.text) == ["R 85%", "40%"])
    #expect(BatteryLevels(case: 40).badges.map(\.spokenText) == ["Case 40%"])
    #expect(BatteryLevels().badges.isEmpty)
}

@Test
func batteryBadgesShowASingleBattery() {
    #expect(BatteryLevels(main: 55).badges == [
        BatteryBadge(icon: "airpodsmax", text: "55%", spokenText: "Battery 55%", level: 55),
    ])
}

@Test
func batteryBadgesFlagLowLevelsByTheLowestEarbud() {
    let badges = BatteryLevels(left: 80, right: 20, case: 21).badges
    #expect(badges.map(\.isLow) == [true, false])
    #expect(BatteryLevels(main: 5).badges.first?.isLow == true)
}

@Test
func pairedSpeakersAndHeadphonesBecomeOutputsWithCoreAudioUIDs() throws {
    // Measured on macOS 27 with a JBL Xtreme and Galaxy Buds FE paired but
    // off, next to a paired mouse and iPhone. The Echo Dot is connected, and
    // CoreAudio named its output AC-41-6A-C5-C3-F1:output.
    let report = BluetoothBattery.parse(Data("""
    {"SPBluetoothDataType": [{
      "device_connected": [
        {"Echo Dot-65W": {"device_address": "AC:41:6A:C5:C3:F1", "device_minorType": "Speaker"}}
      ],
      "device_not_connected": [
        {"1.JBL Xtreme": {"device_address": "20:18:5B:E4:7C:CD", "device_minorType": "Speaker"}},
        {"Galaxy Buds FE": {"device_address": "AC:80:FB:D0:0C:82", "device_minorType": "Headset"}},
        {"iPhone": {"device_address": "88:20:0D:BC:8C:1E"}},
        {"MX Master 3S": {"device_address": "DD:4A:BE:F5:3B:07", "device_minorType": "Mouse"}}
      ]
    }]}
    """.utf8))
    let devices = report.pairedAudio.map(\.device)
    #expect(devices.map(\.uid) == [
        "20-18-5B-E4-7C-CD:output", "AC-41-6A-C5-C3-F1:output", "AC-80-FB-D0-0C-82:output",
    ])
    #expect(devices.map(\.declaredCategory) == [.speaker, .speaker, .headphone])

    let budsMic = AudioDevice(platformID: 0, uid: "AC-80-FB-D0-0C-82:input", name: "Buds", role: .input)
    #expect(try #require(report.bluetoothDevice(for: budsMic)).name == "Galaxy Buds FE")
    let oddUID = AudioDevice(platformID: 0, uid: "le-audio-1", name: "Galaxy Buds FE", role: .output)
    #expect(report.bluetoothDevice(for: oddUID)?.address == "AC-80-FB-D0-0C-82")
    let echo = AudioDevice(platformID: 1, uid: "AC-41-6A-C5-C3-F1:output", name: "Echo", role: .output)
    #expect(BluetoothBattery.address(of: echo) == "AC-41-6A-C5-C3-F1")
    #expect(BluetoothBattery.address(of: budsMic) == "AC-80-FB-D0-0C-82")
    let usb = AudioDevice(
        platformID: 2,
        uid: "AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:50C275445423:1",
        name: "Jabra Link 380",
        role: .output
    )
    #expect(BluetoothBattery.address(of: usb) == nil)
}
