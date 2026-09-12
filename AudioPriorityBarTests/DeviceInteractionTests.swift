import AudioPriorityCore
import CoreGraphics
import Foundation
import Testing
@testable import AudioPriorityBar

@Test
@MainActor
func dropReordersSpeakersAndMicrophonesWithinTheirLists() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let firstSpeaker = output(1, "speaker-1")
    let secondSpeaker = output(2, "speaker-2")
    let thirdSpeaker = output(3, "speaker-3")
    let firstMic = input(4, "mic-1")
    let secondMic = input(5, "mic-2")
    let audio = FakeAudio()
    audio.catalog = [
        firstSpeaker, secondSpeaker, thirdSpeaker, firstMic, secondMic,
    ]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    #expect(model.dropDevice(firstSpeaker.id, into: .speaker, at: 3))
    #expect(model.dropDevice(secondMic.id, into: nil, at: 0))
    #expect(model.speakerDevices == [
        secondSpeaker, thirdSpeaker, firstSpeaker,
    ])
    #expect(model.inputDevices == [secondMic, firstMic])
}

@Test
@MainActor
func staleMoveActionsLeaveRefreshedListsUnchanged() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let microphone = input(2, "microphone")
    let audio = FakeAudio()
    audio.catalog = [speaker, microphone]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.moveOutput(
        in: .speaker,
        from: IndexSet(integer: 2),
        to: 3
    )
    model.moveInput(
        from: IndexSet(integer: 2),
        to: 3
    )

    #expect(model.speakerDevices == [speaker])
    #expect(model.inputDevices == [microphone])
}

@Test
@MainActor
func dropMovesOutputBetweenListsAtRequestedPosition() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let firstHeadphone = output(2, "headphone-1", "AirPods Pro")
    let secondHeadphone = output(3, "headphone-2", "USB Headphones")
    let audio = FakeAudio()
    audio.catalog = [speaker, firstHeadphone, secondHeadphone]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    #expect(model.dropDevice(speaker.id, into: .headphone, at: 1))
    #expect(model.headphoneDevices == [
        firstHeadphone, speaker, secondHeadphone,
    ])
    #expect(model.store.category(for: speaker) == .headphone)
    #expect(model.store.sorted(
        [firstHeadphone, secondHeadphone, speaker],
        category: .headphone
    ) == [firstHeadphone, speaker, secondHeadphone])

    #expect(model.dropDevice(speaker.id, into: .speaker, at: 0))
    #expect(model.speakerDevices == [speaker])
    #expect(model.store.category(for: speaker) == .speaker)
}

@Test
@MainActor
func crossListDropUsesStableIdentityAfterDeviceRefresh() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    let audio = FakeAudio()
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog = [output(3, "speaker"), headphones]

    #expect(model.dropDevice(speaker.id, into: .headphone, at: 1))
    #expect(model.headphoneDevices.map(\.id) == [headphones.id, speaker.id])
    #expect(model.headphoneDevices[1].platformID == 3)
}

@Test
@MainActor
func insertionIndexPicksTheNearestGap() {
    let top = DeviceRowMetrics.sectionHeader + DeviceRowMetrics.spacing
    let pitch = DeviceRowMetrics.pitch

    #expect(PanelLayout.insertionIndex(y: top, rowCount: 3) == 0)
    #expect(PanelLayout.insertionIndex(y: top + pitch * 0.4, rowCount: 3) == 0)
    #expect(PanelLayout.insertionIndex(y: top + pitch * 0.6, rowCount: 3) == 1)
    #expect(PanelLayout.insertionIndex(y: top + pitch * 3, rowCount: 3) == 3)
    #expect(PanelLayout.insertionIndex(y: 0, rowCount: 3) == 0)
    #expect(PanelLayout.insertionIndex(y: 10_000, rowCount: 3) == 3)
    #expect(PanelLayout.insertionIndex(y: 10_000, rowCount: 0) == 0)
}

@Test
@MainActor
func layoutResolvesRawTargetSection() {
    let layout = PanelLayout(sections: [
        (.speaker, 2), (.headphone, 1), (.input, 2),
    ])
    let speakerTop = PanelLayout.verticalPadding
    let headphoneTop = speakerTop
        + DeviceRowMetrics.sectionHeader + 2 * DeviceRowMetrics.pitch
        + PanelLayout.sectionGap

    let inSpeakers = CGPoint(x: 10, y: speakerTop + 20)
    #expect(layout.target(at: inSpeakers)?.section == .speaker)

    let inHeadphones = CGPoint(x: 10, y: headphoneTop + 20)
    #expect(layout.target(at: inHeadphones)?.section == .headphone)

    let farDown = CGPoint(x: 10, y: layout.contentHeight - 10)
    #expect(layout.target(at: farDown)?.section == .input)
    #expect(layout.target(at: CGPoint(x: 10, y: -1)) == DropTarget(
        section: .speaker,
        index: 0
    ))
    #expect(layout.target(at: CGPoint(
        x: 10,
        y: layout.contentHeight + PanelLayout.sectionGap
    )) == nil)
}

@Test
@MainActor
func roleMismatchesAreForbiddenUntilTheDragReentersAValidSection() {
    let layout = PanelLayout(sections: [
        (.speaker, 1), (.headphone, 1), (.input, 1),
    ])
    let translation = CGSize(width: 12, height: 80)
    for section in [DeviceSection.speaker, .headphone] {
        var microphoneDrag = DeviceDrag(
            device: input(1, "microphone"),
            section: .input,
            index: 0
        )

        microphoneDrag.update(
            hovered: DropTarget(section: section, index: 0),
            translation: translation
        )

        #expect(microphoneDrag.isForbidden)
        #expect(microphoneDrag.target == nil)
        #expect(microphoneDrag.translation == translation)
        #expect(layout.liftedOffset(for: microphoneDrag) == CGSize(
            width: 0,
            height: translation.height
        ))
    }

    var outputDrag = DeviceDrag(
        device: output(2, "output"),
        section: .speaker,
        index: 0
    )
    outputDrag.update(
        hovered: DropTarget(section: .input, index: 0),
        translation: translation
    )
    #expect(outputDrag.isForbidden)
    #expect(outputDrag.target == nil)

    outputDrag.update(hovered: nil, translation: translation)
    #expect(!outputDrag.isForbidden)
    #expect(outputDrag.target == nil)
    #expect(layout.liftedOffset(for: outputDrag) == CGSize(
        width: 0,
        height: translation.height
    ))

    let validTarget = DropTarget(section: .headphone, index: 1)
    outputDrag.update(hovered: validTarget, translation: translation)
    #expect(!outputDrag.isForbidden)
    #expect(outputDrag.target == validTarget)
}

@Test
@MainActor
func crossSectionDragShiftsOnlySectionsBetweenSourceAndTarget() {
    let downLayout = PanelLayout(sections: [
        (.speaker, 2), (.headphone, 1), (.input, 1),
    ])
    let device = output(1, "speaker")
    let down = DeviceDrag(
        device: device,
        section: .speaker,
        index: 0,
        target: DropTarget(section: .headphone, index: 1)
    )

    #expect(downLayout.sectionOffset(for: .speaker, drag: down) == 0)
    #expect(
        downLayout.sectionOffset(for: .headphone, drag: down)
            == -DeviceRowMetrics.pitch
    )
    #expect(downLayout.sectionOffset(for: .input, drag: down) == 0)

    let upLayout = PanelLayout(sections: [
        (.speaker, 1), (.headphone, 2), (.input, 1),
    ])
    let up = DeviceDrag(
        device: device,
        section: .headphone,
        index: 0,
        target: DropTarget(section: .speaker, index: 0)
    )

    #expect(upLayout.sectionOffset(for: .speaker, drag: up) == 0)
    #expect(
        upLayout.sectionOffset(for: .headphone, drag: up)
            == DeviceRowMetrics.pitch
    )
    #expect(upLayout.sectionOffset(for: .input, drag: up) == 0)
}

@Test
@MainActor
func crossSectionOffsetsMatchPostDropLayoutAtPlaceholderBoundaries() throws {
    let scenarios: [(
        before: [Int],
        after: [Int],
        source: DeviceSection,
        target: DeviceSection
    )] = [
        ([1, 1, 1], [0, 2, 1], .speaker, .headphone),
        ([2, 0, 1], [1, 1, 1], .speaker, .headphone),
        ([1, 0, 1], [0, 1, 1], .speaker, .headphone),
        ([1, 1, 1], [2, 0, 1], .headphone, .speaker),
        ([0, 2, 1], [1, 1, 1], .headphone, .speaker),
        ([3, 2, 1], [2, 3, 1], .speaker, .headphone),
    ]
    let sections: [DeviceSection] = [.speaker, .headphone, .input]

    for scenario in scenarios {
        let before = PanelLayout(sections: Array(
            zip(sections, scenario.before)
        ))
        let after = PanelLayout(sections: Array(
            zip(sections, scenario.after)
        ))
        let drag = DeviceDrag(
            device: output(1, "device"),
            section: scenario.source,
            index: 0,
            target: DropTarget(section: scenario.target, index: 0)
        )

        for section in sections {
            let predicted = try #require(before.sectionTop(of: section))
                + before.sectionOffset(for: section, drag: drag)
            #expect(predicted == after.sectionTop(of: section))
        }

        // The panel sizes its scroll view from this, so a preview that is
        // taller than the frame clips its bottom row.
        #expect(
            before.contentHeight + before.heightDelta(for: drag)
                == after.contentHeight
        )
    }
}

@Test
@MainActor
func liftedRowSnapsBelowTargetHeaderWithoutOverlappingNextSection() throws {
    let layout = PanelLayout(sections: [
        (.speaker, 4), (.headphone, 4), (.input, 3),
    ])
    let sourceIndex = 2
    let targetIndex = 3
    let drag = DeviceDrag(
        device: output(1, "speaker"),
        section: .speaker,
        index: sourceIndex,
        target: DropTarget(section: .headphone, index: targetIndex)
    )
    let sourceTop = try #require(layout.contentTop(of: .speaker))
    let targetTop = try #require(layout.contentTop(of: .headphone))
        + layout.sectionOffset(for: .headphone, drag: drag)
    let nextHeaderTop = try #require(layout.sectionTop(of: .input))
        + layout.sectionOffset(for: .input, drag: drag)
    let liftedTop = sourceTop
        + CGFloat(sourceIndex) * DeviceRowMetrics.pitch
        + layout.sectionOffset(for: .speaker, drag: drag)
        + layout.liftedOffset(for: drag).height

    #expect(
        liftedTop
            == targetTop + CGFloat(targetIndex) * DeviceRowMetrics.pitch
    )
    #expect(liftedTop + DeviceRowMetrics.height <= nextHeaderTop)
}

@Test
@MainActor
func liftedRowHandlesSameSectionEmptyTargetAndInvalidTarget() {
    let device = output(1, "speaker")
    let sameSection = PanelLayout(sections: [
        (.speaker, 3), (.headphone, 0), (.input, 1),
    ])
    let moveToEnd = DeviceDrag(
        device: device,
        section: .speaker,
        index: 0,
        target: DropTarget(section: .speaker, index: 3)
    )
    #expect(
        sameSection.liftedOffset(for: moveToEnd).height
            == DeviceRowMetrics.pitch * 2
    )
    #expect(sameSection.sectionOffset(for: .speaker, drag: moveToEnd) == 0)

    let emptyTarget = PanelLayout(sections: [
        (.speaker, 1), (.headphone, 0), (.input, 1),
    ])
    let moveToEmpty = DeviceDrag(
        device: device,
        section: .speaker,
        index: 0,
        target: DropTarget(section: .headphone, index: 0)
    )
    #expect(
        emptyTarget.liftedOffset(for: moveToEmpty).height
            == DeviceRowMetrics.sectionHeader
                + DeviceRowMetrics.pitch
                + PanelLayout.sectionGap
    )

    let invalid = DeviceDrag(
        device: device,
        section: .speaker,
        index: 0,
        target: nil
    )
    #expect(sameSection.liftedOffset(for: invalid) == .zero)
    #expect(sameSection.sectionOffset(for: .headphone, drag: invalid) == 0)
    #expect(
        sameSection.rowOffset(at: 1, in: .speaker, drag: invalid) == 0
    )
}

@Test
@MainActor
func changingCategoryKeepsAnExcludedDeviceVisible() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let audio = FakeAudio()
    audio.catalog = [speaker]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    model.hideEntirely(speaker)
    #expect(model.speakerDevices.isEmpty)

    model.setCategory(.headphone, for: speaker)

    #expect(model.headphoneDevices == [speaker])
    #expect(model.hiddenHeadphoneDevices.isEmpty)
}

@Test
@MainActor
func dropRejectsDevicesFromAnotherRole() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let mic = input(2, "mic")
    let audio = FakeAudio()
    audio.catalog = [speaker, mic]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    #expect(!model.dropDevice(mic.id, into: .speaker, at: 0))
    #expect(!model.dropDevice(speaker.id, into: nil, at: 0))
    #expect(model.speakerDevices == [speaker])
    #expect(model.inputDevices == [mic])
}

@Test
@MainActor
func outputDropReappliesAutomaticSelectionOnce() {
    let defaults = isolatedDefaults()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    let audio = FakeAudio()
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()

    #expect(model.dropDevice(headphones.id, into: .speaker, at: 1))
    #expect(audio.selections.map(\.1) == [speaker.platformID])
    #expect(model.currentOutputID == speaker.platformID)
}

@Test
@MainActor
func crossListDropDoesNotSelectBeforeFinalOrderIsSaved() {
    let defaults = isolatedDefaults()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    let audio = FakeAudio()
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()
    audio.selections.removeAll()

    #expect(model.dropDevice(headphones.id, into: .speaker, at: 0))
    #expect(audio.selections.isEmpty)
    #expect(model.currentOutputID == headphones.platformID)
}

@Test
@MainActor
func outputDropKeepsManualSelectionActive() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    store.isManualMode = true
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    let audio = FakeAudio()
    audio.catalog = [speaker, headphones]
    audio.defaults[.output] = headphones.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    #expect(model.dropDevice(headphones.id, into: .speaker, at: 1))
    #expect(audio.selections.isEmpty)
    #expect(model.currentOutputID == headphones.platformID)
}

@Test
@MainActor
func dualRoleDisconnectKeepsAutomaticForBothRoles() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let headsetOutput = output(1, "headset", "AirPods Pro")
    let headsetInput = input(1, "headset", "AirPods Pro")
    let speaker = output(2, "speaker")
    let builtin = input(3, "builtin")
    let webcam = input(4, "webcam", "Webcam")
    store.savePriorities([headsetInput, webcam, builtin], role: .input)
    let audio = FakeAudio()
    audio.catalog = [
        headsetOutput, headsetInput, speaker, builtin, webcam,
    ]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog = [speaker, builtin, webcam]
    audio.defaults[.output] = speaker.platformID
    audio.defaults[.input] = builtin.platformID
    model.handleDefaultChanged(.output)
    model.handleDefaultChanged(.input)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == speaker.platformID)
    #expect(model.currentInputID == webcam.platformID)
}

@Test
@MainActor
func noAutomaticTargetDoesNotSilentlyEnableManual() {
    let defaults = isolatedDefaults()
    let store = PriorityStore(defaults: defaults)
    let first = output(1, "first")
    let second = output(2, "second")
    store.setNeverUse(first, true)
    store.setNeverUse(second, true)
    let audio = FakeAudio()
    audio.catalog = [first, second]
    audio.defaults[.output] = first.platformID
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog = [second]
    audio.defaults[.output] = second.platformID
    model.handleDevicesChanged()
    model.handleDefaultChanged(.output)

    #expect(!model.isManualMode)
    #expect(model.currentOutputID == second.platformID)
}

@Test
@MainActor
func unrelatedConnectionDoesNotMaskSoundSettingsChoice() {
    let defaults = isolatedDefaults()
    let audio = FakeAudio()
    let speaker = output(1, "speaker")
    let headphones = output(2, "headphones", "AirPods Pro")
    let display = output(3, "display", "HDMI")
    audio.catalog = [speaker, headphones]
    let model = testModel(audio: audio, defaults: defaults)
    model.start()

    audio.catalog.append(display)
    audio.defaults[.output] = speaker.platformID
    model.handleDefaultChanged(.output)

    #expect(model.isManualMode)
    #expect(model.currentOutputID == speaker.platformID)
}
