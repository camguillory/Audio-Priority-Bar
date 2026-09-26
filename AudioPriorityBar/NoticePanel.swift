import AppKit
import AudioPriorityCore
import SwiftUI

/// What the floating notice under the menu bar icon shows.
struct NoticeContent: Equatable {
    let icon: String
    let text: String

    static let mutedWhileRecording = NoticeContent(
        icon: "mic.slash.fill",
        text: "Microphone muted"
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

    /// Describes one automatic switch. Both halves of a USB headset switching
    /// together read as one device rather than two separate changes.
    static func switchText(_ devices: [AudioDevice]) -> String {
        func label(_ device: AudioDevice) -> String {
            device.role == .input ? "Microphone" : "Output"
        }
        guard let first = devices.first else { return "" }
        guard devices.count > 1 else { return "\(label(first)): \(first.name)" }
        let second = devices[1]
        if first.name == second.name {
            return "Output and microphone: \(first.name)"
        }
        return "\(label(first)): \(first.name), "
            + "\(label(second).lowercased()): \(second.name)"
    }
}

/// A borderless, click-through window below the menu bar icon, used for the
/// automatic switch notice and the muted reminder.
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
        rootView: NoticeView(content: .mutedWhileRecording)
    )
    private let placement: (NSSize) -> NSPoint?
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
        host.rootView = NoticeView(content: content)
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
                .announcement: content.text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

private struct NoticeView: View {
    let content: NoticeContent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: content.icon)
            Text(content.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
