import AppKit
import AudioPriorityCore
import SwiftUI

/// What the floating notice under the menu bar icon shows.
struct NoticeContent: Equatable {
    struct Line: Equatable {
        let icon: String
        let text: String
    }

    let lines: [Line]
    /// The notice read as a single announcement when the window appears.
    let announcement: String

    static let mutedWhileRecording = NoticeContent(
        lines: [Line(icon: "mic.slash.fill", text: "Microphone muted")],
        announcement: "Microphone muted"
    )

    /// While muted, an app records from a microphone the mute does not hold.
    static func unmuted(_ recording: UncoveredRecording) -> NoticeContent {
        let text = recording.isConfirmed
            ? "\(recording.app ?? "An app") is using \(recording.microphone), which isn't muted"
            : "\(recording.microphone) is active and may be recording unmuted"
        return NoticeContent(lines: [Line(icon: "mic.fill", text: text)], announcement: text)
    }

    /// A switch notice wins for its moment, then the muted reminder returns
    /// if it still applies. Nothing shows over the open panel.
    static func current(
        switchNotice: NoticeContent?,
        mutedReminder: NoticeContent?,
        isSuppressed: Bool
    ) -> NoticeContent? {
        guard !isSuppressed else { return nil }
        return switchNotice ?? mutedReminder
    }

    /// Describes one automatic switch, one line per device: its icon and
    /// name. Both halves of a USB headset switching together read as one
    /// device rather than two separate changes.
    static func switched(
        to devices: [AudioDevice],
        icon: (AudioDevice) -> String
    ) -> NoticeContent {
        if devices.count == 2, devices[0].name == devices[1].name {
            return NoticeContent(
                lines: [Line(icon: icon(devices[0]), text: "Output and microphone · \(devices[0].name)")],
                announcement: "Output and microphone: \(devices[0].name)"
            )
        }
        return NoticeContent(
            lines: devices.map {
                Line(icon: icon($0), text: "\($0.role == .input ? "Microphone" : "Output") · \($0.name)")
            },
            announcement: devices.map {
                "\($0.role == .input ? "Microphone" : "Output"): \($0.name)"
            }.joined(separator: ", ")
        )
    }

    /// Names the profile a Focus or shortcut applied, then the devices it
    /// changed, if any.
    static func applied(
        profile: String,
        devices: [AudioDevice],
        icon: (AudioDevice) -> String
    ) -> NoticeContent {
        let profileLine = Line(icon: "rectangle.stack", text: "Profile · \(profile)")
        guard !devices.isEmpty else {
            return NoticeContent(lines: [profileLine], announcement: "Profile: \(profile)")
        }
        let switched = switched(to: devices, icon: icon)
        return NoticeContent(
            lines: [profileLine] + switched.lines,
            announcement: "Profile: \(profile), \(switched.announcement)"
        )
    }
}

/// Whether the muted reminder shows. Dismissing it hides it until it stops
/// applying, so the next recording while muted brings it back.
struct MutedReminderState {
    private(set) var isDismissed = false

    mutating func update(applies: Bool) -> Bool {
        if !applies { isDismissed = false }
        return applies && !isDismissed
    }

    mutating func dismiss() {
        isDismissed = true
    }
}

/// A borderless window below the menu bar icon, used for the automatic switch
/// notice and the muted reminder. It is click-through except while showing
/// the reminder, which a click dismisses.
@MainActor
final class NoticePanel {
    private static let switchDuration: Duration = .milliseconds(1500)

    private let window = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let host = NSHostingView(
        rootView: NoticeView(content: .mutedWhileRecording, onDismiss: nil)
    )
    private let placement: (NSSize) -> NSPoint?
    var onDismissMutedReminder: (() -> Void)?
    private var switchNotice: NoticeContent?
    private var clearTask: Task<Void, Never>?
    private var shown: NoticeContent?

    var mutedReminder: NoticeContent? {
        didSet { if oldValue != mutedReminder { update() } }
    }

    /// True while the panel is open, which already shows everything.
    var isSuppressed = false {
        didSet { if oldValue != isSuppressed { update() } }
    }

    init(placement: @escaping (NSSize) -> NSPoint?) {
        self.placement = placement
        window.contentView = host
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
    }

    func showSwitch(_ content: NoticeContent) {
        guard !isSuppressed else { return }
        switchNotice = content
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.switchDuration)
            guard !Task.isCancelled, let self else { return }
            switchNotice = nil
            update()
        }
        update()
    }

    private func update() {
        let content = NoticeContent.current(
            switchNotice: switchNotice,
            mutedReminder: mutedReminder,
            isSuppressed: isSuppressed
        )
        guard content != shown else { return }
        shown = content
        let isReminder = content != nil && content == mutedReminder
        window.ignoresMouseEvents = !isReminder
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let content else {
            guard animates else { return window.orderOut(nil) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, shown == nil else { return }
                    window.orderOut(nil)
                }
            }
            return
        }
        host.rootView = NoticeView(
            content: content,
            onDismiss: isReminder
                ? { [weak self] in self?.onDismissMutedReminder?() }
                : nil
        )
        let size = host.fittingSize
        window.setContentSize(size)
        if let origin = placement(size) { window.setFrameOrigin(origin) }
        if !window.isVisible { window.alphaValue = animates ? 0 : 1 }
        window.orderFrontRegardless()
        if animates {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: content.announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

private struct NoticeView: View {
    let content: NoticeContent
    let onDismiss: (() -> Void)?

    var body: some View {
        if let onDismiss {
            Button(action: onDismiss) { bubble }
                .buttonStyle(.plain)
                .accessibilityLabel(content.announcement)
                .accessibilityHint("Dismiss this reminder until the next recording")
        } else {
            bubble.accessibilityLabel(content.announcement)
        }
    }

    private var bubble: some View {
        NoticeLayout {
            message
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .fixedSize()
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(content.lines.indices, id: \.self) { index in
                    let line = content.lines[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: line.icon)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(line.text)
                            .font(.body.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if onDismiss != nil {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// AppKit asks for the notice's ideal size before it assigns a window frame.
/// Measure the height at the final wrapping width, including for long warnings.
private struct NoticeLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let message = subviews.first else { return .zero }
        let width = min(320, message.sizeThatFits(.unspecified).width)
        let size = message.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// A click-through window below the menu bar icon, shown while the pointer
/// rests on it, naming the current microphone and output.
@MainActor
final class HoverPreviewPanel {
    private let window = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let host: NSHostingController<HoverPreviewView>
    private let placement: (NSSize) -> NSPoint?

    var isVisible: Bool { window.isVisible }

    init(model: AppModel, placement: @escaping (NSSize) -> NSPoint?) {
        self.placement = placement
        host = NSHostingController(rootView: HoverPreviewView(model: model))
        // Follows the content, such as a device being renamed or muted while
        // the preview is up.
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        // Rounded like the panel's view, so the shadow does not draw a square
        // around the glass. Matches `PanelBackground`.
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = 12
        host.view.layer?.cornerCurve = .continuous
        host.view.layer?.masksToBounds = true
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
    }

    func show() {
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        window.setContentSize(size)
        if let origin = placement(size) { window.setFrameOrigin(origin) }
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

private struct HoverPreviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(model.currentOutputDevice, name: "Output", showsLevel: model.isVolumeControllable, level: model.volume)
            row(model.currentInputDevice, name: "Microphone", showsLevel: model.isMicrophoneLevelControllable, level: model.microphoneLevel)
            Divider()
            HStack {
                Text("Automatic switching")
                Spacer()
                Text(model.isManualMode ? "Off" : "On")
                    .fontWeight(.medium)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if model.isActiveOutputLinkDown {
                Label("Headset off", systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        }
        .padding(12)
        .frame(width: 260)
        .modifier(PanelBackground())
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ device: AudioDevice?, name: String, showsLevel: Bool, level: Float) -> some View {
        let isMuted = device.map(model.isMuted) ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isMuted ? mutedIcon(device) : device.map(icon) ?? "minus")
                .foregroundStyle(isMuted ? Color.red : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name)
                    Spacer()
                    if isMuted {
                        Text("Muted").fontWeight(.semibold)
                    } else if device != nil && showsLevel {
                        Text(level, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(device?.name ?? "None selected")
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func mutedIcon(_ device: AudioDevice?) -> String {
        device?.role == .input ? "mic.slash.fill" : "speaker.slash.fill"
    }

    private func icon(_ device: AudioDevice) -> String {
        device.hardwareIcon(
            category: device.role == .output ? model.store.category(for: device) : nil
        )
    }
}
