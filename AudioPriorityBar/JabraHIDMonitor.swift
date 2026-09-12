import AudioPriorityCore
import Foundation
import IOKit.hid

@MainActor
final class JabraHIDMonitor {
    private final class DeviceState {
        let device: IOHIDDevice
        let profile: JabraProfile
        var element: IOHIDElement?
        var reportBuffer: UnsafeMutablePointer<UInt8>?
        var reportBufferSize = 0
        var link = DebouncedLinkState()
        var pendingDown: DispatchWorkItem?

        init(device: IOHIDDevice, profile: JabraProfile) {
            self.device = device
            self.profile = profile
        }

        deinit {
            pendingDown?.cancel()
            reportBuffer?.deallocate()
        }
    }

    var onLinkChange: (() -> Void)?

    private var manager: IOHIDManager?
    private var pollTimer: Timer?
    private var devices: [IOHIDDevice: DeviceState] = [:]
    private static let downDebounce: TimeInterval = 3
    private static let pollInterval: TimeInterval = 2
    nonisolated private static let reportBytesNeeded =
        JabraLink.profiles.compactMap {
            guard case let .report(_, byteIndex, _) = $0.signal else { return nil }
            return byteIndex + 1
        }.max() ?? 0

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
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
            self.manager = nil
            return
        }
        if let matched = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in matched { attach(device) }
        }
    }

    func stop() {
        guard let manager else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        for state in Array(devices.values) {
            devices.removeValue(forKey: state.device)
            tearDown(state)
        }
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

    func linkState(for name: String) -> LinkState {
        guard let profile = JabraLink.profile(matching: name) else {
            return .unknown
        }
        let states = devices.values
            .filter { $0.profile.id == profile.id }
            .map(\.link.effective)
        return states.isEmpty
            ? .monitoringUnavailable
            : JabraLink.aggregate(states)
    }

    func isUsable(_ name: String) -> Bool {
        let supported = JabraLink.profile(matching: name) != nil
        return JabraLink.allowsSelection(
            isSupported: supported,
            state: linkState(for: name)
        )
    }

    func monitoredState(for name: String) -> LinkState? {
        guard JabraLink.profile(matching: name) != nil else { return nil }
        return linkState(for: name)
    }

    private func attach(_ device: IOHIDDevice) {
        guard devices[device] == nil,
              let profile = profile(for: device),
              IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else {
            return
        }
        let state = DeviceState(device: device, profile: profile)
        let context = Unmanaged.passUnretained(self).toOpaque()

        switch profile.signal {
        case let .element(page, usage, linkedValue):
            let match = [
                kIOHIDElementUsagePageKey: page,
                kIOHIDElementUsageKey: usage,
            ]
            guard let element = (
                IOHIDDeviceCopyMatchingElements(
                    device,
                    match as CFDictionary,
                    0
                ) as? [IOHIDElement]
            )?.first else {
                IOHIDDeviceClose(device, 0)
                return
            }
            state.element = element
            IOHIDDeviceRegisterInputValueCallback(
                device,
                Self.valueCallback,
                context
            )
            if let linked = Self.readLinked(
                device: device,
                element: element,
                linkedValue: linkedValue
            ) {
                _ = state.link.seed(linked)
            }

        case let .report(reportID, byteIndex, bitMask):
            let size = max(
                IOHIDDeviceGetProperty(
                    device,
                    kIOHIDMaxInputReportSizeKey as CFString
                ) as? Int ?? 64,
                2
            )
            state.reportBuffer = .allocate(capacity: size)
            state.reportBuffer?.initialize(repeating: 0, count: size)
            state.reportBufferSize = size
            IOHIDDeviceRegisterInputReportCallback(
                device,
                state.reportBuffer!,
                size,
                Self.reportCallback,
                context
            )
            if let linked = Self.readReportLinked(
                device: device,
                reportID: reportID,
                byteIndex: byteIndex,
                bitMask: bitMask,
                bufferSize: size
            ) {
                _ = state.link.seed(linked)
            }
        }

        devices[device] = state
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        updatePollTimer()
        if state.link.effective != nil { onLinkChange?() }
    }

    private func detach(_ device: IOHIDDevice) {
        guard let state = devices.removeValue(forKey: device) else { return }
        let wasKnown = state.link.effective != nil
        tearDown(state)
        updatePollTimer()
        if wasKnown { onLinkChange?() }
    }

    private func tearDown(_ state: DeviceState) {
        state.pendingDown?.cancel()
        state.pendingDown = nil
        switch state.profile.signal {
        case .element:
            IOHIDDeviceRegisterInputValueCallback(state.device, nil, nil)
        case .report:
            if let buffer = state.reportBuffer {
                IOHIDDeviceRegisterInputReportCallback(
                    state.device,
                    buffer,
                    state.reportBufferSize,
                    nil,
                    nil
                )
            }
        }
        IOHIDDeviceUnscheduleFromRunLoop(
            state.device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceClose(state.device, 0)
    }

    private func update(_ state: DeviceState, linked: Bool) {
        switch state.link.observe(linked) {
        case .unchanged:
            return
        case .changed:
            state.pendingDown?.cancel()
            state.pendingDown = nil
            onLinkChange?()
        case .cancelDown:
            state.pendingDown?.cancel()
            state.pendingDown = nil
        case .scheduleDown:
            state.pendingDown?.cancel()
            let deviceAddress = Self.address(of: state.device)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let current = self.devices.values.first(where: {
                              Self.address(of: $0.device) == deviceAddress
                          }) else {
                        return
                    }
                    current.pendingDown = nil
                    if current.link.commitDown() { self.onLinkChange?() }
                }
            }
            state.pendingDown = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.downDebounce,
                execute: work
            )
        }
    }

    private func updatePollTimer() {
        let needsPolling = devices.values.contains {
            if case .report = $0.profile.signal { return true }
            return false
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
                self?.pollReports()
            }
        }
    }

    private func pollReports() {
        for state in Array(devices.values) {
            guard case let .report(reportID, byteIndex, bitMask)
                    = state.profile.signal,
                  let linked = Self.readReportLinked(
                    device: state.device,
                    reportID: reportID,
                    byteIndex: byteIndex,
                    bitMask: bitMask,
                    bufferSize: state.reportBufferSize
                  ) else {
                continue
            }
            update(state, linked: linked)
        }
    }

    private func profile(for device: IOHIDDevice) -> JabraProfile? {
        guard let name = IOHIDDeviceGetProperty(
            device,
            kIOHIDProductKey as CFString
        ) as? String else {
            return nil
        }
        return JabraLink.profile(matching: name)
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
            body(monitor, device)
        }
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
            guard let state = monitor.devices[device],
                  let expected = state.element,
                  IOHIDElementGetCookie(expected) == cookie,
                  case let .element(_, _, linkedValue) = state.profile.signal
            else {
                return
            }
            monitor.update(
                state,
                linked: JabraLink.decodeElement(
                    value: integer,
                    linkedValue: linkedValue
                )
            )
        }
    }

    nonisolated private static let reportCallback: IOHIDReportCallback = {
        context, _, sender, _, reportID, report, length in
        guard let sender else { return }
        let deviceAddress = UInt(bitPattern: sender)
        let bytes = Array(UnsafeBufferPointer(
            start: report,
            count: min(length, reportBytesNeeded)
        ))
        onMain(context: context, deviceAddress: deviceAddress) {
            monitor, device in
            guard let state = monitor.devices[device],
                  case let .report(expectedID, byteIndex, bitMask)
                    = state.profile.signal,
                  let linked = JabraLink.decodeReport(
                    reportID: Int(reportID),
                    expectedID: expectedID,
                    bytes: bytes,
                    byteIndex: byteIndex,
                    bitMask: bitMask
                  ) else {
                return
            }
            monitor.update(state, linked: linked)
        }
    }
}
