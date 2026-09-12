import AppKit
import Observation
import SwiftUI

enum StatusItemClickAction: Equatable { case togglePanel, showMenu }

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
    private let statusItem: NSStatusItem
    private let panel = PanelWindow(
        contentRect: .zero,
        styleMask: [.nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let menu = NSMenu()
    private let labelView: PassthroughHostingView<StatusLabel>
    private var suppressNextClickAt: TimeInterval?

    init(
        model: AppModel,
        settings: SettingsWindowController,
        statusBar: NSStatusBar = .system
    ) {
        self.model = model
        self.settings = settings
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        labelView = PassthroughHostingView(
            rootView: StatusLabel(model: model)
        )
        super.init()
        configureStatusItem()
        configurePanel()
        configureMenu()
        observeStatus()
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
            "Activate to show audio devices; open the context menu for Settings and Quit"
        )
    }

    private func configurePanel() {
        let hostingController = NSHostingController(
            rootView: PanelView(
                model: model,
                showSettings: { [weak self] in
                    self?.hidePanel()
                    self?.settings.showSettings()
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
        statusItem.length = ceil(labelView.fittingSize.width) + 8
        statusItem.button?.setAccessibilityValue(statusDescription)
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
        }
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
        positionPanel(relativeTo: button)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
    }

    private func showMenu() {
        hidePanel()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showSettings() {
        settings.showSettings()
    }

    private func hidePanel(suppressNextClick: Bool = false) {
        statusItem.button?.highlight(false)
        guard panel.isVisible else { return }
        if suppressNextClick {
            suppressNextClickAt = ProcessInfo.processInfo.systemUptime
        }
        panel.orderOut(nil)
    }

    private func positionPanel(relativeTo button: NSStatusBarButton) {
        guard let window = button.window, let screen = window.screen else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let maxX = max(visible.maxX - size.width - 4, visible.minX + 4)
        let x = min(
            max(buttonRect.midX - size.width / 2, visible.minX + 4),
            maxX
        )
        let y = max(buttonRect.minY - size.height - 4, visible.minY + 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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
                    .frame(width: 16)
                    .opacity(reduceMotion || model.micFlashState ? 1 : 0.45)
            }
            Group {
                if model.isActiveOutputMuted {
                    Image(systemName: "speaker.slash.fill")
                } else if model.activeOutputCategory == .headphone {
                    Image(systemName: "headphones")
                } else if !model.isVolumeControllable {
                    Image(systemName: "speaker.wave.3.fill")
                } else {
                    Image(
                        systemName: "speaker.wave.3.fill",
                        variableValue: Double(model.volume)
                    )
                }
            }
            .frame(width: 24)
        }
        .accessibilityHidden(true)
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
