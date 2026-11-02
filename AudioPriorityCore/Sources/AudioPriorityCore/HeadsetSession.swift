import Foundation

/// What the app knows about the headset behind one Link dongle, and what it
/// asks of it, kept apart from HID so recorded traffic can be replayed
/// through it. The driver feeds it timestamped inputs and carries out the
/// effects it returns.
public struct HeadsetSession: Sendable {

    /// Telephony inputs the driver reports as they change.
    public enum Signal: Sendable, Equatable {
        case standardHook
        /// Jabra's own copy of the hook switch, which Jabra Direct's call app
        /// plugins use, and which the call button flashes as it starts a call
        /// of the headset's own.
        case jabraHook
        case standardLine
        case jabraLine
    }

    /// The current call signals, read when the controls are refreshed. Nil
    /// for an element the dongle does not have.
    public struct Signals: Sendable, Equatable {
        public var standardHook: Bool?
        public var jabraHook: Bool?
        public var standardLine: Bool?
        public var jabraLine: Bool?

        public init(
            standardHook: Bool? = nil,
            jabraHook: Bool? = nil,
            standardLine: Bool? = nil,
            jabraLine: Bool? = nil
        ) {
            self.standardHook = standardHook
            self.jabraHook = jabraHook
            self.standardLine = standardLine
            self.jabraLine = jabraLine
        }
    }

    public enum Light: Sendable, Equatable {
        case offHook
        case mute
    }

    public enum Wake: Sendable, Equatable {
        case hookSettled
        case lineSettled
        case writesDue
        case muteLight
        case modeAfterCall
        /// Must fire even if the dongle's interfaces change meanwhile, so the
        /// lights it clears never stay on.
        case endCall
    }

    public enum Input: Sendable, Equatable {
        /// The headset is connected: read its controls and subscribe.
        case refresh
        case disconnected
        case message(JabraGNP.Message)
        case signal(Signal, Bool)
        case signals(Signals)
        /// A press of the mute button or move of the boom, which a call app
        /// answers on the Mute light some time later.
        case muteRequest
        case muteLight(Bool?)
        case wake(Wake)
        case setNoiseMode(JabraGNP.NoiseMode)
        case setSidetone(Bool)
        case setBusy(Bool)
        /// End a call the headset's call button started.
        case endCall
        case stop
        /// An effect the driver could not carry out.
        case failed(Effect)
    }

    public enum Effect: Sendable, Equatable {
        case send(kind: UInt8, group: UInt8, op: UInt8, arguments: [UInt8])
        case setLight(Light, Bool)
        case readMuteLight
        case readSignals
        case wake(Wake, after: TimeInterval)
        case changed
        /// Whether the headset's last mute report was "muted", kept for a
        /// relaunch during the same call.
        case rememberMute(Bool)
    }

    // MARK: - Timing, all measured on an Evolve2 85

    /// Writes this close together lost the first one while noise cancellation
    /// was switching, its acknowledgement taking 280ms.
    static let writeSpacing: TimeInterval = 0.4
    /// The call button raises Jabra's hook switch for about half a second as
    /// it starts the headset's own call, so a call on that switch counts only
    /// once it stays up.
    static let hookSettle: TimeInterval = 1
    /// Something checks the microphone for 1.5 to 3s every so often, so an
    /// open line counts only once it has stayed open longer.
    static let lineSettle: TimeInterval = 4
    /// The call button raises Jabra's hook switch half a second before it
    /// opens the line, which nothing using the microphone does.
    static let callButtonWindow: TimeInterval = 1.5
    /// The headset took 0.5s to answer the Off-Hook light, so it is held
    /// longer before being cleared, should the hook switch never show it.
    static let endCallHold: TimeInterval = 1.5
    /// Once its hook switch shows the headset took the call, the Off-Hook
    /// light is cleared this soon after.
    static let endCallAnswer: TimeInterval = 0.3
    /// Restores after long calls landed several seconds after the call ended.
    static let afterCallRereads: [TimeInterval] = [1, 5, 15, 30, 60]
    /// Another call app sets the Mute light some time after the request.
    /// ponytail: fixed delays; a later change shows on the next panel open.
    static let muteLightRereads: [TimeInterval] = [0.3, 1]

    // MARK: - State

    public private(set) var controls = JabraGNP.HeadsetControls()
    /// Set while our own read of the event mask is pending, so another app's
    /// read of it never makes us write.
    private var awaitsEventMask = false
    /// The headset answered for noise control at `ambienceModeOp` rather than
    /// `noiseModeOp`.
    private var usesAmbience = false
    /// From the Mute light, which every client reads alike.
    private var confirmedMute: Bool?
    /// What the headset itself last reported. It sends no current value on
    /// request, so this is unknown until the first change.
    private var reportedMute: Bool?
    private var remembersMute: Bool
    /// A call sets one hook switch or the other, depending on whether its app
    /// uses the standard telephony controls or Jabra's copy.
    private var hooks = (standard: false, jabra: false)
    private var lines = (standard: false, jabra: false)
    private var jabraHookRoseAt = -TimeInterval.greatestFiniteMagnitude
    /// While the app ends a call the headset started, the hook switch it
    /// raises on the way is its own, not a call.
    private var endsCallUntil = -TimeInterval.greatestFiniteMagnitude
    private var isEndingCall = false
    private var quietUntil: TimeInterval = 0
    /// Clicks that came while the last write settled, sent in turn once it
    /// has, keeping the latest for each setting.
    private var pendingWrites: [(group: UInt8, op: UInt8, arguments: [UInt8])] = []

    /// `remembersMute`: a mute reported during the call still under way when
    /// the app last quit.
    public init(remembersMute: Bool = false) {
        self.remembersMute = remembersMute
    }

    /// The controls as the row shows them, nil until the headset answers for
    /// a setting it has.
    public var shownControls: JabraGNP.HeadsetControls? {
        guard controls.hasControls else { return nil }
        var shown = controls
        shown.answeredMute = Self.engaged(controls) == true ? reportedMute ?? confirmedMute : nil
        return shown
    }

    // MARK: - Inputs

    public mutating func handle(_ input: Input, at now: TimeInterval) -> [Effect] {
        var effects: [Effect] = []
        switch input {
        case .refresh:
            for op in [
                JabraGNP.noiseModeOp, JabraGNP.sidetoneOp,
                JabraGNP.headDetectionOp, JabraGNP.ambienceModeOp,
            ] {
                effects.append(Self.read(JabraGNP.settingsGroup, op))
            }
            effects.append(Self.read(JabraGNP.statusGroup, JabraGNP.busyOp))
            effects.append(Self.read(JabraGNP.telemetryGroup, JabraGNP.telemetrySwitchOp))
            effects.append(.readSignals)
            // Asked last, so the settings it would report have answered.
            awaitsEventMask = true
            effects.append(Self.read(JabraGNP.pairingGroup, JabraGNP.eventMaskOp))
            effects.append(.readMuteLight)
        case .disconnected:
            // The next headset to connect may not be this one.
            controls = JabraGNP.HeadsetControls()
            awaitsEventMask = false
            usesAmbience = false
            pendingWrites.removeAll()
            setReportedMute(nil, &effects)
        case let .message(message):
            receive(message, at: now, &effects)
        case let .signal(signal, isOn):
            note(signal, isOn, at: now, &effects)
        case let .signals(signals):
            // Read as they stand, so a call or line already under way counts
            // at once.
            if let up = signals.standardHook { hooks.standard = up }
            if let up = signals.jabraHook { hooks.jabra = up }
            if let open = signals.standardLine { lines.standard = open }
            if let open = signals.jabraLine { lines.jabra = open }
            apply(.inCall(hooks.standard || hooks.jabra), at: now, &effects)
            apply(.lineOpen(lines.standard || lines.jabra), at: now, &effects)
        case .muteRequest:
            for delay in Self.muteLightRereads { effects.append(.wake(.muteLight, after: delay)) }
        case let .muteLight(isLit):
            // A call app lights it while muted only if it supports headsets,
            // so an unlit light proves nothing.
            let mute: Bool? = isLit == true ? true : nil
            guard mute != confirmedMute else { break }
            confirmedMute = mute
            effects.append(.changed)
        case let .wake(wake):
            fire(wake, at: now, &effects)
        case let .setNoiseMode(mode):
            guard controls.noiseMode != nil else { break }
            // Each choice shows at once; the read-back after its write puts
            // back what the headset kept, should it refuse.
            if usesAmbience {
                write(JabraGNP.settingsGroup, JabraGNP.ambienceModeOp, JabraGNP.ambienceArguments(mode), at: now, &effects)
                apply(.ambienceMode(mode), at: now, &effects)
            } else {
                write(JabraGNP.settingsGroup, JabraGNP.noiseModeOp, [mode.rawValue], at: now, &effects)
                apply(.noiseMode(mode), at: now, &effects)
            }
        case let .setSidetone(isOn):
            guard var sidetone = controls.sidetone else { break }
            sidetone.isOn = isOn
            write(JabraGNP.settingsGroup, JabraGNP.sidetoneOp, sidetone.arguments, at: now, &effects)
            apply(.sidetone(sidetone), at: now, &effects)
        case let .setBusy(isBusy):
            guard controls.isBusy != nil else { break }
            write(JabraGNP.statusGroup, JabraGNP.busyOp, JabraGNP.busyArguments(isBusy), at: now, &effects)
            apply(.busy(isBusy), at: now, &effects)
        case .endCall:
            endCall(at: now, &effects)
        case .stop:
            finishEndingCall(&effects)
        case let .failed(effect):
            undo(effect, &effects)
        }
        return effects
    }

    /// Puts back what the session assumed when it asked for `effect`.
    private mutating func undo(_ effect: Effect, _ effects: inout [Effect]) {
        switch effect {
        case .setLight(.offHook, true) where isEndingCall:
            // Without the Off-Hook light there is no call to end, so the hook
            // switch counts again.
            isEndingCall = false
            endsCallUntil = -TimeInterval.greatestFiniteMagnitude
            effects.append(.setLight(.mute, false))
        case .send(_, JabraGNP.pairingGroup, JabraGNP.eventMaskOp, _):
            awaitsEventMask = false
        default:
            break
        }
    }

    private mutating func receive(
        _ message: JabraGNP.Message,
        at now: TimeInterval,
        _ effects: inout [Effect]
    ) {
        if let setting = JabraGNP.headsetSetting(message) {
            apply(setting, at: now, &effects)
            return
        }
        switch JabraGNP.headsetEvent(message) {
        case let .settingsChanged(ops)?:
            // The event names what changed, not the new value.
            let followed = [
                JabraGNP.noiseModeOp, JabraGNP.ambienceModeOp,
                JabraGNP.sidetoneOp, JabraGNP.headDetectionOp,
            ]
            for op in ops where followed.contains(op) {
                effects.append(Self.read(JabraGNP.settingsGroup, op))
            }
        case let .busy(isBusy)?:
            apply(.busy(isBusy), at: now, &effects)
        case let .boomUp(isUp)?:
            apply(.boomUp(isUp), at: now, &effects)
        case let .earcup(isLeft, isOn)?:
            apply(.earcup(isLeft: isLeft, isOn: isOn), at: now, &effects)
        case let .ambienceMode(mode)?:
            apply(.ambienceMode(mode), at: now, &effects)
        case let .micMuted(isMuted)?:
            guard reportedMute != isMuted else { return }
            setReportedMute(isMuted, &effects)
            effects.append(.changed)
        case nil:
            break
        }
    }

    private mutating func note(
        _ signal: Signal,
        _ isOn: Bool,
        at now: TimeInterval,
        _ effects: inout [Effect]
    ) {
        switch signal {
        case .standardHook:
            hooks.standard = isOn
            if isOn, isEndingCall { effects.append(.wake(.endCall, after: Self.endCallAnswer)) }
            noteHooks(at: now, &effects)
        case .jabraHook:
            if isOn, !hooks.jabra { jabraHookRoseAt = now }
            hooks.jabra = isOn
            noteHooks(at: now, &effects)
        case .standardLine:
            lines.standard = isOn
            noteLines(at: now, &effects)
        case .jabraLine:
            lines.jabra = isOn
            noteLines(at: now, &effects)
        }
    }

    /// The standard hook switch rises for calls alone and counts at once;
    /// Jabra's copy only once it stays up. Either going down counts at once.
    private mutating func noteHooks(at now: TimeInterval, _ effects: inout [Effect]) {
        guard hooks.standard || hooks.jabra else {
            apply(.inCall(false), at: now, &effects)
            return
        }
        guard now > endsCallUntil else { return }
        if hooks.standard {
            apply(.inCall(true), at: now, &effects)
        } else {
            effects.append(.wake(.hookSettled, after: Self.hookSettle))
        }
    }

    /// Opening the microphone line makes the headset play call audio, with or
    /// without a call: an app recording, or its call button pressed with no
    /// call app, which opens the line until it is pressed again.
    private mutating func noteLines(at now: TimeInterval, _ effects: inout [Effect]) {
        guard lines.standard || lines.jabra else {
            apply(.lineOpen(false), at: now, &effects)
            return
        }
        if now - jabraHookRoseAt <= Self.callButtonWindow {
            apply(.lineOpen(true), at: now, &effects)
        } else {
            effects.append(.wake(.lineSettled, after: Self.lineSettle))
        }
    }

    private mutating func fire(_ wake: Wake, at now: TimeInterval, _ effects: inout [Effect]) {
        switch wake {
        case .hookSettled:
            guard hooks.standard || hooks.jabra, now > endsCallUntil else { return }
            apply(.inCall(true), at: now, &effects)
        case .lineSettled:
            guard lines.standard || lines.jabra else { return }
            apply(.lineOpen(true), at: now, &effects)
        case .writesDue:
            guard !pendingWrites.isEmpty else { return }
            guard now >= quietUntil else {
                effects.append(.wake(.writesDue, after: quietUntil - now))
                return
            }
            let next = pendingWrites.removeFirst()
            write(next.group, next.op, next.arguments, at: now, &effects)
            if !pendingWrites.isEmpty {
                effects.append(.wake(.writesDue, after: quietUntil - now))
            }
        case .muteLight:
            effects.append(.readMuteLight)
        case .modeAfterCall:
            let op = usesAmbience ? JabraGNP.ambienceModeOp : JabraGNP.noiseModeOp
            effects.append(Self.read(JabraGNP.settingsGroup, op))
        case .endCall:
            finishEndingCall(&effects)
        }
    }

    // MARK: - Ending a call the headset started

    /// The way a softphone ends a call: Off-Hook on, then off. Off alone
    /// changes nothing. With the boom raised the Mute light goes on too, or
    /// the headset reminds the wearer to lower it as the brief call starts;
    /// with the boom down the light would have it announce a mute instead.
    private mutating func endCall(at now: TimeInterval, _ effects: inout [Effect]) {
        guard controls.isLineOpen == true, controls.isInCall != true else { return }
        if controls.isBoomUp == true { effects.append(.setLight(.mute, true)) }
        effects.append(.setLight(.offHook, true))
        isEndingCall = true
        endsCallUntil = now + Self.endCallHold + Self.hookSettle + 1
        effects.append(.wake(.endCall, after: Self.endCallHold))
    }

    private mutating func finishEndingCall(_ effects: inout [Effect]) {
        guard isEndingCall else { return }
        isEndingCall = false
        effects.append(.setLight(.offHook, false))
        effects.append(.setLight(.mute, false))
    }

    // MARK: - Writes

    /// Writes a setting and reads it straight back, so the panel shows what
    /// the headset kept rather than what was asked.
    private mutating func write(
        _ group: UInt8,
        _ op: UInt8,
        _ arguments: [UInt8],
        at now: TimeInterval,
        _ effects: inout [Effect]
    ) {
        // An older click for the same setting still queued would otherwise
        // undo this one once the queue drains.
        let isQueueWaking = !pendingWrites.isEmpty
        pendingWrites.removeAll { $0.group == group && $0.op == op }
        guard now >= quietUntil else {
            pendingWrites.append((group, op, arguments))
            if !isQueueWaking {
                effects.append(.wake(.writesDue, after: quietUntil - now))
            }
            return
        }
        quietUntil = now + Self.writeSpacing
        effects.append(.send(kind: JabraGNP.writeKind, group: group, op: op, arguments: arguments))
        effects.append(Self.read(group, op))
    }

    private static func read(_ group: UInt8, _ op: UInt8) -> Effect {
        .send(
            kind: JabraGNP.queryKind,
            group: group,
            op: op,
            arguments: group == JabraGNP.settingsGroup ? JabraGNP.readArguments(for: op) : []
        )
    }

    // MARK: - Settings

    private mutating func apply(
        _ setting: JabraGNP.HeadsetSetting,
        at now: TimeInterval,
        _ effects: inout [Effect]
    ) {
        var next = controls
        switch setting {
        case let .eventMask(mask):
            guard awaitsEventMask else { return }
            awaitsEventMask = false
            guard controls.hasControls else { return }
            effects.append(.send(
                kind: JabraGNP.writeKind,
                group: JabraGNP.pairingGroup,
                op: JabraGNP.eventMaskOp,
                arguments: JabraGNP.subscribedMask(mask, ambience: usesAmbience)
            ))
            return
        case let .telemetryOn(isOn):
            // The mute reports need it, and Jabra Direct may not be there to
            // switch it on.
            guard !isOn, controls.hasControls else { return }
            effects.append(.send(
                kind: JabraGNP.writeKind,
                group: JabraGNP.telemetryGroup,
                op: JabraGNP.telemetrySwitchOp,
                arguments: [0x01]
            ))
            return
        case let .noiseMode(mode):
            next.noiseMode = mode
        case let .ambienceMode(mode):
            usesAmbience = true
            next.noiseMode = mode
        case let .sidetone(sidetone):
            next.sidetone = sidetone
        case let .busy(isBusy):
            next.isBusy = isBusy
        case let .inCall(isInCall):
            next.setInCall(isInCall)
        case let .lineOpen(isOpen):
            next.isLineOpen = isOpen
        case let .boomUp(isUp):
            next.isBoomUp = isUp
        case let .headDetection(isOn):
            next.detectsHead = isOn
        case let .earcup(isLeft, isOn):
            if isLeft { next.isLeftCupOn = isOn } else { next.isRightCupOn = isOn }
        }
        guard next != controls else { return }
        let callChanged = controls.isInCall != next.isInCall
        let callEnded = controls.isInCall == true && next.isInCall == false
        let wasEngaged = Self.engaged(controls)
        let isEngaged = Self.engaged(next)
        controls = next
        if wasEngaged == nil, let isEngaged {
            // First sight after a launch: a mute saved during this same call
            // still holds, one saved before a call that has since ended does not.
            if isEngaged, reportedMute == nil, remembersMute {
                reportedMute = true
            } else if !isEngaged {
                setReportedMute(nil, &effects)
            }
        } else if wasEngaged == true, isEngaged == false {
            setReportedMute(nil, &effects)
        }
        if callEnded {
            // The headset puts back the mode it had before the call without
            // announcing it, sometimes seconds later.
            for delay in Self.afterCallRereads { effects.append(.wake(.modeAfterCall, after: delay)) }
        }
        if callChanged { effects.append(.readMuteLight) }
        effects.append(.changed)
    }

    /// Microphone line open or busy, the times the headset's mute means
    /// something; nil while none is known yet.
    private static func engaged(_ controls: JabraGNP.HeadsetControls) -> Bool? {
        guard controls.isInCall != nil || controls.isLineOpen != nil || controls.isBusy != nil
        else { return nil }
        return controls.playsCallAudio || controls.isBusy == true
    }

    private mutating func setReportedMute(_ isMuted: Bool?, _ effects: inout [Effect]) {
        reportedMute = isMuted
        remembersMute = isMuted == true
        effects.append(.rememberMute(isMuted == true))
    }
}
