import AudioPriorityCore
import AppKit
import SwiftUI

struct DeviceRow: View {
    private struct Status {
        let icon: String, text: String
        /// Carried with the value so restyling never depends on matching copy.
        var tint: Color = .secondary
        /// Read aloud and shown on hover instead of `text` when the glyph
        /// carries meaning the text alone does not.
        var spokenText: String?
        /// Drawn as the glyph alone where room is short; the text stays in
        /// the tooltip and the spoken value.
        var isIconOnly = false
        var description: String { spokenText ?? text }
    }

    @Bindable var model: AppModel
    let device: AudioDevice
    let index: Int
    let count: Int
    let isSelected: Bool
    let category: OutputCategory?
    let isLifted: Bool
    let select: () -> Void
    let move: (Int) -> Void
    /// Set to a device's `id` while the selection override on its paired
    /// device's row is hovered, so this row can mirror that highlight.
    @Binding var highlightedPairedDeviceID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isHovering = false
    @State private var isHoveringSelectionOverride = false
    @State private var highlightedPartnerID: String?
    @State private var frameInWindow: CGRect = .zero
    @State private var isExplainingCall = false
    @FocusState private var isOverrideFocused: Bool
    @FocusState private var isBluetoothFocused: Bool

    private var linkState: LinkState? { model.linkState(for: device) }
    private var isUnavailable: Bool { linkState == .down }
    private var isHidden: Bool { model.isHidden(device) }
    private var isNeverUse: Bool { model.isNeverUse(device) }
    private var pairedDevice: AudioDevice? { model.pairedDevice(for: device) }
    private var selectsHalvesTogether: Bool { model.selectsHalvesTogether(device) }

    /// Whether this device and its pair are both currently selected, so
    /// selecting them together has nothing left to do.
    private var areBothDevicesSelected: Bool {
        guard let pairedDevice else { return false }
        let pairedIsCurrent = pairedDevice.role == .input
            ? model.currentInputID == pairedDevice.platformID
            : model.currentOutputID == pairedDevice.platformID
        return isSelected && pairedIsCurrent
    }

    /// Whether the paired device is connected and not link-down, so
    /// selecting it could actually take effect.
    private var isPairedDeviceUsable: Bool {
        guard let pairedDevice else { return false }
        return device.isConnected
            && !isUnavailable
            && model.linkState(for: pairedDevice) != .down
    }

    private var canSelectBothDevices: Bool {
        isPairedDeviceUsable && !areBothDevicesSelected
    }

    private var selectionOverrideHelp: String {
        if selectsHalvesTogether {
            return device.role == .input
                ? "Select only this microphone, not its output"
                : "Select only this output, not its microphone"
        }
        return "Use \(device.name) for input and output"
    }

    /// Whether this row should show a highlight because the selection
    /// override on its paired device's row is currently hovered.
    private var isHighlightedPairedDevice: Bool {
        highlightedPairedDeviceID == device.id
    }
    private var statuses: [Status] {
        var result: [Status] = []
        if model.isConnecting(device) {
            result.append(Status(icon: "dot.radiowaves.left.and.right", text: "Connecting…"))
        } else if !device.isConnected {
            let seen = model.store.storedDevice(
                uid: device.uid,
                role: device.role
            )?.relativeLastSeen()
            // The dimmed row and the glyph already say disconnected, so the
            // text keeps to when, which fits beside a long name.
            result.append(Status(
                icon: "wifi.slash",
                text: seen.map { "Last seen \($0)" } ?? "Disconnected",
                spokenText: seen.map { "Disconnected, last seen \($0)" }
            ))
        } else if device.isBluetooth, !model.isInUse(device) {
            result.append(Status(icon: "dot.radiowaves.left.and.right", text: "Connected"))
        }
        // The antenna-slash glyph means a proven verdict, so it belongs to
        // `.down` alone: that state dims the row and blocks selection, while
        // the states below leave the device selectable. `.checking` shows
        // nothing at all because it settles in tens of milliseconds and would
        // only flicker; automatic selection still waits for it internally.
        if linkState == .down {
            result.append(Status(
                icon: "antenna.radiowaves.left.and.right.slash",
                text: "Headset off",
                tint: .orange
            ))
        } else if linkState == .unknown {
            result.append(Status(
                icon: "questionmark.circle",
                text: "Link unknown"
            ))
        } else if linkState == .monitoringUnavailable {
            result.append(Status(
                icon: "questionmark.circle",
                text: "Link status unavailable"
            ))
        }
        if isHidden {
            result.append(Status(icon: "eye.slash", text: "Hidden"))
        }
        if isNeverUse {
            result.append(Status(icon: "nosign", text: "Never auto-select"))
        }
        if model.isMuted(device) {
            result.append(Status(
                icon: device.role == .input ? "mic.slash" : "speaker.slash",
                text: "Muted",
                tint: .red
            ))
        }
        // Glyphs alone, since the headset's buttons share this one line.
        if let controls = model.headsetControls(for: device) {
            if controls.isMicMuted {
                result.append(Status(
                    icon: "mic.slash",
                    text: "Muted",
                    tint: .red,
                    spokenText: controls.isCalling
                        ? "In call, microphone muted on the headset"
                        : controls.isLineOpen == true
                            ? "Microphone in use, muted on the headset"
                            : "Busy, microphone muted on the headset",
                    isIconOnly: true
                ))
            }
        }
        result.append(contentsOf: batteryStatuses)
        return result
    }

    private var batteryStatuses: [Status] {
        (model.batteryLevels(for: device)?.badges ?? []).map {
            Status(
                icon: $0.icon,
                text: $0.text,
                tint: $0.isLow ? .orange : .secondary,
                spokenText: $0.spokenText
            )
        }
    }

    var body: some View {
        let details = statuses
        HStack(spacing: 8) {
            ZStack {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .opacity(showsDragHandle ? 0 : 1)
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .opacity(showsDragHandle ? 1 : 0)
            }
            .foregroundStyle(.secondary)
            .frame(minWidth: 16)
            .help("Priority \(index + 1) of \(count). Drag to reorder.")
            .accessibilityHidden(true)

            Image(systemName: device.hardwareIcon(category: category))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? selectionTint : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(device.name)
                if !details.isEmpty {
                    statusLine(details)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(selectionTint)
                    .help(device.role == .input ? "Current microphone" : "Current sound output")
                    .accessibilityHidden(true)
            }
            rowControls
        }
        .padding(.horizontal, 8)
        .frame(height: DeviceRowMetrics.height)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isLifted ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(rowBackground))
        }
        .overlay {
            if model.keyboardItem == .device(device.id) {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(isLifted && !reduceMotion ? 1.02 : 1)
        .shadow(
            color: .black.opacity(isLifted ? 0.28 : 0),
            radius: isLifted ? 10 : 0,
            y: isLifted ? 5 : 0
        )
        .onHover { hovering in
            isHovering = hovering
            if !hovering {
                if highlightedPairedDeviceID == highlightedPartnerID {
                    highlightedPairedDeviceID = nil
                }
                highlightedPartnerID = nil
                // The override cannot still be hovered once the pointer has
                // left the row, and it reports nothing when selecting a
                // device stops it being rendered at all.
                isHoveringSelectionOverride = false
                return
            }
            guard selectsHalvesTogether, isPairedDeviceUsable, !isSelected,
                  !isHoveringSelectionOverride, let pairedDevice else { return }
            highlightedPartnerID = pairedDevice.id
            highlightedPairedDeviceID = pairedDevice.id
        }
        .contentShape(Rectangle())
        .onTapGesture { activate() }
        .contextMenu { actionItems }
        // Undo the content inset for layout, so the row's text lines up with
        // the section heading while its highlight and hover area overhang it.
        .padding(.horizontal, -8)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            frameInWindow = $0
        }
        .onChange(of: model.actionsMenuDeviceID) { _, id in
            guard id == device.id else { return }
            model.actionsMenuDeviceID = nil
            openActionsMenu()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(device.name)
        .accessibilityValue(accessibilityValue(details))
        .accessibilityHint(accessibilityHint)
        .accessibilityAction { activate() }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            if index > 0 {
                Button("Move Up") { move(index - 1) }
            }
            if index < count - 1 {
                Button("Move Down") { move(index + 1) }
            }
        }
    }

    private func statusLine(_ details: [Status]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                HStack(spacing: 3) {
                    Image(systemName: detail.icon)
                    if !detail.isIconOnly {
                        Text(detail.text).lineLimit(1)
                    }
                }
                .foregroundStyle(detail.tint)
            }
        }
        .font(.caption.monospacedDigit())
        .help(details.map(\.description).joined(separator: " · "))
        .accessibilityHidden(true)
    }

    /// SwiftUI has no way to open a context menu, so the keyboard asks the
    /// panel for the one a right-click on the row's name would show. It opens
    /// a turn later, since a menu opened during a view update never draws.
    private func openActionsMenu() {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return }
        let location = NSPoint(
            x: frameInWindow.minX + 48,
            y: content.bounds.height - frameInWindow.midY
        )
        guard let click = NSEvent.mouseEvent(
                  with: .rightMouseDown,
                  location: location,
                  modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  eventNumber: 0,
                  clickCount: 1,
                  pressure: 1
              ),
              let menu = content.menu(for: click) else { return }
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: content.convert(location, from: nil), in: content)
        }
    }

    /// An AppKit sheet on the panel: SwiftUI's dialog takes key status from
    /// the panel before attaching to it, so the panel closes and takes the
    /// dialog with it. Return forgets and Escape cancels.
    private func confirmForget() {
        guard let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(device.name)?"
        alert.informativeText = "Its saved priority, category, and visibility will be removed."
        alert.addButton(withTitle: "Forget Device")
        alert.addButton(withTitle: "Cancel")
        DebugLog.shared.write("clicked Forget on \(device.logName)")
        alert.beginSheetModal(for: window) { [model, device] response in
            if response == .alertFirstButtonReturn {
                model.forget(device)
            } else {
                DebugLog.shared.write("cancelled forgetting \(device.logName)")
            }
        }
    }

    private var accessibilityHint: String {
        if !device.isConnected {
            return model.canConnect(device)
                ? "Activate to connect and use this device"
                : "Use the actions menu to manage this device"
        }
        if isUnavailable { return "This device is unavailable" }
        if isSelected { return "Current device" }
        return device.role == .input ? "Use as the microphone" : "Use for sound output"
    }

    private func activate() { model.activate(device) }

    /// The warning on a link-down device also applies to its current-route mark.
    private var selectionTint: Color {
        isUnavailable ? .orange : .accentColor
    }

    private var showsDragHandle: Bool { isHovering || isLifted }

    private var showsQuickActions: Bool {
        isHovering || voiceOverEnabled || isOverrideFocused || isBluetoothFocused
            || model.keyboardItem == .device(device.id)
    }

    private var nameColor: Color {
        !device.isConnected || isUnavailable ? .secondary : .primary
    }

    private var rowBackground: Color {
        if isSelected {
            return selectionTint.opacity(isHovering || isHighlightedPairedDevice ? 0.15 : 0.09)
        }
        return isHovering || isHighlightedPairedDevice ? Color.primary.opacity(0.07) : .clear
    }

    /// The override for the current default: offers to select only this
    /// device while both are normally selected together, or to select both
    /// while only one is. Shown only while it would change something, so a
    /// row whose pair is already in the target state, unavailable, or absent
    /// keeps the layout it had before.
    @ViewBuilder
    private var selectionOverride: some View {
        if let option = selectionOverrideOption, let pairedDevice {
            selectionOverridePill(partner: pairedDevice, label: option.pill, action: option.action)
        }
    }

    /// The override while it would change something, with the pill's label
    /// and the actions menu's title, so the keyboard reaches it too.
    private var selectionOverrideOption: (pill: String, title: String, action: () -> Void)? {
        guard isPairedDeviceUsable else { return nil }
        if selectsHalvesTogether {
            guard !isSelected else { return nil }
            return device.role == .input
                ? ("Mic only", "Use Microphone Only", { model.selectOnly(device) })
                : ("Output only", "Use Output Only", { model.selectOnly(device) })
        }
        guard canSelectBothDevices else { return nil }
        return ("Use both", "Use for Input and Output", { model.selectWithPairedDevice(device) })
    }

    /// Keep the actions menu visible. Pairing shortcuts appear on interaction,
    /// and real headset controls stay available alongside their device.
    private var rowControls: some View {
        HStack(spacing: 4) {
            if let headset = model.headsetControls(for: device) {
                headsetButtons(headset)
            } else if showsQuickActions {
                connectControl
                selectionOverride
            }
            actions
        }
        .fixedSize()
    }

    @ViewBuilder
    private var connectControl: some View {
        if model.canConnect(device) {
            if !model.isConnecting(device) {
                bluetoothPill("Connect") { model.connect(device) }
            }
        } else if model.canDisconnect(device), !model.isInUse(device) {
            bluetoothPill("Disconnect") { model.disconnect(device) }
        }
    }

    private func bluetoothPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .controlSize(.small)
            .help("\(title) \(device.name) over Bluetooth")
            .accessibilityLabel("\(title) \(device.name)")
            .focused($isBluetoothFocused)
    }

    private func selectionOverridePill(
        partner: AudioDevice,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(label, action: action)
            .controlSize(.small)
            .help(selectionOverrideHelp)
            .accessibilityLabel(selectionOverrideHelp)
            .focused($isOverrideFocused)
            .onHover { hovering in
                isHoveringSelectionOverride = hovering
                if selectsHalvesTogether {
                    // This override selects only the hovered device, so
                    // suppress the partner highlight while hovering it, and
                    // restore it when returning to the row, which still selects
                    // both.
                    if hovering {
                        if highlightedPairedDeviceID == partner.id {
                            highlightedPairedDeviceID = nil
                        }
                    } else if isHovering, !isSelected {
                        highlightedPartnerID = partner.id
                        highlightedPairedDeviceID = partner.id
                    }
                } else if hovering {
                    // "Use both" is the only control that selects the partner
                    // while selecting one device at a time is the default.
                    highlightedPairedDeviceID = partner.id
                } else if highlightedPairedDeviceID == partner.id {
                    highlightedPairedDeviceID = nil
                }
            }
    }

    /// Settings the headset keeps itself: noise control, sidetone and the
    /// busylight, each a round button of its own.
    private func headsetButtons(_ controls: JabraGNP.HeadsetControls) -> some View {
        HStack(spacing: 4) {
            if controls.noiseMode != nil {
                noiseControlMenu(controls)
            }
            if let sidetone = controls.sidetone {
                Button { model.setSidetone(!sidetone.isOn, for: device) } label: {
                    HeadsetGlyph(
                        symbol: "person.wave.2",
                        isOn: sidetone.isOn,
                        tint: .accentColor,
                        isDimmed: controls.isSidetoneSilenced
                    )
                }
                .buttonStyle(.plain)
                .help(controls.isSidetoneSilenced
                    ? "Sidetone, silent while the microphone is muted"
                    : "Sidetone: hear your own voice during calls")
                .accessibilityLabel("Sidetone")
                .accessibilityValue(sidetone.isOn ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
            }
            if controls.isHeadsetCall {
                // A call the call button started ends from here, light and
                // all. Clearing only the light would see the button's next
                // press switch it on again.
                Button { model.endHeadsetCall(for: device) } label: {
                    HeadsetGlyph(symbol: "phone.down.fill", isOn: true, tint: .red)
                }
                .buttonStyle(.plain)
                .help("End the call started with the headset's call button")
                .accessibilityLabel("End call")
            } else if controls.isInCall == true {
                // An app's call holds the busylight until it ends, and only
                // that app can end it.
                Button { isExplainingCall.toggle() } label: {
                    HeadsetGlyph(symbol: "phone.fill", isOn: true, tint: .red)
                }
                .buttonStyle(.plain)
                .help("In a call")
                .popover(isPresented: $isExplainingCall, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("In a call").font(.headline)
                        Text("The headset keeps the busylight on until the call ends, so it can't be turned off from here.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(width: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                }
                .onDisappear { isExplainingCall = false }
                .accessibilityLabel("In call")
                .accessibilityValue("Busylight on until the call ends")
            } else if let isBusy = controls.isBusy {
                let isDark = controls.isBusylightDark
                Button { model.setBusy(!isBusy, for: device) } label: {
                    HeadsetGlyph(symbol: "light.beacon.max", isOn: isBusy, tint: .red, isDimmed: isDark)
                }
                .buttonStyle(.plain)
                .help(isDark
                    ? "Busylight on. On-ear detection keeps it dark until you put the headset on."
                    : "Busylight: show you're busy")
                .accessibilityLabel("Busylight")
                .accessibilityValue(isDark ? "On, dark until you put the headset on" : isBusy ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
            }
        }
    }

    /// The menu shows and changes what is heard now: the check follows the
    /// noise control playing, and a mode the call stops is greyed out, so a
    /// greyed-out mode is never the checked one.
    private func noiseControlMenu(_ controls: JabraGNP.HeadsetControls) -> some View {
        Menu {
            if controls.playsCallAudio {
                let reason = controls.isCalling ? "during calls" : "while an app uses the microphone"
                Text(controls.sidetone?.isOn == true
                    ? "Sidetone replaces noise control \(reason)"
                    : "HearThrough isn't available \(reason)")
                if controls.isHeadsetCall {
                    Text("End this call with the red button or the headset's call button")
                }
                if controls.isSidetoneSilenced {
                    Text("Sidetone is silent while the microphone is muted")
                }
                if let before = controls.modeBeforeCall, before != controls.audibleNoiseMode {
                    Text("\(before.title) returns after the call")
                }
            }
            if let audible = controls.audibleNoiseMode {
                Section("Noise control") {
                    ForEach(JabraGNP.NoiseMode.allCases, id: \.self) { mode in
                        Toggle(isOn: Binding(
                            get: { mode == audible },
                            set: { if $0 { model.setNoiseMode(mode, for: device) } }
                        )) {
                            Label(mode.title, systemImage: mode.symbol)
                        }
                        .disabled(!controls.isAvailable(mode))
                    }
                }
            }
        } label: {
            HeadsetGlyph(symbol: (controls.audibleNoiseMode ?? .off).symbol)
        }
        // A borderless menu draws its label its own way, ignoring the glyph's
        // round background.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(controls.audibleNoiseMode.map {
            let reason = controls.isCalling ? " during the call" : " while an app uses the microphone"
            return "Noise control: \($0.title)" + ($0 != controls.noiseMode ? reason : "")
        } ?? "Noise control")
        .accessibilityLabel("Noise control")
        .accessibilityValue(controls.audibleNoiseMode?.title ?? "")
    }

    private var actions: some View {
        Menu {
            actionItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Actions for \(device.name)")
        .accessibilityLabel("Actions for \(device.name)")
    }

    @ViewBuilder
    private var actionItems: some View {
        if device.isConnected {
            Button(action: select) {
                Label(
                    activationTitle,
                    systemImage: "checkmark.circle"
                )
            }
                .disabled(isSelected || isUnavailable)
            if let option = selectionOverrideOption {
                Button(action: option.action) {
                    Label(option.title, systemImage: "rectangle.2.swap")
                }
            }
            if model.selectsPairedDevice, pairedDevice != nil {
                Toggle(
                    device.role == .output ? "Use Its Microphone Too" : "Use With Its Output",
                    isOn: Binding(
                        get: { selectsHalvesTogether },
                        set: { model.setSelectsHalvesTogether(device, $0) }
                    )
                )
            }
            Divider()
        } else if model.canConnect(device) {
            Button { model.connect(device) } label: {
                Label("Connect", systemImage: "link")
            }
            .disabled(model.isConnecting(device))
            Divider()
        }

        Button {
            move(index - 1)
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(index == 0)
        Button {
            move(index + 1)
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(index == count - 1)

        if device.role == .output, let category {
            Divider()
            Button {
                let target: OutputCategory = category == .speaker
                    ? .headphone
                    : .speaker
                model.setCategory(target, for: device)
            } label: {
                Label(
                    category == .speaker
                        ? "Move to Headphones"
                        : "Move to Speakers",
                    systemImage: category == .speaker
                        ? "headphones"
                        : "speaker.wave.2.fill"
                )
            }
        }

        Divider()
        if isHidden {
            Button {
                model.unhide(device)
            } label: {
                Label("Unhide Device", systemImage: "eye")
            }
        } else {
            Button {
                model.hide(device)
            } label: {
                Label("Hide Device", systemImage: "eye.slash")
            }
            .disabled(isSelected)
        }

        if device.isConnected {
            Divider()
            Button {
                model.setNeverUse(device, !isNeverUse)
            } label: {
                Label(
                    isNeverUse
                        ? "Allow Auto-Selection"
                        : "Never Auto-Select",
                    systemImage: isNeverUse ? "checkmark.circle" : "nosign"
                )
            }
            if model.canDisconnect(device) {
                Button { model.disconnect(device) } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        }

        if !device.isConnected {
            Divider()
            Button(role: .destructive, action: confirmForget) {
                Label("Forget Device", systemImage: "trash")
            }
        }
    }

    private var activationTitle: String {
        let role = device.role == .input ? "Microphone" : "Output"
        if isSelected {
            return isUnavailable ? "Current \(role), Unavailable" : "Current \(role)"
        }
        return device.role == .input ? "Use as Microphone" : "Use for Sound Output"
    }

    private func accessibilityValue(_ details: [Status]) -> String {
        var values = ["Priority \(index + 1) of \(count)"]
        if isSelected { values.append("Current") }
        values.append(contentsOf: details.map(\.description))
        return values.joined(separator: ", ")
    }
}

/// A round headset control, sized like the device badge beside the name.
/// Off, it is the neutral badge; on, an opaque fill under a white glyph that
/// darkens a little under the pointer, so its contrast never depends on what
/// the glass shows behind the panel.
private struct HeadsetGlyph: View {
    let symbol: String
    var isOn = false
    var tint: Color = .accentColor
    var isDimmed = false
    @State private var isHovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(isOn ? tint : Color.primary.opacity(isHovering ? 0.16 : 0.1))
                    .brightness(isOn && isHovering ? -0.12 : 0)
            )
            .opacity(isDimmed ? 0.5 : 1)
            .contentShape(Circle())
            .onHover { isHovering = $0 }
    }
}

private extension JabraGNP.NoiseMode {
    var title: String {
        switch self {
        case .off: "Off"
        case .cancelling: "Noise Cancellation"
        case .hearThrough: "HearThrough"
        }
    }

    var symbol: String {
        switch self {
        case .off: "headphones"
        case .cancelling: "person.and.background.dotted"
        case .hearThrough: "ear.and.waveform"
        }
    }
}
