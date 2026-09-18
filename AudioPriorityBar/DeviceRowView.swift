import AudioPriorityCore
import AppKit
import SwiftUI

struct DeviceRow: View {
    private struct Status {
        let icon: String, text: String
        /// Carried with the value so restyling never depends on matching copy.
        var tint: Color = .secondary
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
    @State private var confirmsForget = false
    @State private var isHovering = false
    @State private var isHoveringSelectionOverride = false

    private var linkState: LinkState? { model.linkState(for: device) }
    private var isUnavailable: Bool { linkState == .down }
    private var isHidden: Bool { model.isHidden(device) }
    private var isNeverUse: Bool { model.isNeverUse(device) }
    private var pairedDevice: AudioDevice? { model.pairedDevice(for: device) }

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
        if model.selectsPairedDevice {
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
        if isSelected && isUnavailable {
            result.append(Status(
                icon: "exclamationmark.circle",
                text: "Current",
                tint: .orange
            ))
        }
        if !device.isConnected {
            let seen = model.store.storedDevice(
                uid: device.uid,
                role: device.role
            )?.relativeLastSeen()
            result.append(Status(
                icon: "wifi.slash",
                text: ["Disconnected", seen.map { "Last seen \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
            ))
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
                icon: device.role == .input ? "mic.slash.fill" : "speaker.slash.fill",
                text: "Muted",
                tint: .red
            ))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0.65)
            }
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .lineLimit(1)
                    .help(device.name)
                    .foregroundStyle(
                        device.isConnected && !isUnavailable
                            ? .primary
                            : .secondary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !statuses.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(statuses, id: \.text) { status in
                            Label(status.text, systemImage: status.icon)
                                .font(.caption)
                                .foregroundStyle(status.tint)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(statuses.map(\.text).joined(separator: " · "))
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            selectionOverride

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(isUnavailable ? Color.orange : Color.accentColor)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 18)
                .accessibilityHidden(true)

            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: DeviceRowMetrics.height)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isLifted ? Color(nsColor: .controlBackgroundColor) : rowBackground)
        }
        .scaleEffect(isLifted && !reduceMotion ? 1.02 : 1)
        .shadow(
            color: .black.opacity(isLifted ? 0.28 : 0),
            radius: isLifted ? 10 : 0,
            y: isLifted ? 5 : 0
        )
        .onHover { hovering in
            isHovering = hovering
            guard model.selectsPairedDevice, isPairedDeviceUsable, !isSelected,
                  !isHoveringSelectionOverride, let pairedDevice else { return }
            if hovering {
                highlightedPairedDeviceID = pairedDevice.id
            } else if highlightedPairedDeviceID == pairedDevice.id {
                highlightedPairedDeviceID = nil
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if device.isConnected, !isUnavailable, !isSelected { select() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(device.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            !device.isConnected
                ? "Use the actions menu to manage this device"
                : (isUnavailable
                    ? "This device is unavailable"
                    : (isSelected
                        ? "Current device"
                        : (model.isManualMode
                            ? "Activate to make this device active"
                            : "Activate to select this device and turn off automatic switching")))
        )
        .accessibilityAction {
            if device.isConnected, !isUnavailable, !isSelected { select() }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Move Up") {
            if index > 0 { move(index - 1) }
        }
        .accessibilityAction(named: "Move Down") {
            if index < count - 1 { move(index + 1) }
        }
        .confirmationDialog(
            "Forget \(device.name)?",
            isPresented: $confirmsForget,
            titleVisibility: .visible
        ) {
            Button("Forget Device", role: .destructive) {
                model.forget(device)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its saved priority, category, and visibility will be removed.")
        }
    }

    private var rowBackground: Color {
        if isSelected && isUnavailable { return Color.orange.opacity(0.12) }
        if isSelected { return Color.accentColor.opacity(0.14) }
        return isHovering || isHighlightedPairedDevice
            ? Color.primary.opacity(0.06) : .clear
    }

    /// The override for the current default: offers to select only this
    /// device while both are normally selected together, or to select both
    /// while only one is. Shown only while it would change something, so a
    /// row whose pair is already in the target state, unavailable, or absent
    /// keeps the layout it had before.
    @ViewBuilder
    private var selectionOverride: some View {
        if let pairedDevice, isPairedDeviceUsable {
            if model.selectsPairedDevice {
                if !isSelected {
                    selectionOverridePill(
                        partner: pairedDevice,
                        label: device.role == .input ? "Mic only" : "Output only",
                        action: { model.selectOnly(device) }
                    )
                }
            } else if canSelectBothDevices {
                selectionOverridePill(
                    partner: pairedDevice,
                    label: "Use both",
                    action: { model.selectWithPairedDevice(device) }
                )
            }
        }
    }

    private func selectionOverridePill(
        partner: AudioDevice,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(
                    Capsule().fill(
                        Color.primary.opacity(isHoveringSelectionOverride ? 0.12 : 0.06)
                    )
                )
        }
        .buttonStyle(.plain)
        .help(selectionOverrideHelp)
        .accessibilityLabel(selectionOverrideHelp)
        .onHover { hovering in
            isHoveringSelectionOverride = hovering
            if model.selectsPairedDevice {
                // This override selects only the hovered device, so
                // suppress the partner highlight while hovering it, and
                // restore it when returning to the row, which still selects
                // both.
                if hovering {
                    if highlightedPairedDeviceID == partner.id {
                        highlightedPairedDeviceID = nil
                    }
                } else if isHovering, !isSelected {
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

    private var actions: some View {
        Menu {
            if device.isConnected {
                Button(action: select) {
                    Label(
                        activationTitle,
                        systemImage: "checkmark.circle"
                    )
                }
                    .disabled(isSelected || isUnavailable)
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
                    Label("Show Device", systemImage: "eye")
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
            }

            if !device.isConnected {
                Divider()
                Button(role: .destructive) {
                    confirmsForget = true
                } label: {
                    Label("Forget Device", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .accessibilityLabel("Actions for \(device.name)")
    }

    private var activationTitle: String {
        let role = device.role == .input ? "Microphone" : "Output"
        if isSelected {
            return isUnavailable ? "Current \(role), Unavailable" : "Current \(role)"
        }
        return device.role == .input ? "Use as Microphone" : "Use for Sound Output"
    }

    private var accessibilityValue: String {
        var values = ["Priority \(index + 1) of \(count)"]
        if isSelected, !isUnavailable { values.append("Active") }
        values.append(contentsOf: statuses.map(\.text))
        return values.joined(separator: ", ")
    }
}
