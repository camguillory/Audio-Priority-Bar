import AudioPriorityCore
import AppKit
import SwiftUI

struct DeviceRow: View {
    private struct Status {
        let icon: String, text: String
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmsForget = false
    @State private var isHovering = false

    private var linkState: LinkState? { model.linkState(for: device) }
    private var isUnavailable: Bool { linkState == .down }
    private var isIgnored: Bool { model.isIgnored(device, category: category) }
    private var isNeverUse: Bool { model.isNeverUse(device) }
    private var statuses: [Status] {
        var result: [Status] = []
        if isSelected && isUnavailable {
            result.append(Status(
                icon: "exclamationmark.circle",
                text: "Current"
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
        if linkState == .down {
            result.append(Status(
                icon: "antenna.radiowaves.left.and.right.slash",
                text: "Headset off"
            ))
        } else if linkState == .unknown {
            result.append(Status(icon: "questionmark.circle", text: "Link unknown"))
        } else if linkState == .monitoringUnavailable {
            result.append(Status(icon: "antenna.radiowaves.left.and.right.slash", text: "Link unavailable"))
        }
        if isIgnored {
            result.append(Status(icon: "eye.slash", text: "Excluded"))
        }
        if isNeverUse {
            result.append(Status(icon: "nosign", text: "Never auto-select"))
        }
        if model.isMuted(device) {
            result.append(Status(
                icon: device.role == .input ? "mic.slash.fill" : "speaker.slash.fill",
                text: "Muted"
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
                                .foregroundStyle(statusColor(status))
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
        .onHover { isHovering = $0 }
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
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    private func statusColor(_ status: Status) -> Color {
        if status.text == "Muted" { return .red }
        if status.text == "Current" { return .orange }
        return .secondary
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
            if isIgnored {
                Button {
                    model.stopIgnoring(device, category: category)
                } label: {
                    Label("Include in This List", systemImage: "eye")
                }
            } else {
                Button {
                    model.hide(device, category: category)
                } label: {
                    Label("Exclude from This List", systemImage: "eye.slash")
                }
                .disabled(isSelected)
            }
            if device.role == .output {
                Button {
                    model.hideEntirely(device)
                } label: {
                    Label(
                        "Exclude from Speakers and Headphones",
                        systemImage: "eye.slash.fill"
                    )
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
