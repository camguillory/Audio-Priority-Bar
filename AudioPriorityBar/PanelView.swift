import AudioPriorityCore
import AppKit
import Combine
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    let showSettings: () -> Void
    var showProfiles: () -> Void = {}
    var showActivity: () -> Void = {}
    var panelScreen: () -> NSScreen? = { NSScreen.main }
    /// Reports the size the content needs, which the panel takes on.
    var fit: (CGSize) -> Void = { _ in }

    /// The AirPods page, which holds their Connect to This Mac setting.
    static let headphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.HeadphoneSettings"
    )!

    /// Held here rather than per section so a row can be dragged between lists.
    @State private var drag: DeviceDrag?
    /// The id of the device whose row should show a highlight because the
    /// selection override on its paired device's row is hovered, held here
    /// since the two rows can be in different sections.
    @State private var highlightedPairedDeviceID: String?

    private var layout: PanelLayout {
        PanelLayout(sections: [
            (.speaker, model.speakerDevices.count),
            (.headphone, model.headphoneDevices.count),
            (.input, model.inputDevices.count),
        ])
    }

    private var renderedDeviceIDs: [String] {
        model.listedDevices.map(\.id)
    }

    /// Only ever grows for a drag, so a preview that adds a row cannot clip the
    /// bottom of the list, and one that removes a row cannot resize the panel
    /// out from under the cursor.
    private var listHeight: CGFloat {
        let growth = max(0, drag.map { layout.heightDelta(for: $0) } ?? 0)
        return min(layout.contentHeight + growth, maximumListHeight)
    }

    @State private var headerHeight: CGFloat = 200
    @State private var footerHeight: CGFloat = 80
    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800

    private var maximumListHeight: CGFloat {
        min(520, max(DeviceRowMetrics.height, screenHeight - headerHeight - footerHeight - 16))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Audio devices")
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: showSettings) {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .controlSize(.regular)
                    .keyboardShortcut(",", modifiers: .command)
                    .keyboardHighlight(model.keyboardItem == .settings)
                    .help("Open Audio Priority Bar Settings (⌘,)")
                }
                .padding(.bottom, 11)

                VStack(spacing: 9) {
                    LevelControl(
                        role: .output,
                        device: model.currentOutputDevice,
                        icon: outputIcon,
                        isMuted: model.isActiveOutputMuted,
                        level: model.volume,
                        isControllable: model.isVolumeControllable,
                        canToggleMute: model.isOutputMutable,
                        toggleMute: { model.setOutputMuted(!model.isActiveOutputMuted) },
                        setLevel: model.setVolume
                    )
                    .keyboardHighlight(model.keyboardItem == .outputLevel)
                    LevelControl(
                        role: .input,
                        device: model.currentInputDevice,
                        icon: "mic.fill",
                        isMuted: model.isMicrophoneMuted,
                        level: model.microphoneLevel,
                        isControllable: model.isMicrophoneLevelControllable,
                        canToggleMute: model.isMicrophoneMutable,
                        toggleMute: { model.setMicrophoneMuted(!model.isMicrophoneMuted) },
                        setLevel: model.setMicrophoneLevel
                    )
                    .keyboardHighlight(model.keyboardItem == .microphoneLevel)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                switchingControls
                    .padding(.vertical, 10)
            }
            .padding(.horizontal, PanelLayout.horizontalPadding)
            .padding(.top, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            Divider()

            if model.listedDevices.isEmpty && !model.microphonesFollowOutput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No audio devices to show").font(.headline)
                    Text(model.showAll
                         ? "Connect a speaker, headset, or microphone to get started."
                         : "Connect an audio device, or show hidden and disconnected devices below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PanelLayout.horizontalPadding)
            } else {
                deviceLists
            }

            VStack(spacing: 0) {
                Divider()
                Toggle("Show hidden and disconnected devices", isOn: Binding(
                    get: { model.showAll },
                    set: { value in
                        model.showAll = value
                        model.refreshDevices()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .keyboardHighlight(model.keyboardItem == .showAll)
                .padding(.horizontal, PanelLayout.horizontalPadding)
                .padding(.vertical, 8)
                if let latest = model.recentSwitches.first {
                    Divider()
                    Button(action: showActivity) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(latest.role == .input ? "Last microphone switch" : "Last output switch")
                                        .fontWeight(.semibold)
                                    Text(latest.date, format: .dateTime.hour().minute())
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Text("History")
                                    Image(systemName: "chevron.forward")
                                        .font(.caption.weight(.semibold))
                                }
                                Text("\(latest.device) · \(latest.reason)")
                                    .foregroundStyle(Color.primary.opacity(0.78))
                                    .lineLimit(2)
                            }
                        }
                        .font(.callout)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PanelLinkStyle())
                    .keyboardHighlight(model.keyboardItem == .activity)
                    .accessibilityLabel("Open switch history")
                    .accessibilityValue(latest.description)
                    .help("Open switch history · \(latest.description)")
                    .padding(.horizontal, PanelLayout.horizontalPadding)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: 416)
        .onAppear(perform: updateScreenHeight)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in updateScreenHeight() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in updateScreenHeight() }
        .onChange(of: renderedDeviceIDs) { _, ids in
            if let drag, !ids.contains(drag.device.id) {
                self.drag = nil
            }
            // A row removed while hovered never reports the pointer leaving, so
            // its partner's highlight would outlive both rows.
            if let highlightedPairedDeviceID,
               !ids.contains(highlightedPairedDeviceID) {
                self.highlightedPairedDeviceID = nil
            }
            if case .device(let id)? = model.keyboardItem, !ids.contains(id) {
                model.keyboardItem = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWindow.didResignKeyNotification
            )
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  window.styleMask.contains(.nonactivatingPanel) else {
                return
            }
            drag = nil
        }
        .modifier(PanelBackground())
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { fit($0) }
        // Holds the content to the top while the window catches up with a new
        // height, rather than centering it for a frame.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var deviceLists: some View {
        ScrollViewReader { proxy in
            ScrollView(
                .vertical,
                showsIndicators: listHeight >= maximumListHeight
            ) {
                VStack(spacing: PanelLayout.sectionGap) {
                    DeviceSectionView(
                        model: model,
                        section: .speaker,
                        title: "Speakers",
                        emptyText: "No speakers shown",
                        devices: model.speakerDevices,
                        currentID: model.currentOutputID,
                        layout: layout,
                        drag: $drag,
                        highlightedPairedDeviceID: $highlightedPairedDeviceID
                    )
                    .zIndex(drag?.section == .speaker ? 1 : 0)
                    DeviceSectionView(
                        model: model,
                        section: .headphone,
                        title: "Headphones",
                        emptyText: "No headphones shown",
                        showsSeparator: true,
                        devices: model.headphoneDevices,
                        currentID: model.currentOutputID,
                        layout: layout,
                        drag: $drag,
                        highlightedPairedDeviceID: $highlightedPairedDeviceID
                    )
                    .zIndex(drag?.section == .headphone ? 1 : 0)
                    DeviceSectionView(
                        model: model,
                        section: .input,
                        title: "Microphones",
                        emptyText: "No microphones shown",
                        showsSeparator: true,
                        devices: model.inputDevices,
                        currentID: model.currentInputID,
                        layout: layout,
                        drag: $drag,
                        highlightedPairedDeviceID: $highlightedPairedDeviceID
                    )
                    .zIndex(drag?.section == .input ? 1 : 0)
                }
                .padding(.horizontal, PanelLayout.horizontalPadding)
                .padding(.top, PanelLayout.topPadding)
                .padding(.bottom, PanelLayout.bottomPadding)
                .coordinateSpace(name: PanelLayout.space)
            }
            .frame(height: listHeight)
            .onChange(of: model.keyboardItem) { _, item in
                if case .device(let id)? = item { proxy.scrollTo(id) }
            }
        }
    }

    private func updateScreenHeight() {
        if let screen = panelScreen() { screenHeight = screen.visibleFrame.height }
    }

    private var switchingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Automatic switching", isOn: Binding(
                    get: { !model.isManualMode },
                    set: { model.setManualMode(!$0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.body.weight(.medium))
                .fixedSize()
                .keyboardHighlight(model.keyboardItem == .automatic)
                .help("Choose devices using your saved priority order")
                Spacer(minLength: 0)
                if model.profiles.count > 1 { profileMenu }
            }
            if let takeover = model.takeoverDevice {
                HStack(spacing: 6) {
                    Text(takeover.role == .input
                        ? "\(takeover.name) keeps taking the microphone. Retrying shortly."
                        : "macOS keeps switching to \(takeover.name).")
                        .lineLimit(2)
                    if takeover.isBluetooth {
                        Button("Fix in Settings…") { NSWorkspace.shared.open(Self.headphoneSettingsURL) }
                            .buttonStyle(.link)
                            .fixedSize()
                            .keyboardHighlight(model.keyboardItem == .takeoverFix)
                            .help("Under Connect to This Mac, choose When Last Connected to This Mac")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if let automationNote {
                Text(automationNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(automationNote)
            }
            if !model.microphonesAwaitingRestore.isEmpty {
                warning("Couldn’t restore microphone after mute: \(model.microphonesAwaitingRestore.joined(separator: ", ")).")
            }
            if let speaker = model.speakerMuteFailure, speaker.uid == model.currentOutputDevice?.uid {
                warning("Headphones disconnected. Couldn’t mute \(speaker.name).")
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .lineLimit(2)
            .help(text)
    }

    /// The profile in use, and the others to switch to. Shown only once there
    /// is a second profile.
    private var profileMenu: some View {
        let active = model.profiles.first { $0.id == model.activeProfileID }
        return HeadingMenu(
            label: active?.name ?? "Profile",
            accessibilityLabel: "Profile"
        ) {
            Picker("Profile", selection: Binding(
                get: { model.activeProfileID },
                set: { id in if let id { model.applyProfile(id: id) } }
            )) {
                ForEach(model.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Edit Profiles…", action: showProfiles)
        }
        .frame(maxWidth: 140, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .keyboardHighlight(model.keyboardItem == .profile)
        .help("Switch to another profile")
    }

    /// The current output's hardware icon, so it is clear which device the
    /// slider controls. A generic speaker shows the volume level instead, or
    /// full waves when the device has no volume to show.
    private var outputIcon: String {
        let hardware = model.currentOutputDevice.map {
            $0.hardwareIcon(category: model.activeOutputCategory)
        } ?? (model.activeOutputCategory == .headphone
            ? "headphones"
            : AudioDevice.genericSpeakerIcon)
        guard hardware == AudioDevice.genericSpeakerIcon else { return hardware }
        if !model.isVolumeControllable { return "speaker.wave.3.fill" }
        return switch model.volume {
        case ...0: "speaker.fill"
        case ..<0.33: "speaker.wave.1.fill"
        case ..<0.66: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    /// Why automatic switching chose what it did, shown only when there is
    /// something the lists and the toggle do not already say.
    private var automationNote: String? {
        guard let current = model.currentOutputDevice else { return nil }
        if let uid = model.externalInputUID, let mic = model.currentInputDevice, mic.uid == uid {
            return "Keeping \(mic.name) until it disconnects or you choose another microphone"
        }
        if model.isManualMode {
            return nil
        }
        if model.keptPicks[.output] == current.uid
            || model.currentInputDevice.map({ model.keptPicks[.input] == $0.uid }) == true {
            return "Keeping your choice until a preferred device connects."
        }
        guard let skipped = model.automaticOutputDecision.skipped,
              skipped.device.id != current.id else {
            return nil
        }
        return "Skipping \(skipped.device.name): \(skipped.reason.label)"
    }
}

/// The two channels share the same columns so the device name, mute button
/// and level stay in predictable positions as the route changes.
private struct LevelControl: View {
    let role: DeviceRole
    let device: AudioDevice?
    let icon: String
    let isMuted: Bool
    let level: Float
    let isControllable: Bool
    let canToggleMute: Bool
    let toggleMute: () -> Void
    let setLevel: (Float) -> Void

    private var name: String { role == .input ? "Microphone" : "Output" }
    private var muteTitle: String {
        "\(isMuted ? "Unmute" : "Mute") \(name.lowercased())"
    }
    private var muteIcon: String { role == .input ? "mic.slash.fill" : "speaker.slash.fill" }
    private var value: String { level.formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleMute) {
                Image(systemName: isMuted ? muteIcon : icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(isMuted ? Color.red : .primary)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(device == nil || !canToggleMute)
            .help(muteTitle)
            .accessibilityLabel(muteTitle)
            .accessibilityValue(device?.name ?? "Unavailable")

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(Color.primary.opacity(0.74))
                        .frame(width: 68, alignment: .leading)
                    Text(device?.name ?? "None selected")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(device?.name ?? "None selected")
                    Spacer(minLength: 0)
                    if isMuted {
                        Text("Muted")
                            .font(.callout.weight(.semibold))
                            .fixedSize()
                    }
                }
                .accessibilityElement(children: .combine)

                if device != nil, isControllable {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { Double(level) }, set: { setLevel(Float($0)) }), in: 0...1)
                            .controlSize(.small)
                            .accessibilityLabel(role == .input ? "Microphone input level" : "Output volume")
                            .accessibilityValue("\(value), \(device?.name ?? name)")
                        Text(value)
                            .monospacedDigit()
                            .font(.callout)
                            .foregroundStyle(Color.primary.opacity(0.74))
                            .frame(minWidth: 34, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                } else if device != nil {
                    Text(role == .input ? "Input level unavailable" : "Volume control unavailable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ScrollWheelReceiver { delta in
            guard device != nil, isControllable else { return }
            setLevel(max(0, min(1, level + Float(delta * 0.02))))
        })
    }
}

private struct PanelLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(Highlight(pressed: configuration.isPressed))
    }

    private struct Highlight: ViewModifier {
        var pressed: Bool
        @State private var hovering = false

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 5)
                .background(Color.primary.opacity(pressed ? 0.12 : hovering ? 0.07 : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, -5)
                .onHover { hovering = $0 }
        }
    }
}

private struct ScrollWheelReceiver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollView {
        ScrollView(onScroll: onScroll)
    }

    func updateNSView(_ view: ScrollView, context: Context) {
        view.onScroll = onScroll
    }

    final class ScrollView: NSView {
        var onScroll: (CGFloat) -> Void

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override func scrollWheel(with event: NSEvent) {
            onScroll(event.deltaY)
        }
    }
}

extension View {
    /// The row tint the arrow keys leave on a header or level row, reaching
    /// past it like a device row's highlight without moving anything.
    func keyboardHighlight(_ isOn: Bool) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color.accentColor.opacity(isOn ? 0.12 : 0),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, -8)
            .padding(.vertical, -3)
    }
}

/// Matches the menu bar's own menus: Liquid Glass on macOS 26 and later, and
/// the menu material blurred over whatever is behind the panel before that.
struct PanelBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let cornerRadius: CGFloat = 12

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
                .clipShape(shape)
        } else if #available(macOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(MenuMaterial(cornerRadius: cornerRadius))
                .overlay {
                    shape.stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .clipShape(shape)
        }
    }
}

private struct MenuMaterial: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        // The app remains inactive when this nonactivating panel becomes key,
        // so following the window state would render the material as inactive.
        view.state = .active
        view.maskImage = maskImage
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A clip shape alone leaves the behind-window blur square at the corners.
    private var maskImage: NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}
