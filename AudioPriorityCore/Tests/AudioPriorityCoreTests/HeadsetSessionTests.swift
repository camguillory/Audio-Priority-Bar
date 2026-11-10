import AudioPriorityCore
import Foundation
import Testing

/// Plays recorded headset traffic through a session, line by line, running
/// its timers in order. Lines are the recorder's own, `<seconds> hid rid ...`
/// for telephony reports and `<seconds> rep|evt dst .. src .. seq .. grp ..
/// op .. args ..` for headset messages, plus `<seconds> do <input>` for the
/// wearer's clicks. Telephony bits are the ones measured on a Link 380:
/// report 2 byte 1 has the hook switch at bit 0, the line at bit 2 and phone
/// mute at bit 3; report 4 has them at bits 0, 3 and 4.
private struct Replay {
    var session: HeadsetSession
    private(set) var effects: [(time: TimeInterval, effect: HeadsetSession.Effect)] = []
    private var wakes: [(time: TimeInterval, wake: HeadsetSession.Wake)] = []
    private var reportBits: [Int: UInt8] = [2: 0, 4: 0]

    init(remembersMute: Bool = false) {
        session = HeadsetSession(remembersMute: remembersMute)
    }

    var controls: JabraGNP.HeadsetControls { session.controls }

    /// `base` shifts every time in `trace`.
    mutating func play(_ trace: String, from base: TimeInterval = 0) {
        for line in trace.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard let time = words.first.flatMap(Double.init) else { continue }
            advance(to: base + time)
            take(Array(words.dropFirst()), at: base + time)
        }
    }

    mutating func advance(to time: TimeInterval) {
        while let index = wakes.indices.min(by: { wakes[$0].time < wakes[$1].time }),
              wakes[index].time <= time {
            let due = wakes.remove(at: index)
            deliver(.wake(due.wake), at: due.time)
        }
    }

    func sends(kind: UInt8, op: UInt8) -> [(time: TimeInterval, arguments: [UInt8])] {
        effects.compactMap {
            guard case let .send(sentKind, _, sentOp, arguments) = $0.effect,
                  sentKind == kind, sentOp == op else { return nil }
            return ($0.time, arguments)
        }
    }

    func lights() -> [(time: TimeInterval, light: HeadsetSession.Light, isOn: Bool)] {
        effects.compactMap {
            guard case let .setLight(light, isOn) = $0.effect else { return nil }
            return ($0.time, light, isOn)
        }
    }

    private mutating func take(_ words: [String], at time: TimeInterval) {
        switch words.first {
        case "do":
            deliver(Self.action(Array(words.dropFirst())), at: time)
        case "hid":
            guard words.count >= 5, let report = Int(words[2]),
                  let bits = UInt8(words[4], radix: 16) else { return }
            let layout: [(bit: UInt8, signal: HeadsetSession.Signal?)] = report == 2
                ? [(0, .standardHook), (2, .standardLine), (3, nil)]
                : [(0, .jabraHook), (3, .jabraLine), (4, nil)]
            let before = reportBits[report] ?? 0
            reportBits[report] = bits
            for (bit, signal) in layout {
                let was = before & (1 << bit) != 0
                let isOn = bits & (1 << bit) != 0
                guard was != isOn else { continue }
                if let signal {
                    deliver(.signal(signal, isOn), at: time)
                } else if isOn {
                    deliver(.muteRequest, at: time)
                }
            }
        default:
            let kinds: [String: UInt8] = ["evt": 0x00, "qry": 0x40, "wrt": 0x80, "rep": 0xc0]
            guard let kind = words.first.flatMap({ kinds[$0] }),
                  words.count >= 13, words[11] == "args" else { return }
            let bytes = words.map { UInt8($0, radix: 16) }
            guard let destination = bytes[2], let source = bytes[4], let sequence = bytes[6],
                  let group = bytes[8], let op = bytes[10] else { return }
            let message = JabraGNP.Message(
                destination: destination,
                source: source,
                sequence: sequence,
                kind: kind,
                group: group,
                op: op,
                arguments: bytes[12...].compactMap { $0 }
            )
            deliver(.message(message), at: time)
        }
    }

    mutating func deliver(_ input: HeadsetSession.Input, at time: TimeInterval) {
        for effect in session.handle(input, at: time) {
            effects.append((time, effect))
            if case let .wake(wake, delay) = effect { wakes.append((time + delay, wake)) }
        }
    }

    private static func action(_ words: [String]) -> HeadsetSession.Input {
        let flag = words.count > 1 && words[1] == "1"
        switch words.first {
        case "setBusy": return .setBusy(flag)
        case "setSidetone": return .setSidetone(flag)
        case "setNoiseMode":
            let byte = words.count > 1 ? UInt8(words[1], radix: 16) ?? 0 : 0
            return .setNoiseMode(JabraGNP.NoiseMode(rawValue: byte) ?? .off)
        case "endCall": return .endCall
        case "stop": return .stop
        case "disconnected": return .disconnected
        default: return .refresh
        }
    }
}

/// An Evolve2 85 behind a Link 380 answering the panel's refresh, idle: in
/// HearThrough with sidetone off, on-ear detection on, not busy, worn, boom
/// down. Captured with its replies; the times start at zero.
private let idleHeadset = """
0.000 do refresh
0.078 rep dst 00 src 04 seq c4 grp 13 op 87 args 03
0.091 rep dst 00 src 04 seq c5 grp 13 op 7c args 01 06
0.109 rep dst 00 src 04 seq c6 grp 13 op 92 args 01
0.124 rep dst 00 src 04 seq c7 grp fe op ff args 04 00 c7 47 13
0.139 rep dst 00 src 04 seq c8 grp 12 op 08 args 00
0.154 rep dst 00 src 04 seq c9 grp 23 op 00 args 01
0.169 rep dst 00 src 04 seq ca grp 0d op 4c args 00 00 01 7f
0.182 rep dst 00 src 04 seq cb grp ff op 04 args 00 cb 8a 0d
0.197 evt dst 00 src 04 seq 6c grp 0d op 4c args 02 00
0.212 evt dst 00 src 04 seq 6d grp 0d op 4c args 02 02
0.234 evt dst 00 src 04 seq 6e grp 0d op 4c args 05 00
0.249 evt dst 00 src 04 seq 6f grp 0d op 4c args 06 01
0.261 evt dst 00 src 04 seq 70 grp 0d op 4c args 03 00
0.276 evt dst 00 src 04 seq 71 grp 0d op 4c args 08 08 00
"""

private func idle(at base: TimeInterval) -> Replay {
    var replay = Replay()
    replay.play(idleHeadset, from: base)
    return replay
}

@Test
func anIdleHeadsetIsReadAndSubscribed() throws {
    let replay = idle(at: 0)
    let controls = try #require(replay.session.shownControls)
    #expect(controls.noiseMode == .hearThrough)
    #expect(controls.sidetone == .init(isOn: false, level: 6))
    #expect(controls.detectsHead == true)
    #expect(controls.isBusy == false)
    #expect(controls.isBoomUp == false)
    #expect(controls.isLeftCupOn == true && controls.isRightCupOn == true)
    // The mask already had setting changes on, so it is written back as is,
    // and telemetry was on, so it is left alone.
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.eventMaskOp).map(\.arguments)
        == [[0x00, 0x00, 0x01, 0x7f]])
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.telemetrySwitchOp).isEmpty)
}

@Test
func theBusylightCombinationLightsBusyAlone() {
    // Volume up and down pressed together, then again: busy and nothing else.
    var replay = idle(at: 90)
    replay.play("""
    95.754 evt dst 00 src 04 seq d1 grp 12 op 08 args 01
    95.784 evt dst 00 src 04 seq d2 grp 0d op 4c args 08 08 01
    """)
    replay.advance(to: 100)
    #expect(replay.controls.isBusy == true)
    #expect(!replay.controls.isCalling)
    #expect(!replay.controls.playsCallAudio)
    replay.play("""
    108.240 evt dst 00 src 04 seq d9 grp 12 op 08 args 00
    108.466 evt dst 00 src 04 seq da grp 0d op 4c args 08 08 00
    """)
    #expect(replay.controls.isBusy == false)
}

@Test
func theCallButtonOpensTheLineAtOnceWithoutACall() {
    // Pressed with no call app, then pressed again; the boom was down and
    // the headset reported its microphone muted as the line opened.
    var replay = idle(at: 110)
    replay.play("""
    112.839 hid rid 4 04 01 00
    112.839 hid rid 4 04 03 00
    113.059 evt dst 00 src 04 seq de grp 0d op 4c args 08 08 01
    """)
    // Jabra's hook switch is up for half a second only: no call.
    #expect(replay.controls.isInCall != true)
    replay.play("""
    113.348 hid rid 4 04 0f 00
    113.349 hid rid 2 02 06 00
    113.357 hid rid 4 04 0e 00
    113.363 evt dst 00 src 04 seq df grp 23 op 01 args 00 01
    """)
    #expect(replay.controls.isLineOpen == true)
    #expect(replay.controls.isBusy == true)
    #expect(replay.session.shownControls?.isMicMuted == true)
    replay.advance(to: 115)
    #expect(replay.controls.isInCall != true)
    replay.play("""
    119.179 hid rid 4 04 0c 00
    119.199 hid rid 4 04 08 00
    119.199 hid rid 2 02 04 00
    119.204 hid rid 4 04 00 00
    119.205 hid rid 2 02 00 00
    119.306 evt dst 00 src 04 seq f9 grp 0d op 4c args 08 08 00
    """)
    #expect(replay.controls.isLineOpen == false)
    #expect(replay.controls.isBusy == false)
    #expect(replay.session.shownControls?.isMicMuted == false)
}

@Test
func aMicrophoneCheckNeverOpensTheLine() {
    var replay = idle(at: 10)
    replay.play("""
    15.098 hid rid 4 04 08 00
    15.099 hid rid 2 02 04 00
    16.656 hid rid 4 04 00 00
    16.657 hid rid 2 02 00 00
    """)
    replay.advance(to: 25)
    #expect(replay.controls.isLineOpen != true)
    #expect(!replay.controls.playsCallAudio)
}

@Test
func aRecordingOpensTheLineOnceItHolds() {
    // Voice Memos recording, with the headset's mute button pressed and
    // released during it.
    var replay = idle(at: 45)
    replay.play("""
    51.214 hid rid 4 04 08 00
    51.215 hid rid 2 02 04 00
    """)
    replay.advance(to: 53)
    #expect(replay.controls.isLineOpen != true)
    replay.advance(to: 55.3)
    #expect(replay.controls.isLineOpen == true)
    #expect(replay.controls.audibleNoiseMode == .off)
    #expect(!replay.controls.isCalling)
    replay.play("""
    57.670 evt dst 00 src 04 seq ae grp 23 op 01 args 00 01
    57.728 hid rid 4 04 18 00
    57.728 hid rid 4 04 08 00
    """)
    #expect(replay.session.shownControls?.isMicMuted == true)
    replay.play("""
    67.747 evt dst 00 src 04 seq bd grp 23 op 01 args 00 00
    73.072 hid rid 4 04 00 00
    73.073 hid rid 2 02 00 00
    """)
    #expect(replay.controls.isLineOpen == false)
    #expect(replay.controls.audibleNoiseMode == .hearThrough)
}

@Test
func aCallAppsCallCountsAtOnceAndRereadsTheModeAfter() {
    // Google Meet with its headset option on: joining, mute and unmute, leaving.
    var replay = idle(at: 60)
    replay.play("""
    66.099 evt dst 00 src 04 seq b0 grp 0d op 4c args 08 08 01
    66.578 hid rid 4 04 0c 00
    66.579 hid rid 2 02 07 00
    """)
    #expect(replay.controls.isInCall == true)
    replay.play("""
    71.964 evt dst 00 src 04 seq b5 grp 23 op 01 args 00 01
    """)
    #expect(replay.session.shownControls?.isMicMuted == true)
    replay.play("""
    73.991 evt dst 00 src 04 seq b7 grp 23 op 01 args 00 00
    79.247 hid rid 4 04 08 00
    79.247 hid rid 2 02 05 00
    79.313 evt dst 00 src 04 seq ba grp 0d op 4c args 08 08 00
    79.487 hid rid 2 02 04 00
    """)
    #expect(replay.controls.isInCall == false)
    replay.advance(to: 200)
    let rereads = replay.sends(kind: JabraGNP.queryKind, op: JabraGNP.noiseModeOp)
        .map { ($0.time - 79.487).rounded() }
    #expect(rereads.suffix(5) == [1, 5, 15, 30, 60])
}

@Test
func hangingUpTheHeadsetsCallFromTheAppEndsItQuietly() {
    // The call button opened the line; the app's hang-up was clicked about
    // 0.5s before the headset raised its hook switch for the brief call.
    var replay = idle(at: 105)
    replay.play("""
    110.744 hid rid 4 04 01 00
    110.745 hid rid 4 04 03 00
    111.098 evt dst 00 src 04 seq 6d grp 0d op 4c args 08 08 01
    111.252 hid rid 4 04 0f 00
    111.253 hid rid 2 02 06 00
    111.261 hid rid 4 04 0e 00
    122.000 do endCall
    122.006 hid rid 4 04 0c 00
    122.506 hid rid 2 02 07 00
    """)
    replay.advance(to: 122.832)
    // Its own brief call never shows as one.
    #expect(replay.controls.isInCall != true)
    replay.play("""
    122.832 hid rid 4 04 08 00
    122.833 hid rid 2 02 05 00
    122.840 hid rid 4 04 00 00
    122.841 hid rid 2 02 01 00
    122.880 evt dst 00 src 04 seq 8a grp 0d op 4c args 08 08 00
    123.070 hid rid 2 02 00 00
    """)
    let lights = replay.lights()
    // Boom down: Off-Hook alone, on at the click and off 0.3s after the
    // headset showed it took the call.
    #expect(lights.map(\.light) == [.offHook, .offHook, .mute])
    #expect(lights.map(\.isOn) == [true, false, false])
    #expect(abs(lights[1].time - 122.806) < 0.001)
    #expect(replay.controls.isInCall != true)
    #expect(replay.controls.isLineOpen == false)
    #expect(replay.controls.isBusy == false)
}

@Test
func hangingUpWithTheBoomRaisedSetsTheMuteLightToo() {
    var replay = idle(at: 80)
    replay.play("""
    85.461 evt dst 00 src 04 seq c3 grp 0d op 4c args 06 00
    86.002 evt dst 00 src 04 seq c4 grp 0d op 4c args 06 02
    90.531 hid rid 4 04 01 00
    90.531 hid rid 4 04 03 00
    91.042 hid rid 4 04 0f 00
    91.048 hid rid 4 04 0e 00
    95.000 do endCall
    """)
    replay.advance(to: 97)
    let lights = replay.lights()
    #expect(lights.prefix(2).map(\.light) == [.mute, .offHook])
    #expect(lights.prefix(2).map(\.isOn) == [true, true])
    // No hook switch came back here, so the fallback clears both.
    #expect(lights.suffix(2).map(\.isOn) == [false, false])
    #expect(abs(lights[2].time - 96.5) < 0.001)
}

@Test
func onEarDetectionDarkensTheLightOnlyWithBothEarcupsOff() {
    var replay = idle(at: 145)
    replay.play("""
    151.293 evt dst 00 src 04 seq 91 grp 0d op 4c args 02 01
    151.636 evt dst 00 src 04 seq 92 grp 0d op 4c args 02 03
    154.498 evt dst 00 src 04 seq 95 grp 12 op 08 args 01
    """)
    #expect(replay.controls.isBusylightDark)
    replay.play("""
    159.321 evt dst 00 src 04 seq 99 grp 0d op 4c args 02 02
    """)
    #expect(!replay.controls.isBusylightDark)
}

@Test
func aSecondClickWhileAWriteSettlesIsSentRightAfter() {
    var replay = idle(at: 30)
    replay.play("""
    40.000 do setSidetone 1
    40.100 do setSidetone 0
    """)
    // Shown at once, before the headset answers.
    #expect(replay.controls.sidetone?.isOn == false)
    replay.advance(to: 41)
    let writes = replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.sidetoneOp)
    #expect(writes.map(\.arguments) == [[0x00, 0x06], [0x01, 0x06]])
    #expect(abs(writes[1].time - 40.4) < 0.001)
}

@Test
func aMuteReportedBeforeARelaunchHoldsOnlyWhileStillEngaged() {
    // The refresh after a relaunch during the call button's call: busy.
    let busyDump = """
    0.000 do refresh
    0.015 rep dst 00 src 04 seq 62 grp 12 op 08 args 01
    0.030 rep dst 00 src 04 seq 63 grp 23 op 00 args 01
    0.045 rep dst 00 src 04 seq 5e grp 13 op 87 args 03
    0.060 rep dst 00 src 04 seq 5f grp 13 op 7c args 01 06
    """
    var remembered = Replay(remembersMute: true)
    remembered.play(busyDump)
    #expect(remembered.session.shownControls?.isMicMuted == true)
    var forgotten = Replay(remembersMute: false)
    forgotten.play(busyDump)
    #expect(forgotten.session.shownControls?.isMicMuted == false)
}

@Test
func aDisconnectForgetsTheHeadsetItsQueueAndItsMute() {
    var replay = idle(at: 0)
    replay.play("""
    1.000 evt dst 00 src 04 seq 30 grp 23 op 01 args 00 01
    1.100 do setSidetone 1
    1.200 do setSidetone 0
    1.300 do disconnected
    """)
    replay.advance(to: 3)
    #expect(replay.session.shownControls == nil)
    #expect(replay.controls == JabraGNP.HeadsetControls())
    // The click queued behind the first write goes with the headset.
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.sidetoneOp).map(\.arguments)
        == [[0x00, 0x06]])
    #expect(replay.effects.contains { $0.time == 1.3 && $0.effect == .rememberMute(false) })
}

@Test
func aCallCutOffByADisconnectIsNotCarriedIntoTheNextConnection() {
    // The headset drops mid-call before its hook switch and line go down,
    // and comes back before the dongle's telephony interface does, so the
    // refresh reads no call signals.
    var replay = idle(at: 0)
    replay.play("""
    6.578 hid rid 4 04 0c 00
    6.579 hid rid 2 02 07 00
    8.000 do disconnected
    """)
    replay.play(idleHeadset, from: 20)
    replay.deliver(.signals(.init()), at: 20.3)
    replay.advance(to: 30)
    #expect(!replay.controls.playsCallAudio)
}

@Test
func noiseControlKeptAtTheAmbienceSettingIsWrittenAndSubscribedThere() {
    // No headset at hand keeps noise control here, so the replies are made
    // up in the op's format: 04 is noise cancellation.
    var replay = Replay()
    replay.play("""
    0.000 do refresh
    0.050 rep dst 00 src 04 seq 01 grp 13 op be args 04
    0.060 rep dst 00 src 04 seq 02 grp 0d op 4c args 00 00 01 7f
    1.000 do setNoiseMode 03
    """)
    #expect(replay.controls.noiseMode == .hearThrough)
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.eventMaskOp).map(\.arguments)
        == [[0x00, 0x00, 0x03, 0x7f]])
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.ambienceModeOp).map(\.arguments)
        == [[0x01, 0x02]])
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.noiseModeOp).isEmpty)
}

@Test
func telemetryFoundOffIsSwitchedOn() {
    var replay = Replay()
    replay.play("""
    0.000 do refresh
    0.050 rep dst 00 src 04 seq 01 grp 13 op 87 args 01
    0.060 rep dst 00 src 04 seq 02 grp 23 op 00 args 00
    """)
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.telemetrySwitchOp).map(\.arguments)
        == [[0x01]])
}

@Test
func anotherAppsReadOfTheMaskIsNeverAnsweredWithAWrite() {
    var replay = idle(at: 0)
    replay.play("""
    5.000 rep dst 00 src 04 seq 40 grp 0d op 4c args 00 00 00 00
    """)
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.eventMaskOp).count == 1)
}

@Test
func aRefusedWriteIsPutRightByItsReadBack() {
    var replay = idle(at: 0)
    replay.play("1.000 do setNoiseMode 01")
    #expect(replay.controls.noiseMode == .cancelling)
    // Made up in the shape of the idle capture's refusal, then the read-back.
    replay.play("""
    1.280 rep dst 00 src 04 seq 50 grp fe op ff args 04 00 50 81 13
    1.300 rep dst 00 src 04 seq 51 grp 13 op 87 args 03
    """)
    #expect(replay.controls.noiseMode == .hearThrough)
}

@Test
func aClickSentAtOnceDropsAnOlderOneStillQueued() {
    var session = idle(at: 0).session
    _ = session.handle(.setSidetone(true), at: 1.0)
    _ = session.handle(.setSidetone(false), at: 1.1)
    // The queue's timer runs late, after a newer click went straight out.
    let newer = session.handle(.setSidetone(true), at: 1.45)
    let late = session.handle(.wake(.writesDue), at: 1.5) + session.handle(.wake(.writesDue), at: 1.9)
    let writes = (newer + late).compactMap { effect -> [UInt8]? in
        guard case let .send(kind, _, op, arguments) = effect,
              kind == JabraGNP.writeKind, op == JabraGNP.sidetoneOp else { return nil }
        return arguments
    }
    #expect(writes == [[0x00, 0x06]])
}

@Test
func aFailedOffHookLightLeavesTheHookSwitchCounting() {
    // The boom-raised hang-up, with the dongle refusing the Off-Hook light.
    var replay = idle(at: 80)
    replay.play("""
    85.461 evt dst 00 src 04 seq c3 grp 0d op 4c args 06 00
    86.002 evt dst 00 src 04 seq c4 grp 0d op 4c args 06 02
    90.531 hid rid 4 04 01 00
    90.531 hid rid 4 04 03 00
    91.042 hid rid 4 04 0f 00
    91.048 hid rid 4 04 0e 00
    95.000 do endCall
    """)
    replay.deliver(.failed(.setLight(.offHook, true)), at: 95)
    replay.play("95.500 hid rid 2 02 01 00")
    replay.advance(to: 97)
    #expect(replay.lights().map(\.light) == [.mute, .offHook, .mute])
    #expect(replay.lights().map(\.isOn) == [true, true, false])
    #expect(replay.controls.isInCall == true)
}

@Test
func aMaskReadThatNeverWentOutLeavesTheNextReplyAlone() {
    var replay = Replay()
    replay.play("0.000 do refresh")
    replay.deliver(.failed(.send(
        kind: JabraGNP.queryKind,
        group: JabraGNP.pairingGroup,
        op: JabraGNP.eventMaskOp,
        arguments: []
    )), at: 0)
    replay.play("""
    0.050 rep dst 00 src 04 seq 01 grp 13 op 87 args 01
    0.300 rep dst 00 src 04 seq 02 grp 0d op 4c args 00 00 01 7f
    """)
    #expect(replay.sends(kind: JabraGNP.writeKind, op: JabraGNP.eventMaskOp).isEmpty)
}
