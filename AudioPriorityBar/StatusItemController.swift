import AudioPriorityCore
import AppKit
import Observation
import SwiftUI

enum StatusItemClickAction: Equatable { case togglePanel, showMenu, toggleMute }

enum ClickRouting {
    private static let suppressionLifetime: TimeInterval = 2

    static func action(
        for eventType: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = []
    ) -> StatusItemClickAction {
        if eventType == .rightMouseUp
            || (eventType == .leftMouseUp && modifiers.contains(.control)) {
            return .showMenu
        }
        if eventType == .leftMouseUp && modifiers.contains(.option) {
            return .toggleMute
        }
        return .togglePanel
    }

    static func shouldSuppressOpen(
        suppressedAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard let suppressedAt else { return false }
        return now - suppressedAt < suppressionLifetime
    }
}

enum PanelPlacement {
    /// Centers a window under the status item, kept 4 points inside the
    /// visible part of the screen.
    static func origin(
        buttonRect: NSRect,
        size: NSSize,
        visibleFrame visible: NSRect
    ) -> NSPoint {
        let maxX = max(visible.maxX - size.width - 4, visible.minX + 4)
        let x = min(
            max(buttonRect.midX - size.width / 2, visible.minX + 4),
            maxX
        )
        let y = max(buttonRect.minY - size.height - 4, visible.minY + 4)
        return NSPoint(x: x, y: y)
    }
}

private final class PanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let settings: SettingsWindowController
    private let updates: UpdateChecker
    private let statusItem: NSStatusItem
    private let panel = PanelWindow(
        contentRect: .zero,
        styleMask: [.nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let menu = NSMenu()
    private let updatesItem = NSMenuItem(
        title: "Check for Updates…",
        action: nil,
        keyEquivalent: ""
    )
    private let muteItem = NSMenuItem(
        title: "Mute Microphone",
        action: nil,
        keyEquivalent: ""
    )
    private let labelView: PassthroughHostingView<StatusLabel>
    private var suppressNextClickAt: TimeInterval?
    /// The status item's center when the panel opened. The item widens and
    /// narrows with its glyphs, like the muted microphone, and re-centering on
    /// it would slide the open panel sideways.
    private var panelAnchorX: CGFloat?
    private lazy var notice = NoticePanel { [weak self] size in
        guard let self, let button = statusItem.button else { return nil }
        return origin(under: button, size: size)
    }

    init(
        model: AppModel,
        settings: SettingsWindowController,
        updates: UpdateChecker,
        statusBar: NSStatusBar = .system
    ) {
        self.model = model
        self.settings = settings
        self.updates = updates
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        labelView = PassthroughHostingView(
            rootView: StatusLabel(model: model)
        )
        super.init()
        configureStatusItem()
        configurePanel()
        configureMenu()
        observeStatus()
        observeNotice()
        model.onAutomaticSwitch = { [weak self] in self?.showSwitchNotice($0) }
        // Launch with `--args -previewNotices YES` to see both notices without
        // changing any hardware.
        if UserDefaults.standard.bool(forKey: "previewNotices") { previewNotices() }
    }

    private func previewNotices() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            showSwitchNotice(
                [model.currentOutputDevice, model.currentInputDevice].compactMap { $0 }
            )
            try? await Task.sleep(for: .seconds(2.5))
            notice.showsMutedReminder = true
            try? await Task.sleep(for: .seconds(3))
            notice.showsMutedReminder = model.remindsWhenMuted
                && model.isMicrophoneMuted
                && model.isInputRecording
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        labelView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(labelView)
        NSLayoutConstraint.activate([
            labelView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            labelView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.setAccessibilityLabel(appDisplayName)
        button.setAccessibilityHelp(
            "Activate to show audio devices; open the context menu to mute the microphone, or for Settings and Quit"
        )
    }

    private func configurePanel() {
        let hostingController = NSHostingController(
            rootView: PanelView(
                model: model,
                updates: updates,
                showSettings: { [weak self] in
                    self?.hidePanel()
                    self?.showSettings()
                },
                downloadUpdate: { [weak self] in
                    self?.hidePanel()
                    guard let url = self?.updates.downloadURL else { return }
                    NSWorkspace.shared.open(url)
                }
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hostingController
        panel.setAccessibilityLabel(appDisplayName)
        panel.initialFirstResponder = hostingController.view
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hidePanel() }
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        muteItem.target = self
        muteItem.action = #selector(toggleMute)
        menu.addItem(muteItem)
        menu.addItem(.separator())
        updatesItem.target = self
        updatesItem.action = #selector(handleUpdatesItem)
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        let settingsItem = menu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(
            withTitle: "Quit Audio Priority Bar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
    }

    private func observeStatus() {
        withObservationTracking {
            _ = statusDescription
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatus()
                self?.observeStatus()
            }
        }
        updateStatus()
    }

    private func updateStatus() {
        labelView.layoutSubtreeIfNeeded()
        statusItem.length = ceil(labelView.fittingSize.width)
        statusItem.button?.setAccessibilityValue(statusDescription)
        // Sighted users get the same wording on hover, so the warning glyph
        // does not have to carry the explanation by itself.
        statusItem.button?.toolTip = statusDescription
        if panel.isVisible, let button = statusItem.button {
            positionPanel(relativeTo: button)
        }
    }

    @objc private func handleClick() {
        let action: StatusItemClickAction
        if let event = NSApp.currentEvent,
           ProcessInfo.processInfo.systemUptime - event.timestamp < 1,
           isPointInStatusItem(NSEvent.mouseLocation) {
            action = ClickRouting.action(
                for: event.type,
                modifiers: event.modifierFlags
            )
        } else {
            action = .togglePanel
        }
        switch action {
        case .togglePanel: togglePanel()
        case .showMenu: showMenu()
        case .toggleMute: toggleMute()
        }
    }

    @objc private func toggleMute() {
        model.setMicrophoneMuted(!model.isMicrophoneMuted)
    }

    private func togglePanel() {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            hidePanel()
            return
        }
        if let suppressedAt = suppressNextClickAt {
            suppressNextClickAt = nil
            if ClickRouting.shouldSuppressOpen(
                suppressedAt: suppressedAt,
                now: ProcessInfo.processInfo.systemUptime
            ) {
                return
            }
        }
        guard let content = panel.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
        panelAnchorX = button.window.map {
            $0.convertToScreen(button.convert(button.bounds, to: nil)).midX
        }
        positionPanel(relativeTo: button)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        notice.isSuppressed = true
    }

    private func showMenu() {
        hidePanel()
        // The item is read fresh here rather than kept in sync continuously,
        // since it is only ever visible for the moment the menu is open.
        updatesItem.title = updates.availableVersion == nil
            ? "Check for Updates…"
            : "Download Update…"
        muteItem.title = model.isMicrophoneMuted
            ? "Unmute Microphone"
            : "Mute Microphone"
        muteItem.isEnabled = model.currentInputID != nil
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showSettings() {
        // The status item lives in the menu bar of the screen being used, which
        // is the same screen the panel is positioned against.
        settings.showSettings(on: statusItem.button?.window?.screen)
    }

    @objc private func handleUpdatesItem() {
        if let downloadURL = updates.downloadURL, updates.availableVersion != nil {
            NSWorkspace.shared.open(downloadURL)
        } else {
            showSettings()
            updates.checkManually()
        }
    }

    private func hidePanel(suppressNextClick: Bool = false) {
        statusItem.button?.highlight(false)
        guard panel.isVisible else { return }
        if suppressNextClick {
            suppressNextClickAt = ProcessInfo.processInfo.systemUptime
        }
        panel.orderOut(nil)
        panelAnchorX = nil
        notice.isSuppressed = false
    }

    private func positionPanel(relativeTo button: NSStatusBarButton) {
        if let origin = origin(under: button, size: panel.frame.size, centeredAt: panelAnchorX) {
            panel.setFrameOrigin(origin)
        }
    }

    private func origin(
        under button: NSStatusBarButton,
        size: NSSize,
        centeredAt anchorX: CGFloat? = nil
    ) -> NSPoint? {
        guard let window = button.window, let screen = window.screen else { return nil }
        var buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        if let anchorX { buttonRect.origin.x = anchorX - buttonRect.width / 2 }
        return PanelPlacement.origin(
            buttonRect: buttonRect,
            size: size,
            visibleFrame: screen.visibleFrame
        )
    }

    private func observeNotice() {
        withObservationTracking {
            notice.showsMutedReminder = model.remindsWhenMuted
                && model.isMicrophoneMuted
                && model.isInputRecording
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeNotice() }
        }
    }

    private func showSwitchNotice(_ devices: [AudioDevice]) {
        guard model.showsSwitchNotice, !devices.isEmpty else { return }
        notice.showSwitch(NoticeContent.switched(to: devices) { device in
            device.hardwareIcon(
                category: device.role == .output ? model.store.category(for: device) : nil
            )
        })
    }

    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow()
        if panel.isVisible, let button = statusItem.button {
            positionPanel(relativeTo: button)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  panel.isVisible,
                  panel.attachedSheet == nil,
                  NSApp.modalWindow == nil,
                  !isRelatedToPanel(NSApp.keyWindow) else {
                return
            }
            hidePanel(suppressNextClick: isPointInStatusItem(NSEvent.mouseLocation))
        }
    }

    private func isRelatedToPanel(_ window: NSWindow?) -> Bool {
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent ?? current.sheetParent
        }
        return false
    }

    private func isPointInStatusItem(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else {
            return false
        }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
            .contains(point)
    }

    private var statusDescription: String {
        var values = [model.isManualMode ? "Manual" : "Automatic"]
        if let category = model.activeOutputCategory {
            values.append(category == .speaker ? "speakers" : "headphones")
        }
        if model.isActiveOutputLinkDown { values.append("headset off") }
        if model.isActiveOutputMuted { values.append("output muted") }
        if model.isActiveInputMuted { values.append("microphone muted") }
        if model.isVolumeControllable {
            values.append("volume \(Int(model.volume * 100)) percent")
        }
        return values.joined(separator: ", ")
    }
}

private struct StatusLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            if model.isActiveInputMuted {
                Image(systemName: "mic.slash.fill")
                    .opacity(reduceMotion || model.micFlashState ? 1 : 0.45)
            }
            // Every possible output glyph sits hidden underneath, so the item
            // keeps the widest one's width instead of resizing as the output
            // changes.
            ZStack {
                ForEach(Self.reservedIcons, id: \.self) {
                    Image(systemName: $0).hidden()
                }
                if model.isActiveOutputMuted {
                    Image(systemName: "speaker.slash.fill")
                } else if let hardwareIcon {
                    Image(systemName: Self.filled(hardwareIcon))
                } else if !model.isVolumeControllable {
                    Image(systemName: "speaker.wave.2.fill")
                } else {
                    Image(
                        systemName: "speaker.wave.2.fill",
                        variableValue: Double(model.volume)
                    )
                }
            }

            // Beside the audio glyph rather than replacing it: that glyph
            // still identifies the app and the active category, while this
            // one flags the exceptional state. Monochrome like the rest, since
            // colored menu bar icons fight light and dark contrast.
            if model.isActiveOutputLinkDown {
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .padding(.horizontal, 1)
        .accessibilityHidden(true)
    }

    /// The current output's hardware icon, or nil for a generic speaker,
    /// which shows the volume level instead. Falls back to the category
    /// while no output is known.
    private var hardwareIcon: String? {
        let icon = model.currentOutputDevice.map {
            $0.hardwareIcon(category: model.activeOutputCategory)
        } ?? (model.activeOutputCategory == .headphone ? "headphones" : nil)
        return icon == AudioDevice.genericSpeakerIcon ? nil : icon
    }

    private static let reservedIcons = (
        AudioDevice.hardwareIcons + ["speaker.wave.2", "speaker.slash"]
    ).map(filled)

    /// The menu bar uses filled glyphs; not every hardware symbol has one.
    nonisolated private static func filled(_ name: String) -> String {
        let fill = name + ".fill"
        return NSImage(systemSymbolName: fill, accessibilityDescription: nil) == nil
            ? name
            : fill
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
