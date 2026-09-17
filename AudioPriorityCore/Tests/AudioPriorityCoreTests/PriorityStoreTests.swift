import Foundation
import Testing
@testable import AudioPriorityCore

private func fixtureValues(_ fixture: String) throws -> [String: Any] {
    let url = try #require(Bundle.module.url(
        forResource: fixture,
        withExtension: "plist",
        subdirectory: "Fixtures"
    ))
    let data = try Data(contentsOf: url)
    return try #require(
        PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    )
}

private func withDefaults(
    fixture: String? = nil,
    _ body: (UserDefaults) throws -> Void
) throws {
    let suite = "AudioPriorityCoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    if let fixture {
        for (key, value) in try fixtureValues(fixture) {
            defaults.set(value, forKey: key)
        }
    }
    try body(defaults)
}

private func device(
    _ uid: String,
    role: DeviceRole = .output,
    connected: Bool = true,
    name: String? = nil,
    id: UInt32 = 1
) -> AudioDevice {
    AudioDevice(
        platformID: id,
        uid: uid,
        name: name ?? uid,
        role: role,
        isConnected: connected
    )
}

@Test
func v2FixtureLoadsWithoutChangingMeaning() throws {
    try withDefaults(fixture: "v2.0.0-defaults") { defaults in
        let before = defaults.dictionaryRepresentation()
        let store = PriorityStore(defaults: defaults)

        #expect(store.isManualMode)
        #expect(store.knownDevices.count == 3)
        #expect(store.knownDevices[0] == StoredDevice(
            uid: "shared-device",
            name: "Synthetic USB Headset",
            isInput: true,
            lastSeen: Date(timeIntervalSinceReferenceDate: 123_456)
        ))
        #expect(store.category(for: device(
            "shared-device",
            name: "Synthetic USB Headset"
        )) == .headphone)
        #expect(store.isHidden(device("mic-hidden", role: .input)))
        #expect(store.isHidden(device("speaker-hidden"), in: .speaker))
        #expect(store.isNeverUse(device("mic-never", role: .input)))
        #expect(store.isNeverUse(device("speaker-never")))

        let originalData = try #require(defaults.data(forKey: "knownDevices"))
        let roundTripData = try JSONEncoder().encode(store.knownDevices)
        let originalShape = try JSONSerialization.jsonObject(with: originalData)
        let roundTripShape = try JSONSerialization.jsonObject(with: roundTripData)
        #expect(NSDictionary(dictionary: ["value": originalShape]).isEqual(
            to: ["value": roundTripShape]
        ))

        let after = defaults.dictionaryRepresentation()
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }
}

@Test
func publicV1SettingsMigrateOnceWithoutOverwritingV2Values() throws {
    try withDefaults { defaults in
        defaults.set(["current-speaker"], forKey: "speakerPriorities")
        let legacy = try fixtureValues("v1.2.1-defaults")
        let store = PriorityStore(
            defaults: defaults,
            legacyDomain: legacy
        )

        #expect(store.isManualMode)
        #expect(defaults.stringArray(forKey: "inputPriorities") == ["v1-mic"])
        #expect(defaults.stringArray(forKey: "speakerPriorities")
            == ["current-speaker"])
        #expect(defaults.stringArray(forKey: "headphonePriorities")
            == ["v1-headset"])
        #expect(store.category(for: device(
            "v1-headset",
            name: "Synthetic V1 Headset"
        )) == .headphone)
        #expect(store.isHidden(device("v1-mic-hidden", role: .input)))
        #expect(store.isHidden(device("v1-speaker-hidden"), in: .speaker))
        #expect(store.isHidden(device("v1-hidden"), in: .headphone))
        #expect(store.knownDevices == [StoredDevice(
            uid: "v1-headset",
            name: "Synthetic V1 Headset",
            isInput: false,
            lastSeen: Date(timeIntervalSinceReferenceDate: 123_456)
        )])
        #expect(store.isNeverUse(device("v1-never", role: .input)))
        #expect(store.isNeverUse(device("v1-never")))
        #expect(defaults.bool(forKey: "legacyBundleMigration_v1"))

        let once = defaults.dictionaryRepresentation()
        _ = PriorityStore(
            defaults: defaults,
            legacyDomain: ["inputPriorities": ["replacement"]]
        )
        #expect(NSDictionary(dictionary: once).isEqual(
            to: defaults.dictionaryRepresentation()
        ))
    }
}

@Test
func v1NeverUseImportsAfterV2RoleMigrationAlreadyRan() throws {
    try withDefaults(fixture: "v2.0.0-defaults") { defaults in
        let store = PriorityStore(
            defaults: defaults,
            legacyDomain: ["neverUseDevices": ["v1-never"]]
        )

        #expect(store.isNeverUse(device("mic-never", role: .input)))
        #expect(store.isNeverUse(device("speaker-never")))
        #expect(store.isNeverUse(device("v1-never", role: .input)))
        #expect(store.isNeverUse(device("v1-never")))
        #expect(defaults.object(forKey: "neverUseDevices") == nil)
    }
}

@Test
func legacyNeverUseMigratesOnceAndPreservesRoleEntries() throws {
    try withDefaults(fixture: "legacy-defaults") { defaults in
        let store = PriorityStore(defaults: defaults)
        #expect(store.isNeverUse(device("shared-device", role: .input)))
        #expect(store.isNeverUse(device("shared-device")))
        #expect(defaults.stringArray(forKey: "neverUseInputs")
            == ["input-existing", "shared-device", "legacy-only"])
        #expect(defaults.stringArray(forKey: "neverUseOutputs")
            == ["output-existing", "shared-device", "legacy-only"])
        #expect(defaults.object(forKey: "neverUseDevices") == nil)
        #expect(defaults.bool(forKey: "roleSpecificNeverUseMigration_v1"))

        let once = defaults.dictionaryRepresentation()
        _ = store.isNeverUse(device("shared-device"))
        let twice = defaults.dictionaryRepresentation()
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
    }
}

@Test(arguments: [
    (
        ["C", "B", "A"],
        ["A", "hidden-1", "B", "hidden-2", "C"],
        ["C", "hidden-1", "B", "hidden-2", "A"]
    ),
    (
        ["B", "A", "new"],
        ["A", "disconnected", "B"],
        ["B", "disconnected", "A", "new"]
    ),
    (
        ["B", "B", "A"],
        ["A", "missing", "A", "B"],
        ["B", "missing", "A"]
    ),
])
func visibleOrderMergesWithoutDroppingStoredDevices(
    visible: [String],
    stored: [String],
    expected: [String]
) {
    #expect(PriorityStore.mergeVisibleOrder(visible, into: stored) == expected)
}

@Test
func unrankedDevicesKeepDiscoveryOrder() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let devices = [
            device("C", id: 3),
            device("A", id: 1),
            device("B", id: 2),
        ]
        #expect(store.sorted(devices, category: .speaker).map(\.uid)
            == ["C", "A", "B"])
    }
}

@Test
func fullDuplexDeviceKeepsBothRoles() throws {
    try withDefaults { defaults in
        let fixedNow = Date(timeIntervalSinceReferenceDate: 999)
        let store = PriorityStore(defaults: defaults, now: { fixedNow })
        store.remember([
            device("shared", role: .input, name: "USB Headset"),
            device("shared", name: "USB Headset"),
        ])

        #expect(store.knownDevices.count == 2)
        #expect(store.storedDevice(uid: "shared", role: .input)?.isInput == true)
        #expect(store.storedDevice(uid: "shared", role: .output)?.isInput == false)
    }
}

@Test
func usbAudioEngineRolesShareAPairingKey() {
    let base = "AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:50C275445423"
    #expect(device("\(base):1").pairingKey == base)
    #expect(device("\(base):2", role: .input).pairingKey == base)
    let numericSerial = "AppleUSBAudioEngine:Manufacturer:Device:2110000"
    #expect(device(numericSerial).pairingKey == numericSerial)
    #expect(device("\(base):1,2").pairingKey == "\(base):1,2")
    #expect(device("other-device:1").pairingKey == "other-device:1")
}

@Test
func virtualDevicesDefaultOutOfAutomaticSelection() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let krisp = AudioDevice(
            platformID: 1,
            uid: "krisp",
            name: "krisp speaker",
            role: .output,
            isVirtual: true
        )
        let speakers = device("builtin", name: "MacBook Pro Speakers")

        store.remember([krisp, speakers])

        #expect(store.isNeverUse(krisp))
        #expect(!store.isNeverUse(speakers))
    }
}

@Test
func optingAVirtualDeviceBackInSurvivesLaterRefreshes() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let krisp = AudioDevice(
            platformID: 1,
            uid: "krisp",
            name: "krisp speaker",
            role: .output,
            isVirtual: true
        )
        store.remember([krisp])
        store.setNeverUse(krisp, false)

        store.remember([krisp])

        #expect(!store.isNeverUse(krisp))
    }
}

@Test
func virtualDefaultsAlsoSeedDevicesKnownBeforeTheFeature() throws {
    try withDefaults { defaults in
        let krisp = AudioDevice(
            platformID: 1,
            uid: "krisp",
            name: "krisp speaker",
            role: .output,
            isVirtual: true
        )
        let older = PriorityStore(defaults: defaults)
        defaults.removeObject(forKey: "virtualNeverUseDefaults_v1")
        older.remember([krisp])
        older.setNeverUse(krisp, false)
        defaults.removeObject(forKey: "virtualNeverUseDefaults_v1")

        let upgraded = PriorityStore(defaults: defaults)
        upgraded.remember([krisp])

        #expect(upgraded.isNeverUse(krisp))
    }
}

@Test
func emptyRefreshDoesNotConsumeVirtualDeviceMigration() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        store.remember([])
        #expect(!defaults.bool(forKey: "virtualNeverUseDefaults_v1"))

        let krisp = AudioDevice(
            platformID: 1,
            uid: "krisp",
            name: "krisp speaker",
            role: .output,
            isVirtual: true
        )
        store.remember([krisp])

        #expect(store.isNeverUse(krisp))
    }
}

@Test
func neverUseIsScopedByRole() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let input = device("shared", role: .input)
        let output = device("shared")
        store.setNeverUse(input, true)
        #expect(store.isNeverUse(input))
        #expect(!store.isNeverUse(output))
    }
}

@Test
func microphoneLinkingDefaultsOnAndPersistsOff() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        #expect(store.linksMicrophone)

        store.linksMicrophone = false

        #expect(!PriorityStore(defaults: defaults).linksMicrophone)
    }
}

private func monitor(
    _ uid: String = "dell",
    _ name: String = "DELL U2518D"
) -> AudioDevice {
    AudioDevice(
        platformID: 1,
        uid: uid,
        name: name,
        role: .output,
        isDisplayOutput: true
    )
}

@Test
func displayOutputsAreHiddenOnceAndShowingOneSticks() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let dell = monitor()
        store.remember([dell])
        // Hidden in both categories, so a later move between Speakers and
        // Headphones cannot surface a display the user never asked to see.
        #expect(store.isHidden(dell, in: .speaker))
        #expect(store.isHidden(dell, in: .headphone))

        store.unhide(dell, from: .speaker)
        store.unhide(dell, from: .headphone)
        store.remember([dell])

        // Deciding once is the whole point: a later sighting must not undo
        // the user showing it by hand.
        #expect(!store.isHidden(dell, in: .speaker))
        #expect(!store.isHidden(dell, in: .headphone))
    }
}

@Test
func displayDefaultAppliesToNewDevicesRatherThanRetroactively() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        store.hideNewDisplayOutputs = false
        let seen = monitor()
        store.remember([seen])
        #expect(!store.isHidden(seen, in: .speaker))

        store.hideNewDisplayOutputs = true
        store.remember([seen])
        // Already dealt with, so enabling the preference leaves it alone.
        #expect(!store.isHidden(seen, in: .speaker))

        let arrived = monitor("dell2", "DELL U2720Q")
        store.remember([arrived])
        #expect(store.isHidden(arrived, in: .speaker))
        #expect(store.isHidden(arrived, in: .headphone))
    }
}

@Test
func displayDefaultLeavesOtherOutputsAndMicrophonesAlone() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let speaker = device("speakers", name: "Haut-parleurs MacBook Pro")
        let mic = device("mic", role: .input)
        store.remember([speaker, mic])

        #expect(!store.isHidden(speaker, in: .speaker))
        #expect(!store.isHidden(mic))
    }
}

@Test
func displayPreferenceDefaultsOnAndPersistsOff() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        #expect(store.hideNewDisplayOutputs)

        store.hideNewDisplayOutputs = false

        #expect(!PriorityStore(defaults: defaults).hideNewDisplayOutputs)
    }
}

@Test
func forgettingADisplayLetsItBeTreatedAsNewAgain() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let dell = monitor()
        store.remember([dell])
        store.unhide(dell, from: .speaker)
        store.unhide(dell, from: .headphone)

        store.forget(uid: dell.uid, role: .output)
        store.remember([dell])

        #expect(store.isHidden(dell, in: .speaker))
        #expect(store.isHidden(dell, in: .headphone))
    }
}

@Test
func forgettingOneRolePreservesTheOther() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let input = device("shared", role: .input)
        let output = device("shared")
        store.remember([input, output])
        store.savePriorities([input], role: .input)
        store.savePriorities([output], category: .speaker)
        store.setNeverUse(input, true)
        store.setNeverUse(output, true)
        store.hide(input)
        store.hide(output, in: .speaker)

        store.forget(uid: "shared", role: .input)

        #expect(store.storedDevice(uid: "shared", role: .input) == nil)
        #expect(store.storedDevice(uid: "shared", role: .output) != nil)
        #expect(!store.isNeverUse(input))
        #expect(store.isNeverUse(output))
        #expect(defaults.stringArray(forKey: "inputPriorities") == [])
        #expect(defaults.stringArray(forKey: "speakerPriorities") == ["shared"])
    }
}

@Test
func selectionSkipsUnavailableDevices() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        let disconnected = device("disconnected", connected: false)
        let hidden = device("hidden")
        let never = device("never")
        let unlinked = device("unlinked")
        let selected = device("selected")
        store.hide(hidden)
        store.setNeverUse(never, true)

        let result = store.firstSelectable(
            in: [disconnected, hidden, never, unlinked, selected],
            isUsable: { $0.uid != "unlinked" }
        )
        #expect(result == selected)
    }
}

@Test
func headphoneDetectionIsCaseInsensitive() {
    #expect(HeadphoneDetection.isHeadphone("JABRA LINK 390"))
    #expect(HeadphoneDetection.isHeadphone("AirPods Pro"))
    #expect(!HeadphoneDetection.isHeadphone("Studio Display Speakers"))
}

private func declaring(
    _ uid: String,
    _ name: String,
    _ declared: OutputCategory? = nil
) -> AudioDevice {
    AudioDevice(
        platformID: 1,
        uid: uid,
        name: name,
        role: .output,
        declaredCategory: declared
    )
}

@Test
func knownSpeakerProductsOutrankTheirBrandKeyword() {
    // The bare "jabra" keyword would otherwise claim these.
    #expect(HeadphoneDetection.isKnownSpeaker("Jabra Speak2 75"))
    #expect(HeadphoneDetection.isKnownSpeaker("JABRA SPEAK 750"))
    #expect(!HeadphoneDetection.isKnownSpeaker("Jabra Evolve2 85"))
    #expect(!HeadphoneDetection.isKnownSpeaker("Jabra Elite 8 Active"))
    #expect(!HeadphoneDetection.isKnownSpeaker("Jabra Link 380"))
    // Brands stay out of the list, so their headphones are unaffected.
    #expect(!HeadphoneDetection.isKnownSpeaker("Marshall Major IV"))
}

@Test
func categoryPrefersTheDeviceClaimOverNameKeywords() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)

        // A speaker that a brand keyword would misfile as headphones.
        #expect(store.category(
            for: declaring("anker", "Anker PowerConf S3", .speaker)
        ) == .speaker)
        // A localized name no English keyword matches, the headphone jack.
        #expect(store.category(
            for: declaring("jack", "Écouteurs externes", .headphone)
        ) == .headphone)
        // Without a claim the keyword list still decides, both ways.
        #expect(store.category(for: declaring("jack", "Écouteurs externes")) == .speaker)
        #expect(store.category(for: declaring("pods", "AirPods Pro")) == .headphone)
    }
}

@Test
func knownSpeakerWinsEvenWhenTheDeviceClaimsHeadphones() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        // CoreAudio has no speakerphone terminal type, so a Speak may report
        // headphones. The product rule has to sit ahead of the claim to cover
        // tobi/AudioPriorityBar#39.
        let speak = declaring("speak", "Jabra Speak2 75", .headphone)
        #expect(store.category(for: speak) == .speaker)

        // The user still overrides everything, including that rule.
        store.setCategory(.headphone, for: speak)
        #expect(store.category(for: speak) == .headphone)
    }
}

@Test
func rememberedDeviceKeepsWhatTheHardwareDeclared() throws {
    try withDefaults { defaults in
        let store = PriorityStore(defaults: defaults)
        store.remember([declaring("jack", "Écouteurs externes", .headphone)])

        // Reconstructed while disconnected it must not fall back to the
        // keyword result, or it would change list the moment it is unplugged.
        let remembered = try #require(
            store.storedDevice(uid: "jack", role: .output)
        )
        #expect(remembered.declaredCategory == .headphone)
        #expect(store.category(for: remembered.disconnectedDevice()) == .headphone)
    }
}

@Test
func storedDevicesWrittenBeforeDeclarationsStillDecode() throws {
    let json = Data("""
    [{"uid":"old","name":"Old Speaker","isInput":false,"lastSeen":0}]
    """.utf8)
    let decoded = try JSONDecoder().decode([StoredDevice].self, from: json)
    #expect(decoded.count == 1)
    #expect(decoded.first?.declaredCategory == nil)
}
