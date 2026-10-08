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
    /// What VoiceOver reads, which names each device's role since the icons
    /// only show it visually.
    let announcement: String

    static let mutedWhileRecording = NoticeContent(
        lines: [Line(icon: "mic.slash.fill", text: "Microphone muted")],
        announcement: "Microphone muted"
    )

    /// A switch notice wins for its moment, then the muted reminder returns
    /// if it still applies. Nothing shows over the open panel.
    static func current(
        switchNotice: NoticeContent?,
        showsMutedReminder: Bool,
        isSuppressed: Bool
    ) -> NoticeContent? {
        guard !isSuppressed else { return nil }
        return switchNotice ?? (showsMutedReminder ? mutedWhileRecording : nil)
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
                lines: [Line(icon: icon(devices[0]), text: devices[0].name)],
                announcement: "Output and microphone: \(devices[0].name)"
            )
        }
        return NoticeContent(
            lines: devices.map { Line(icon: icon($0), text: $0.name) },
            announcement: devices.map {
                "\($0.role == .input ? "Microphone" : "Output"): \($0.name)"
            }.joined(separator: ", ")
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

    var showsMutedReminder = false {
        didSet { if oldValue != showsMutedReminder { update() } }
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
            showsMutedReminder: showsMutedReminder,
            isSuppressed: isSuppressed
        )
        guard content != shown else { return }
        shown = content
        let isReminder = content == .mutedWhileRecording
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
            bubble
                .contentShape(shape)
                .onTapGesture(perform: onDismiss)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Hides the reminder until you next record while muted")
                .accessibilityAction(named: "Dismiss", onDismiss)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(content.lines, id: \.text) { line in
                HStack(spacing: 8) {
                    // A shared width keeps the text of every line aligned.
                    Image(systemName: line.icon)
                        .frame(width: 18)
                    Text(line.text)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: shape)
        .fixedSize()
    }

    /// A capsule for one line; two lines would make its ends look swollen.
    private var shape: AnyShape {
        content.lines.count > 1
            ? AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            : AnyShape(Capsule())
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
        // In the panel's order: its header, then output, then microphone.
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Automatic switching")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 16)
                    Text(model.isManualMode ? "Off" : "On")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                // What the tooltip used to explain behind the warning glyph.
                if model.isActiveOutputLinkDown {
                    Label("Headset off", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                row(
                    model.currentOutputDevice,
                    placeholder: "No output",
                    showsLevel: model.isVolumeControllable,
                    level: model.volume
                )
                row(
                    model.currentInputDevice,
                    placeholder: "No microphone",
                    showsLevel: model.isMicrophoneLevelControllable,
                    level: model.microphoneLevel
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .modifier(PanelBackground())
        .fixedSize()
    }

    /// Icon, name, and mute status styled as in the device list, with the
    /// level underneath when the device reports one.
    @ViewBuilder
    private func row(
        _ device: AudioDevice?,
        placeholder: String,
        showsLevel: Bool,
        level: Float
    ) -> some View {
        let isMuted = device.map(model.isMuted) ?? false
        HStack(spacing: 8) {
            // No circle, unlike the panel's buttons, since nothing here can
            // be clicked. Muted is red, like the panel's mute button.
            Image(systemName: isMuted ? mutedIcon(device) : device.map(icon) ?? "questionmark")
                .font(.system(size: 14))
                .foregroundStyle(isMuted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(device?.name ?? placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(device == nil ? .secondary : .primary)
                    .lineLimit(1)
                if device != nil, showsLevel {
                    LevelBar(level: level, isMuted: isMuted)
                }
            }
        }
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

/// A read-only volume meter, dimmed while muted like the panel's slider.
/// Drawn in the text color with no thumb or value, so it does not read as a
/// slider to drag.
private struct LevelBar: View {
    let level: Float
    let isMuted: Bool

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.1))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.primary)
                        .frame(width: proxy.size.width * CGFloat(level))
                }
            }
            .clipShape(Capsule())
            .frame(width: 120, height: 4)
            .opacity(isMuted ? 0.5 : 1)
    }
}
