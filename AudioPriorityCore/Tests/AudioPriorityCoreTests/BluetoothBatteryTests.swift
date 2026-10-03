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
