import AudioPriorityCore
import Foundation
import IOKit.hid

/// Tracks whether a headset is actually connected to each attached Jabra
/// dongle.
///
/// The dongle's telephony link bit cannot carry this on its own: about 1.8s
/// after USB enumeration the dongle asserts a false "linked", identically
/// whether a headset is on or off, and never corrects it. The authoritative
/// answer comes from asking the dongle over its GNP management channel. The
/// legacy bit is kept for two narrower jobs: a fallback for devices that do
/// not answer GNP, and a cheap trigger telling us a real transition happened
/// and it is worth re-querying.
@MainActor
final class JabraHIDMonitor {

    // MARK: - Interfaces and dongles

    /// One HID interface. A dongle may expose several.
    private final class Interface {
        let device: IOHIDDevice
        let profile: JabraProfile?
        var legacyElement: IOHIDElement?
        var management: JabraGNP.Layout?
        var managementOutput: IOHIDElement?
        var offHook: IOHIDElement?
        var muteLight: IOHIDElement?
        var phoneMute: IOHIDElement?
        var hookSwitch: IOHIDElement?
        /// Jabra's own copy of the telephony controls, which Jabra Direct's
        /// call app plugins such as Zoom's use instead of the standard ones.
        var jabraHookSwitch: IOHIDElement?
        var hasHookSwitch: Bool { hookSwitch != nil || jabraHookSwitch != nil }
        /// The microphone line, on each page.
        var line: IOHIDElement?
        var jabraLine: IOHIDElement?
        var watchesTelephony: Bool {
            phoneMute != nil || hasHookSwitch || line != nil || jabraLine != nil
        }
        var reassembler = JabraGNP.Reassembler()
        var buffer: UnsafeMutablePointer<UInt8>?
        var bufferSize = 0

        init(device: IOHIDDevice, profile: JabraProfile?) {
            self.device = device
            self.profile = profile
        }

        deinit {
            buffer?.deallocate()
        }
    }

    /// One in-flight pairing-database walk.
    private final class Query {
        var walk = JabraGNP.PairingWalk()
        var sequence: UInt8 = 0
        var timeout: DispatchWorkItem?
        /// Request in flight, kept so a dropped one can be re-sent.
        var cursor: [UInt8] = []
        var bluetoothType: UInt8 = 0
        var attempt = 0
        let generation: Int
        let interface: Interface

        init(generation: Int, interface: Interface) {
            self.generation = generation
            self.interface = interface
        }
    }

    /// One physical dongle, identified by serial so two dongles of the same
    /// model never contaminate each other's state.
    private final class Dongle {
        let key: String
        let serial: String?
        var profileID: JabraProfile.ID?
        var interfaces: [IOHIDDevice: Interface] = [:]
        /// Bumped whenever membership changes, so asynchronous work that
        /// completes late cannot update a replacement dongle.
        var generation = 0
        var attachedAt: TimeInterval
        var legacy = DebouncedLinkState()
        var pendingDown: DispatchWorkItem?
        var vendor: JabraGNP.Evidence?
        var resolved: Bool?
        /// Last state published to the model. Tracked as a `LinkState` rather
        /// than a boolean so leaving `.checking` still notifies even when the
        /// underlying value happens to be unchanged.
        var reported: LinkState?
        var query: Query?
        var lastQueryAt: TimeInterval = -.greatestFiniteMagnitude
        /// True until the first query for this attachment settles. Until then
        /// the legacy bit is not trustworthy, because the dongle lies right
        /// after enumeration.
        var awaitingFirstAnswer = true
        /// Set when the dongle announced a change while a walk was already
        /// running. Announcements arrive in pairs about 100ms apart, so that
        /// walk may have read its records before the change landed and another
        /// has to follow it.
        var requeryWhenIdle = false
        /// The headset's battery percentage, nil until it answers.
        var battery: Int?
        var lastBatteryQueryAt: TimeInterval = -.greatestFiniteMagnitude
        var session: HeadsetSession

        init(key: String, serial: String?, attachedAt: TimeInterval, remembersMute: Bool) {
            self.key = key
            self.serial = serial
            self.attachedAt = attachedAt
            session = HeadsetSession(remembersMute: remembersMute)
        }

        var managementInterface: Interface? {
            interfaces.values.first { $0.management != nil }
        }
    }

    /// How an audio device binds to the dongles we monitor.
    private enum Binding {
        case unmonitored
        case one(Dongle)
        /// Known to be a Jabra we would monitor, but not bindable to exactly
        /// one dongle, so it must fail open rather than borrow another's state.
        case unidentified
    }

    var onLinkChange: (() -> Void)?
    /// The headset's battery or one of its controls changed.
    var onHeadsetChange: (() -> Void)?

    private var manager: IOHIDManager?
    private var pollTimer: Timer?
    private var dongles: [String: Dongle] = [:]
    private var interfaceKeys: [IOHIDDevice: String] = [:]
    private var sequence: UInt8 = 0
    private var isRunning = false

    private static let downDebounce: TimeInterval = 3
    private static let pollInterval: TimeInterval = 2
    /// The dongle's false "linked" claim lands about 1.8s after enumeration,
    /// so positive legacy claims inside this window are not evidence.
    private static let enumerationSuppression: TimeInterval = 3
    /// A completed walk costs about 0.4s when nothing is connected, so the
    /// safety-net refresh is slow. Real transitions do not wait for it: the
    /// dongle announces them and that triggers a walk immediately. This only
    /// covers an announcement being missed entirely.
    private static let vendorRefreshInterval: TimeInterval = 10
    /// A settled dongle answers in about 4ms, but for roughly 265ms after
    /// enumeration it silently drops requests instead of queueing them. So the
    /// per-request wait is short and a dropped request is simply re-sent,
    /// keeping the overall budget for a first answer near 1.5s.
    private static let queryTimeout: TimeInterval = 0.5
    private static let maximumAttempts = 3
    /// The headset also reports a changed level on its own, so asking is only
    /// the backstop.
    private static let batteryRefreshInterval: TimeInterval = 60
    /// The headset reports its mute only when it changes, so the last report
    /// is kept for a relaunch during the same call.
    private static let mutedKey = "headsetMicMutedDongle"
    /// Jabra's vendor copy of the telephony page.
    private static let jabraTelephonyPage = 0xff30
    private let defaults = UserDefaults.standard

    // MARK: - Lifecycle

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        isRunning = true
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey: JabraLink.vendorID] as CFDictionary
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            Self.matchCallback,
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            Self.removalCallback,
            context
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            isRunning = false
            self.manager = nil
            return
        }
        if let matched = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in matched { attach(device) }
        }
    }

    /// Stops every producer before returning, so no callback, timeout or
    /// debounce can fire afterwards.
    func stop() {
        guard let manager else { return }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        for dongle in dongles.values {
            dongle.generation += 1
            dongle.pendingDown?.cancel()
            dongle.pendingDown = nil
            dongle.query?.timeout?.cancel()
            dongle.query = nil
            run(dongle, .stop)
            for interface in dongle.interfaces.values { tearDown(interface) }
        }
        dongles.removeAll()
        interfaceKeys.removeAll()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, 0)
        self.manager = nil
    }

    // MARK: - Queries from the model

    func linkState(for device: AudioDevice) -> LinkState {
        switch binding(for: device) {
        case .unmonitored:
            return .unknown
        case .unidentified:
            return .monitoringUnavailable
        case let .one(dongle):
            return Self.state(of: dongle)
        }
    }

    func isUsable(_ device: AudioDevice) -> Bool {
        let binding = binding(for: device)
        let isSupported: Bool
        if case .unmonitored = binding { isSupported = false } else { isSupported = true }
        return JabraLink.allowsSelection(
            isSupported: isSupported,
            state: linkState(for: device)
        )
    }

    func monitoredState(for device: AudioDevice) -> LinkState? {
        if case .unmonitored = binding(for: device) { return nil }
        return linkState(for: device)
    }

    func batteryLevel(for device: AudioDevice) -> Int? {
        guard case let .one(dongle) = binding(for: device),
              Self.state(of: dongle) == .up else { return nil }
        return dongle.battery
    }

    func headsetControls(for device: AudioDevice) -> JabraGNP.HeadsetControls? {
        guard case let .one(dongle) = binding(for: device),
              Self.state(of: dongle) == .up else { return nil }
        return dongle.session.shownControls
    }

    func setNoiseMode(_ mode: JabraGNP.NoiseMode, for device: AudioDevice) {
        guard case let .one(dongle) = binding(for: device) else { return }
        run(dongle, .setNoiseMode(mode))
    }

    func setSidetone(_ isOn: Bool, for device: AudioDevice) {
        guard case let .one(dongle) = binding(for: device) else { return }
        run(dongle, .setSidetone(isOn))
    }

    /// Lights or clears the busylight, as its button on the headset does.
    func setBusy(_ isBusy: Bool, for device: AudioDevice) {
        guard case let .one(dongle) = binding(for: device) else { return }
        run(dongle, .setBusy(isBusy))
    }

    /// Ends a call the headset's call button started.
    func endHeadsetCall(for device: AudioDevice) {
        guard case let .one(dongle) = binding(for: device) else { return }
        run(dongle, .endCall)
    }

    // MARK: - Headset session

    /// Feeds the session one input and carries out what it asks for.
    private func run(_ dongle: Dongle, _ input: HeadsetSession.Input) {
        let effects = dongle.session.handle(input, at: ProcessInfo.processInfo.systemUptime)
        // Every walk that finds no headset says so again, and a worn headset
        // streams telemetry several times a second, both with nothing to do.
        let isRepeat = switch input {
        case .disconnected: true
        case let .message(message): message.group == JabraGNP.telemetryGroup
        default: false
        }
        if !isRepeat || !effects.isEmpty {
            DebugLog.shared.write("Jabra \(dongle.key) headset: \(input) gives \(effects)"
                .replacing(/AudioPriorityCore\.(HeadsetSession\.(Effect\.)?|JabraGNP\.)?/, with: ""))
        }
        var changed = false
        for effect in effects {
            if effect == .changed { changed = true } else { perform(effect, for: dongle) }
        }
        if changed, isRunning { onHeadsetChange?() }
    }

    private func perform(_ effect: HeadsetSession.Effect, for dongle: Dongle) {
        switch effect {
        case let .send(kind, group, op, arguments):
            if !sendToHeadset(dongle, kind: kind, group: group, op: op, arguments: arguments) {
                run(dongle, .failed(effect))
            }
        case let .setLight(light, isOn):
            if !setLight(dongle, light == .offHook ? \.offHook : \.muteLight, isOn) {
                run(dongle, .failed(effect))
            }
        case .readMuteLight:
            run(dongle, .muteLight(muteLight(dongle)))
        case .readSignals:
            run(dongle, .signals(readCallSignals(dongle)))
        case let .wake(.endCall, delay):
            // Not tied to the dongle's generation: the lights must go off
            // even if an interface comes or goes meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.run(dongle, .wake(.endCall)) }
            }
        case let .wake(wake, delay):
            // Queued writes drain even if another of the dongle's interfaces
            // attaches meanwhile, or later clicks would wait behind them.
            afterDelay(dongle, delay, sameGeneration: wake != .writesDue) { $0.run($1, .wake(wake)) }
        case let .rememberMute(isMuted):
            if isMuted {
                defaults.set(dongle.key, forKey: Self.mutedKey)
            } else if defaults.string(forKey: Self.mutedKey) == dongle.key {
                defaults.removeObject(forKey: Self.mutedKey)
            }
        case .changed:
            break
        }
    }

    @discardableResult
    private func setLight(
        _ dongle: Dongle,
        _ light: KeyPath<Interface, IOHIDElement?>,
        _ isOn: Bool
    ) -> Bool {
        guard let interface = dongle.interfaces.values.first(where: { $0[keyPath: light] != nil }),
              let element = interface[keyPath: light] else { return false }
        let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, isOn ? 1 : 0)
        return IOHIDDeviceSetValue(interface.device, element, value) == kIOReturnSuccess
    }

    private func readCallSignals(_ dongle: Dongle) -> HeadsetSession.Signals {
        func read(_ element: KeyPath<Interface, IOHIDElement?>) -> Bool? {
            for interface in dongle.interfaces.values {
                if let element = interface[keyPath: element],
                   let value = Self.integerValue(interface.device, element) {
                    return value != 0
                }
            }
            return nil
        }
        return HeadsetSession.Signals(
            standardHook: read(\.hookSwitch),
            jabraHook: read(\.jabraHookSwitch),
            standardLine: read(\.line),
            jabraLine: read(\.jabraLine)
        )
    }

    private func muteLight(_ dongle: Dongle) -> Bool? {
        guard let interface = dongle.interfaces.values.first(where: { $0.muteLight != nil }),
              let light = interface.muteLight else { return nil }
        return Self.integerValue(interface.device, light).map { $0 != 0 }
    }

    /// Runs `body` later unless the dongle has gone or, with `sameGeneration`,
    /// changed meanwhile.
    private func afterDelay(
        _ dongle: Dongle,
        _ delay: TimeInterval,
        sameGeneration: Bool = true,
        _ body: @escaping @MainActor (JabraHIDMonitor, Dongle) -> Void
    ) {
        let key = dongle.key
        let generation = dongle.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.isRunning,
                      let current = self.dongles[key],
                      !sameGeneration || current.generation == generation else { return }
                body(self, current)
            }
        }
    }

    /// Events keep the controls current once subscribed. Opening the panel
    /// reads them again in case another app reset the subscription, and
    /// reads the Mute light, which another call app changes silently.
    func refreshHeadsetControls() {
        for dongle in dongles.values where Self.state(of: dongle) == .up {
            run(dongle, .refresh)
        }
    }

    /// Binds an audio device to at most one physical dongle. The USB serial in
    /// the CoreAudio UID is preferred because it is exact; the product name is
    /// only consulted when the serial cannot identify anything, and then only
    /// when the answer is unambiguous.
    private func binding(for device: AudioDevice) -> Binding {
        let profile = JabraLink.profile(matching: device.name)
        if let serial = JabraLink.serial(fromAudioUID: device.uid) {
            let matches = dongles.values.filter { dongle in
                dongle.serial.map { JabraLink.serialsMatch($0, serial) } == true
            }
            if matches.count == 1 { return .one(matches[0]) }
            if matches.count > 1 { return .unidentified }
            return profile == nil ? .unmonitored : .unidentified
        }
        guard let profile else { return .unmonitored }
        let candidates = dongles.values.filter { $0.profileID == profile.id }
        return candidates.count == 1 ? .one(candidates[0]) : .unidentified
    }

    // MARK: - Attach and detach

    private func attach(_ device: IOHIDDevice) {
        guard isRunning, interfaceKeys[device] == nil else { return }
        let name = IOHIDDeviceGetProperty(
            device,
            kIOHIDProductKey as CFString
        ) as? String
        // Restrict monitoring to dongles. A directly connected Jabra headset or
        // speakerphone can expose the same management collection, and reporting
        // its empty pairing list as a down link would make a working device
        // unselectable.
        guard let name, JabraLink.isDongleProduct(name) else { return }
        let profile = JabraLink.profile(matching: name)
        let management = Self.managementLayout(device)
        // Among dongles, capability rather than a model allow-list decides.
        guard management != nil || profile != nil else { return }
        guard IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { return }

        let interface = Interface(device: device, profile: profile)
        interface.management = management?.layout
        interface.managementOutput = management?.output
        interface.offHook = Self.telephonyElement(device, kHIDPage_LEDs, kHIDUsage_LED_OffHook, output: true)
        interface.muteLight = Self.telephonyElement(device, kHIDPage_LEDs, kHIDUsage_LED_Mute, output: true)
        interface.phoneMute = Self.telephonyElement(device, kHIDPage_Telephony, kHIDUsage_Tfon_PhoneMute, output: false)
        interface.hookSwitch = Self.telephonyElement(device, kHIDPage_Telephony, kHIDUsage_Tfon_HookSwitch, output: false)
        interface.jabraHookSwitch = Self.telephonyElement(device, Self.jabraTelephonyPage, kHIDUsage_Tfon_HookSwitch, output: false)
        interface.line = Self.telephonyElement(device, kHIDPage_Telephony, kHIDUsage_Tfon_Line, output: false)
        interface.jabraLine = Self.telephonyElement(device, Self.jabraTelephonyPage, kHIDUsage_Tfon_Line, output: false)

        let identity = Self.identity(of: device)
        DebugLog.shared.write("Jabra \(identity.key) attached: \(name), serial \(identity.serial ?? "none"), management \(management != nil), profile \(profile.map { "\($0.id)" } ?? "none")")
        let uptime = ProcessInfo.processInfo.systemUptime
        let dongle = dongles[identity.key] ?? Dongle(
            key: identity.key,
            serial: identity.serial,
            attachedAt: uptime,
            remembersMute: defaults.string(forKey: Self.mutedKey) == identity.key
        )
        if dongles[identity.key] == nil {
            dongles[identity.key] = dongle
        } else {
            dongle.generation += 1
        }
        if dongle.profileID == nil { dongle.profileID = profile?.id }

        let context = Unmanaged.passUnretained(self).toOpaque()
        var needsReportCallback = management != nil

        if case let .element(page, usage, linkedValue)? = profile?.signal {
            let match = [
                kIOHIDElementUsagePageKey: page,
                kIOHIDElementUsageKey: usage,
            ]
            if let element = (
                IOHIDDeviceCopyMatchingElements(
                    device,
                    match as CFDictionary,
                    0
                ) as? [IOHIDElement]
            )?.first {
                interface.legacyElement = element
                if let linked = Self.readLinked(
                    device: device,
                    element: element,
                    linkedValue: linkedValue
                ) {
                    _ = dongle.legacy.seed(linked)
                }
            }
        }

        // One callback per device carries the link element and the
        // telephony controls.
        if interface.legacyElement != nil || interface.watchesTelephony {
            IOHIDDeviceRegisterInputValueCallback(device, Self.valueCallback, context)
        }

        if case let .report(reportID, byteIndex, bitMask)? = profile?.signal {
            needsReportCallback = true
            if let linked = Self.readReportLinked(
                device: device,
                reportID: reportID,
                byteIndex: byteIndex,
                bitMask: bitMask,
                bufferSize: 64
            ) {
                _ = dongle.legacy.seed(linked)
            }
        }

        if needsReportCallback {
            // A device supports only one input-report callback, so management
            // frames and legacy reports share it and are routed by report ID.
            let size = max(
                IOHIDDeviceGetProperty(
                    device,
                    kIOHIDMaxInputReportSizeKey as CFString
                ) as? Int ?? 64,
                (interface.management?.inputFrameLength ?? 0) + 1
            )
            interface.buffer = .allocate(capacity: size)
            interface.buffer?.initialize(repeating: 0, count: size)
            interface.bufferSize = size
            IOHIDDeviceRegisterInputReportCallback(
                device,
                interface.buffer!,
                size,
                Self.reportCallback,
                context
            )
        }

        dongle.interfaces[device] = interface
        interfaceKeys[device] = identity.key
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        updatePollTimer()
        // Start the query before publishing anything, so the first state the
        // model ever sees for this attachment is `.checking` rather than the
        // dongle's untrustworthy post-enumeration claim.
        requestQuery(dongle)
        refresh(dongle)
    }

    private func detach(_ device: IOHIDDevice) {
        guard let key = interfaceKeys.removeValue(forKey: device),
              let dongle = dongles[key],
              let interface = dongle.interfaces.removeValue(forKey: device) else {
            return
        }
        DebugLog.shared.write("Jabra \(key) detached an interface, \(dongle.interfaces.count) left")
        // Invalidate anything still referring to this dongle's membership.
        dongle.generation += 1
        dongle.query?.timeout?.cancel()
        dongle.query = nil
        tearDown(interface)
        if dongle.interfaces.isEmpty {
            dongle.pendingDown?.cancel()
            dongle.pendingDown = nil
            let wasKnown = dongle.resolved != nil
            dongles.removeValue(forKey: key)
            updatePollTimer()
            if wasKnown { notifyLinkChange() }
            return
        }
        updatePollTimer()
        refresh(dongle)
    }

    private func tearDown(_ interface: Interface) {
        if interface.legacyElement != nil || interface.watchesTelephony {
            IOHIDDeviceRegisterInputValueCallback(interface.device, nil, nil)
        }
        if let buffer = interface.buffer {
            IOHIDDeviceRegisterInputReportCallback(
                interface.device,
                buffer,
                interface.bufferSize,
                nil,
                nil
            )
        }
        IOHIDDeviceUnscheduleFromRunLoop(
            interface.device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceClose(interface.device, 0)
    }

    // MARK: - Resolution

    private static func state(of dongle: Dongle) -> LinkState {
        // A query is only pending before the first answer while the legacy bit
        // is still untrustworthy, so the model is told to wait rather than act.
        if dongle.awaitingFirstAnswer, dongle.query != nil { return .checking }
        guard let resolved = dongle.resolved else { return .unknown }
        return resolved ? .up : .down
    }

    /// Recomputes the dongle's reported value. Complete GNP evidence wins over
    /// the legacy bit; the two are never averaged or aggregated as peers.
    private func refresh(_ dongle: Dongle) {
        dongle.resolved = JabraGNP.resolve(
            vendor: dongle.vendor,
            legacy: dongle.legacy.effective
        )
        let state = Self.state(of: dongle)
        guard state != dongle.reported else { return }
        DebugLog.shared.write("Jabra \(dongle.key) link \(state), from pairing \(dongle.vendor.map { "\($0)" } ?? "unknown") and legacy \(dongle.legacy.effective.map { "\($0)" } ?? "unknown")")
        dongle.reported = state
        notifyLinkChange()
    }

    private func notifyLinkChange() {
        guard isRunning else { return }
        onLinkChange?()
    }

    private func observeLegacy(_ dongle: Dongle, linked: Bool) {
        let previous = dongle.legacy.observed
        defer {
            // A change in the raw bit means something really happened, which is
            // the cheapest moment to confirm it authoritatively.
            if linked != previous { requestQuery(dongle) }
        }
        // A positive claim right after enumeration is the dongle's known lie.
        // A negative claim is never spurious, so it is always accepted.
        if linked,
           ProcessInfo.processInfo.systemUptime - dongle.attachedAt
               < Self.enumerationSuppression {
            return
        }
        switch dongle.legacy.observe(linked) {
        case .unchanged:
            return
        case .changed:
            dongle.pendingDown?.cancel()
            dongle.pendingDown = nil
            refresh(dongle)
        case .cancelDown:
            dongle.pendingDown?.cancel()
            dongle.pendingDown = nil
        case .scheduleDown:
            scheduleLegacyDown(dongle)
        }
    }

    private func scheduleLegacyDown(_ dongle: Dongle) {
        dongle.pendingDown?.cancel()
        let key = dongle.key
        let generation = dongle.generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.isRunning,
                      let current = self.dongles[key],
                      current.generation == generation else { return }
                current.pendingDown = nil
                if current.legacy.commitDown() { self.refresh(current) }
            }
        }
        dongle.pendingDown = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.downDebounce,
            execute: work
        )
    }

    // MARK: - GNP transactions

    private func nextSequence() -> UInt8 {
        sequence &+= 1
        return sequence
    }

    /// Starts a walk unless one is already running for this dongle. Queries are
    /// serialized per dongle so replies can never be attributed to the wrong
    /// request.
    private func requestQuery(_ dongle: Dongle) {
        guard isRunning, dongle.query == nil,
              let interface = dongle.managementInterface else { return }
        let query = Query(generation: dongle.generation, interface: interface)
        dongle.query = query
        dongle.lastQueryAt = ProcessInfo.processInfo.systemUptime
        advance(dongle, query, step: query.walk.start())
    }

    private func advance(
        _ dongle: Dongle,
        _ query: Query,
        step: JabraGNP.PairingWalk.Step
    ) {
        switch step {
        case let .query(cursor, bluetoothType):
            send(dongle, query, cursor: cursor, bluetoothType: bluetoothType)
        case let .finished(evidence):
            finish(dongle, query, evidence: evidence)
        }
    }

    private func send(
        _ dongle: Dongle,
        _ query: Query,
        cursor: [UInt8],
        bluetoothType: UInt8
    ) {
        query.cursor = cursor
        query.bluetoothType = bluetoothType
        query.attempt = 0
        transmit(dongle, query)
    }

    private func transmit(_ dongle: Dongle, _ query: Query) {
        query.attempt += 1
        guard let layout = query.interface.management,
              let output = query.interface.managementOutput,
              let body = JabraGNP.encodeQuery(
                  sequence: nextSequence(),
                  group: JabraGNP.pairingGroup,
                  op: JabraGNP.recordOp,
                  arguments: JabraGNP.recordArguments(
                      cursor: query.cursor,
                      bluetoothType: query.bluetoothType
                  ),
                  frameLength: layout.outputFrameLength
              ),
              let value = IOHIDValueCreateWithBytes(
                  kCFAllocatorDefault,
                  output,
                  0,
                  body,
                  body.count
              ) else {
            finish(dongle, query, evidence: .inconclusive)
            return
        }
        // Record the awaited sequence and arm the timeout before writing, so a
        // fast reply cannot arrive against unprepared state.
        query.sequence = body[2]
        query.interface.reassembler.reset()
        armTimeout(dongle, query)
        guard IOHIDDeviceSetValue(query.interface.device, output, value)
                == kIOReturnSuccess else {
            finish(dongle, query, evidence: .inconclusive)
            return
        }
    }

    private func armTimeout(_ dongle: Dongle, _ query: Query) {
        query.timeout?.cancel()
        let key = dongle.key
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.isRunning,
                      let current = self.dongles[key],
                      current.generation == query.generation,
                      let pending = current.query,
                      pending === query else { return }
                pending.timeout = nil
                // A request the dongle dropped while still booting is not an
                // answer, so re-send it before concluding anything.
                guard pending.attempt >= Self.maximumAttempts else {
                    self.transmit(current, pending)
                    return
                }
                if case let .finished(evidence) = pending.walk.fail() {
                    self.finish(current, pending, evidence: evidence)
                }
            }
        }
        query.timeout = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.queryTimeout,
            execute: work
        )
    }

    private func finish(
        _ dongle: Dongle,
        _ query: Query,
        evidence: JabraGNP.Evidence
    ) {
        guard dongle.query === query else { return }
        query.timeout?.cancel()
        query.timeout = nil
        dongle.query = nil
        dongle.awaitingFirstAnswer = false
        // Incomplete evidence must not linger as authoritative, otherwise a
        // single failed cycle would freeze a stale verdict in place.
        let vendor: JabraGNP.Evidence? = evidence == .inconclusive ? nil : evidence
        if vendor != dongle.vendor {
            DebugLog.shared.write("Jabra \(dongle.key) pairing list: \(evidence)")
        }
        dongle.vendor = vendor
        refresh(dongle)
        if evidence == .connected {
            requestBattery(dongle)
            if dongle.session.shownControls == nil { run(dongle, .refresh) }
        } else if evidence == .disconnected {
            // The next headset to connect may not be this one.
            dongle.lastBatteryQueryAt = -.greatestFiniteMagnitude
            run(dongle, .disconnected)
            updateBattery(dongle, nil)
        }
        if dongle.requeryWhenIdle {
            dongle.requeryWhenIdle = false
            requestQuery(dongle)
        }
    }

    /// Asks the headset for its battery without waiting: the answer is picked
    /// up like an unasked update. A headset that just connected may not answer
    /// yet, so until it does every walk asks again.
    private func requestBattery(_ dongle: Dongle) {
        let now = ProcessInfo.processInfo.systemUptime
        guard dongle.battery == nil
                || now - dongle.lastBatteryQueryAt >= Self.batteryRefreshInterval,
              sendToHeadset(dongle, group: JabraGNP.statusGroup, op: JabraGNP.batteryOp)
        else { return }
        dongle.lastBatteryQueryAt = now
    }

    private func updateBattery(_ dongle: Dongle, _ level: Int?) {
        guard dongle.battery != level else { return }
        DebugLog.shared.write("Jabra \(dongle.key) battery \(level.map { "\($0)%" } ?? "unknown")")
        dongle.battery = level
        if isRunning { onHeadsetChange?() }
    }

    /// Sends one message to the headset without waiting: the dongle answers
    /// back-to-back messages in order.
    @discardableResult
    private func sendToHeadset(
        _ dongle: Dongle,
        kind: UInt8 = JabraGNP.queryKind,
        group: UInt8,
        op: UInt8,
        arguments: [UInt8] = []
    ) -> Bool {
        guard let interface = dongle.managementInterface,
              let layout = interface.management,
              let output = interface.managementOutput,
              let body = JabraGNP.encodeQuery(
                  destination: JabraGNP.headsetAddress,
                  sequence: nextSequence(),
                  kind: kind,
                  group: group,
                  op: op,
                  arguments: arguments,
                  frameLength: layout.outputFrameLength
              ),
              let value = IOHIDValueCreateWithBytes(
                  kCFAllocatorDefault,
                  output,
                  0,
                  body,
                  body.count
              ) else { return false }
        return IOHIDDeviceSetValue(interface.device, output, value) == kIOReturnSuccess
    }

    /// The dongle announced that a remembered device connected or
    /// disconnected. Ask it what the pairing database now says, since the
    /// announcement is a trigger rather than an answer.
    private func noteAnnouncedChange(_ dongle: Dongle) {
        guard dongle.query == nil else {
            dongle.requeryWhenIdle = true
            return
        }
        requestQuery(dongle)
    }

    private func handleReport(
        _ dongle: Dongle,
        _ interface: Interface,
        reportID: UInt8,
        bytes: [UInt8]
    ) {
        if let layout = interface.management, reportID == layout.inputReportID {
            // IOKit prefixes the buffer with the physical report ID; the
            // canonical GNP body starts after it.
            var chunk = bytes
            if chunk.first == reportID { chunk.removeFirst() }
            guard let body = interface.reassembler.feed(chunk),
                  let message = JabraGNP.decode(body) else { return }
            if JabraGNP.isConnectionEvent(message) {
                noteAnnouncedChange(dongle)
                return
            }
            if let level = JabraGNP.batteryLevel(message) {
                updateBattery(dongle, level)
                return
            }
            if message.source == JabraGNP.headsetAddress {
                run(dongle, .message(message))
                return
            }
            guard let query = dongle.query,
                  query.generation == dongle.generation,
                  JabraGNP.isReply(
                      message,
                      sequence: query.sequence,
                      group: JabraGNP.pairingGroup,
                      op: JabraGNP.recordOp
                  ) else { return }
            query.timeout?.cancel()
            query.timeout = nil
            advance(dongle, query, step: query.walk.accept(record: message.arguments))
            return
        }
        guard case let .report(expectedID, byteIndex, bitMask)?
                = interface.profile?.signal,
              let linked = JabraLink.decodeReport(
                  reportID: Int(reportID),
                  expectedID: expectedID,
                  bytes: bytes,
                  byteIndex: byteIndex,
                  bitMask: bitMask
              ) else { return }
        observeLegacy(dongle, linked: linked)
    }

    // MARK: - Polling

    private func updatePollTimer() {
        let needsPolling = dongles.values.contains { dongle in
            dongle.managementInterface != nil
                || dongle.interfaces.values.contains {
                    if case .report = $0.profile?.signal { return true }
                    return false
                }
        }
        guard needsPolling else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    private func poll() {
        guard isRunning else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        for dongle in Array(dongles.values) {
            for interface in dongle.interfaces.values {
                guard case let .report(reportID, byteIndex, bitMask)?
                        = interface.profile?.signal,
                      let linked = Self.readReportLinked(
                          device: interface.device,
                          reportID: reportID,
                          byteIndex: byteIndex,
                          bitMask: bitMask,
                          bufferSize: interface.bufferSize
                      ) else { continue }
                observeLegacy(dongle, linked: linked)
            }
            if uptime - dongle.lastQueryAt >= Self.vendorRefreshInterval {
                requestQuery(dongle)
            }
        }
    }

    // MARK: - Device inspection

    private static func identity(
        of device: IOHIDDevice
    ) -> (key: String, serial: String?) {
        if let serial = IOHIDDeviceGetProperty(
            device,
            kIOHIDSerialNumberKey as CFString
        ) as? String, !serial.isEmpty {
            return ("serial:\(serial.lowercased())", serial)
        }
        // Without a serial, fall back to the USB position. Two dongles still
        // stay distinct, they just cannot be matched by UID.
        let productID = IOHIDDeviceGetProperty(
            device,
            kIOHIDProductIDKey as CFString
        ) as? Int ?? -1
        let location = IOHIDDeviceGetProperty(
            device,
            kIOHIDLocationIDKey as CFString
        ) as? Int ?? -1
        return ("product:\(productID)/location:\(location)", nil)
    }

    /// A telephony control. The Mute light confirms a mute the headset
    /// asked for with its Phone Mute button.
    private static func telephonyElement(
        _ device: IOHIDDevice,
        _ page: Int,
        _ usage: Int,
        output: Bool
    ) -> IOHIDElement? {
        let match: [String: Any] = [
            kIOHIDElementUsagePageKey: page,
            kIOHIDElementUsageKey: usage,
        ]
        return (IOHIDDeviceCopyMatchingElements(device, match as CFDictionary, 0) as? [IOHIDElement])?
            .first { (IOHIDElementGetType($0) == kIOHIDElementTypeOutput) == output }
    }

    private static func managementLayout(
        _ device: IOHIDDevice
    ) -> (layout: JabraGNP.Layout, output: IOHIDElement)? {
        let match: [String: Any] = [
            kIOHIDElementUsagePageKey: JabraGNP.usagePage,
            kIOHIDElementUsageKey: JabraGNP.usage,
        ]
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            match as CFDictionary,
            0
        ) as? [IOHIDElement] else { return nil }

        var descriptors: [JabraGNP.Element] = []
        var outputs: [(element: IOHIDElement, reportID: UInt8, bytes: Int)] = []
        for element in elements {
            // IOKit reports an element's full width in reportSize, while
            // reportCount is the item count, so the two must not be multiplied.
            let bits = Int(IOHIDElementGetReportSize(element))
            let reportID = UInt8(truncatingIfNeeded: IOHIDElementGetReportID(element))
            switch IOHIDElementGetType(element) {
            case kIOHIDElementTypeOutput:
                descriptors.append(
                    .init(direction: .output, reportID: reportID, bits: bits)
                )
                outputs.append((element, reportID, bits / 8))
            case kIOHIDElementTypeFeature, kIOHIDElementTypeCollection:
                continue
            default:
                descriptors.append(
                    .init(direction: .input, reportID: reportID, bits: bits)
                )
            }
        }
        guard let layout = JabraGNP.selectLayout(descriptors),
              let output = outputs.first(where: {
                  $0.reportID == layout.outputReportID
                      && $0.bytes == layout.outputFrameLength
              }) else { return nil }
        return (layout, output.element)
    }

    private static func integerValue(_ device: IOHIDDevice, _ element: IOHIDElement) -> Int? {
        var value: Unmanaged<IOHIDValue>?
        let status = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: Unmanaged<IOHIDValue>.self, capacity: 1) {
                IOHIDDeviceGetValue(device, element, $0)
            }
        }
        guard status == kIOReturnSuccess, let value = value?.takeUnretainedValue() else { return nil }
        return IOHIDValueGetIntegerValue(value)
    }

    private static func readLinked(
        device: IOHIDDevice,
        element: IOHIDElement,
        linkedValue: Int
    ) -> Bool? {
        var value: Unmanaged<IOHIDValue>?
        let status = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(
                to: Unmanaged<IOHIDValue>.self,
                capacity: 1
            ) {
                IOHIDDeviceGetValue(device, element, $0)
            }
        }
        guard status == kIOReturnSuccess,
              let value = value?.takeUnretainedValue() else {
            return nil
        }
        return JabraLink.snapshot(
            value: IOHIDValueGetIntegerValue(value),
            timestamp: IOHIDValueGetTimeStamp(value),
            linkedValue: linkedValue
        )
    }

    private static func readReportLinked(
        device: IOHIDDevice,
        reportID: Int,
        byteIndex: Int,
        bitMask: UInt8,
        bufferSize: Int
    ) -> Bool? {
        var bytes = [UInt8](
            repeating: 0,
            count: max(bufferSize, byteIndex + 1)
        )
        var length = CFIndex(bytes.count)
        let status = bytes.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeInput,
                CFIndex(reportID),
                $0.baseAddress!,
                &length
            )
        }
        guard status == kIOReturnSuccess,
              length > byteIndex else {
            return nil
        }
        // IOHIDDeviceGetReport already selects reportID. Upstream Link 390
        // hardware research indexes the returned payload directly.
        return bytes[byteIndex] & bitMask != 0
    }

    // MARK: - Callback plumbing

    nonisolated private static func address(of device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    nonisolated private static func onMain(
        context: UnsafeMutableRawPointer?,
        deviceAddress: UInt,
        _ body: @MainActor @Sendable (JabraHIDMonitor, IOHIDDevice) -> Void
    ) {
        guard let context else { return }
        let monitorAddress = UInt(bitPattern: context)
        MainActor.assumeIsolated {
            guard let monitorPointer = UnsafeRawPointer(bitPattern: monitorAddress),
                  let devicePointer = UnsafeRawPointer(bitPattern: deviceAddress)
            else { return }
            let monitor = Unmanaged<JabraHIDMonitor>
                .fromOpaque(monitorPointer).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>
                .fromOpaque(devicePointer).takeUnretainedValue()
            guard monitor.isRunning else { return }
            body(monitor, device)
        }
    }

    /// Resolves a device back to the dongle that currently owns it, so work
    /// arriving after a detach or replug is dropped.
    private func current(_ device: IOHIDDevice) -> (Dongle, Interface)? {
        guard let key = interfaceKeys[device],
              let dongle = dongles[key],
              let interface = dongle.interfaces[device] else { return nil }
        return (dongle, interface)
    }

    nonisolated private static let matchCallback: IOHIDDeviceCallback = {
        context, _, _, device in
        onMain(context: context, deviceAddress: address(of: device)) {
            $0.attach($1)
        }
    }

    nonisolated private static let removalCallback: IOHIDDeviceCallback = {
        context, _, _, device in
        onMain(context: context, deviceAddress: address(of: device)) {
            $0.detach($1)
        }
    }

    nonisolated private static let valueCallback: IOHIDValueCallback = {
        context, _, _, value in
        let element = IOHIDValueGetElement(value)
        let deviceAddress = address(of: IOHIDElementGetDevice(element))
        let cookie = IOHIDElementGetCookie(element)
        let integer = IOHIDValueGetIntegerValue(value)
        onMain(context: context, deviceAddress: deviceAddress) {
            monitor, device in
            guard let (dongle, interface) = monitor.current(device) else { return }
            if let phoneMute = interface.phoneMute, IOHIDElementGetCookie(phoneMute) == cookie {
                if integer == 1 { monitor.run(dongle, .muteRequest) }
                return
            }
            let signals: [(KeyPath<Interface, IOHIDElement?>, HeadsetSession.Signal)] = [
                (\.hookSwitch, .standardHook), (\.jabraHookSwitch, .jabraHook),
                (\.line, .standardLine), (\.jabraLine, .jabraLine),
            ]
            for (element, signal) in signals {
                if let element = interface[keyPath: element], IOHIDElementGetCookie(element) == cookie {
                    monitor.run(dongle, .signal(signal, integer != 0))
                    return
                }
            }
            guard let expected = interface.legacyElement,
                  IOHIDElementGetCookie(expected) == cookie,
                  case let .element(_, _, linkedValue)? = interface.profile?.signal
            else { return }
            monitor.observeLegacy(
                dongle,
                linked: JabraLink.decodeElement(
                    value: integer,
                    linkedValue: linkedValue
                )
            )
        }
    }

    nonisolated private static let reportCallback: IOHIDReportCallback = {
        context, _, sender, _, reportID, report, length in
        guard let sender, length > 0 else { return }
        let deviceAddress = UInt(bitPattern: sender)
        // GNP needs the whole frame, so the buffer is never truncated here.
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        onMain(context: context, deviceAddress: deviceAddress) {
            monitor, device in
            guard let (dongle, interface) = monitor.current(device) else { return }
            monitor.handleReport(
                dongle,
                interface,
                reportID: UInt8(truncatingIfNeeded: reportID),
                bytes: bytes
            )
        }
    }
}
