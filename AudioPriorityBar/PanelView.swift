import AudioPriorityCore
import AppKit
import Combine
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    @Bindable var updates: UpdateChecker
    let showSettings: () -> Void
    let downloadUpdate: () -> Void

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
        (model.speakerDevices + model.headphoneDevices + model.inputDevices)
            .map(\.id)
    }

    /// Only ever grows for a drag, so a preview that adds a row cannot clip the
    /// bottom of the list, and one that removes a row cannot resize the panel
    /// out from under the cursor.
    private var listHeight: CGFloat {
        let growth = max(0, drag.map { layout.heightDelta(for: $0) } ?? 0)
        return min(layout.contentHeight + growth, maximumListHeight)
    }

    private var maximumListHeight: CGFloat {
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        return min(500, max(240, (screen?.visibleFrame.height ?? 900) / 2))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let availableVersion = updates.availableVersion {
                UpdateBanner(
                    version: availableVersion,
                    download: downloadUpdate,
                    dismiss: { updates.dismissThisVersion() }
                )
                Divider().padding(.horizontal, 12)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Automatic switching")
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                    Spacer()
                    Toggle(
                        "Automatic switching",
                        isOn: Binding(
                            get: { !model.isManualMode },
                            set: { model.setManualMode(!$0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .help("Use device priorities as availability changes")
                if let automationNote {
                    Text(automationNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            VStack(spacing: 8) {
                LevelControl(
                    name: "Output",
                    deviceName: model.currentOutputDevice?.name,
                    icon: model.isActiveOutputMuted ? "speaker.slash.fill" : outputIcon,
                    isMuted: model.isActiveOutputMuted,
                    level: model.volume,
                    isControllable: model.isVolumeControllable,
                    toggleMute: { model.setOutputMuted(!model.isActiveOutputMuted) },
                    setLevel: model.setVolume
                )
                if model.currentInputID != nil {
                    LevelControl(
                        name: "Microphone",
                        deviceName: model.currentInputDevice?.name,
                        icon: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                        isMuted: model.isMicrophoneMuted,
                        level: model.microphoneLevel,
                        isControllable: model.isMicrophoneLevelControllable,
                        toggleMute: { model.setMicrophoneMuted(!model.isMicrophoneMuted) },
                        setLevel: model.setMicrophoneLevel
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 12)

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

            Divider().padding(.horizontal, 12)
            Footer(model: model, showSettings: showSettings)
        }
        .frame(width: 380)
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
    }

    /// The current output's hardware icon, so it is clear which device the
    /// slider controls. A generic speaker shows the volume level instead.
    private var outputIcon: String {
        if !model.isVolumeControllable { return "speaker.wave.3.fill" }
        let hardware = model.currentOutputDevice.map {
            $0.hardwareIcon(category: model.activeOutputCategory)
        } ?? (model.activeOutputCategory == .headphone
            ? "headphones"
            : AudioDevice.genericSpeakerIcon)
        guard hardware == AudioDevice.genericSpeakerIcon else { return hardware }
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
        guard let current = model.currentOutputDevice else {
            return "No output selected"
        }
        if model.isManualMode {
            return "Your choice stays until you turn this on"
        }
        guard let skipped = model.automaticOutputDecision.skipped,
              skipped.device.id != current.id else {
            return nil
        }
        let reason = switch skipped.reason {
        case .off: "headset off"
        case .neverAutoSelect: "never auto-selected"
        }
        return "Skipping \(skipped.device.name): \(reason)"
    }
}

/// One row for the current output or microphone: the icon mutes, the slider
/// sets the level. Both rows share it so they look and behave alike.
private struct LevelControl: View {
    private static let buttonSize: CGFloat = 26
    private static let spacing: CGFloat = 10

    let name: String
    /// The device the row controls, named in the tooltip and for VoiceOver
    /// rather than taking a line of its own.
    let deviceName: String?
    let icon: String
    let isMuted: Bool
    let level: Float
    let isControllable: Bool
    let toggleMute: () -> Void
    let setLevel: (Float) -> Void

    @State private var isHoveringMute = false

    var body: some View {
        HStack(spacing: Self.spacing) {
            Button(action: toggleMute) {
                Image(systemName: icon)
                    .foregroundStyle(isMuted ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .background(Circle().fill(muteBackground))
                    .contentShape(Circle())
                    .animation(.easeInOut(duration: 0.15), value: icon)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringMute = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHoveringMute)
            .help(muteTitle)
            .accessibilityLabel(muteTitle)
            Slider(
                value: Binding(
                    get: { Double(level) },
                    set: { setLevel(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .disabled(!isControllable)
            .opacity(isMuted ? 0.5 : 1)
            .help(deviceName ?? name)
            .accessibilityLabel("\(name) volume")
            .accessibilityValue(valueDescription)
            // Sized to the widest value, so it sits close to the slider
            // without the slider resizing as the digits change.
            ZStack(alignment: .leading) {
                Text("100%").hidden()
                Text(isControllable ? "\(Int(level * 100))%" : "—")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.leading, 6 - Self.spacing)
            .accessibilityHidden(true)
        }
        .background(ScrollWheelReceiver { delta in
            guard isControllable else { return }
            setLevel(max(0, min(1, level + Float(delta * 0.02))))
        })
    }

    private var muteTitle: String {
        "\(isMuted ? "Unmute" : "Mute") \(deviceName ?? name)"
    }

    /// Always filled so the icon reads as a button, and tinted while muted.
    private var muteBackground: AnyShapeStyle {
        isMuted
            ? AnyShapeStyle(Color.red.opacity(isHoveringMute ? 0.3 : 0.2))
            : AnyShapeStyle(Color.primary.opacity(isHoveringMute ? 0.16 : 0.08))
    }

    private var valueDescription: String {
        var values = [isControllable ? "\(Int(level * 100)) percent" : "Unavailable"]
        if isMuted { values.insert("Muted", at: 0) }
        if let deviceName { values.append(deviceName) }
        return values.joined(separator: ", ")
    }
}

/// Shown at the top of the panel, the most-opened surface in the app, so an
/// available update is obvious without visiting Settings or the right-click
/// menu.
private struct UpdateBanner: View {
    let version: String
    let download: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Version \(version) is available")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Download", action: download)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)
            .help("Dismiss until next launch")
            .accessibilityLabel("Dismiss version \(version) until next launch")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }
}

private struct Footer: View {
    @Bindable var model: AppModel
    let showSettings: () -> Void

    @State private var isHoveringSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Toggle(
                "Show hidden and disconnected devices",
                isOn: Binding(
                    get: { model.showAll },
                    set: {
                        model.showAll = $0
                        model.refreshDevices()
                    }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 12)

            Divider().padding(.horizontal, 12)

            Button(action: showSettings) {
                // A plain button only hits its visible pixels, so give the
                // label the whole row to click.
                Text("Audio Priority Bar Settings…")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(
                        Color.primary.opacity(isHoveringSettings ? 0.1 : 0),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringSettings = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHoveringSettings)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
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

/// Matches the menu bar's own menus: Liquid Glass on macOS 26 and later, and
/// the menu material blurred over whatever is behind the panel before that.
private struct PanelBackground: ViewModifier {
    private let cornerRadius: CGFloat = 12

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
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
