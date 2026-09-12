import AudioPriorityCore
import AppKit
import Combine
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    let showSettings: () -> Void

    /// Held here rather than per section so a row can be dragged between lists.
    @State private var drag: DeviceDrag?

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
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Automatic switching",
                    isOn: Binding(
                        get: { !model.isManualMode },
                        set: { model.setManualMode(!$0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Use device priorities as availability changes")
                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                VolumeControl(model: model)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))

            Divider().padding(.horizontal, 10)

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
                        icon: "speaker.wave.2.fill",
                        devices: model.speakerDevices,
                        currentID: model.currentOutputID,
                        layout: layout,
                        drag: $drag
                    )
                    .zIndex(drag?.section == .speaker ? 1 : 0)
                    DeviceSectionView(
                        model: model,
                        section: .headphone,
                        title: "Headphones",
                        emptyText: "No headphones shown",
                        icon: "headphones",
                        devices: model.headphoneDevices,
                        currentID: model.currentOutputID,
                        layout: layout,
                        drag: $drag
                    )
                    .zIndex(drag?.section == .headphone ? 1 : 0)
                    DeviceSectionView(
                        model: model,
                        section: .input,
                        title: "Microphones",
                        emptyText: "No microphones shown",
                        icon: "mic.fill",
                        devices: model.inputDevices,
                        currentID: model.currentInputID,
                        layout: layout,
                        drag: $drag
                    )
                    .zIndex(drag?.section == .input ? 1 : 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, PanelLayout.verticalPadding)
                .coordinateSpace(name: PanelLayout.space)
            }
            .frame(height: listHeight)

            Divider().padding(.horizontal, 10)
            Footer(model: model, showSettings: showSettings)
        }
        .frame(width: 380)
        .onChange(of: renderedDeviceIDs) { _, ids in
            if let drag, !ids.contains(drag.device.id) {
                self.drag = nil
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
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var modeDescription: String {
        guard let current = model.currentOutputDevice else {
            return "No output selected"
        }
        if model.isManualMode {
            return "Using \(current.name) manually"
        }
        guard let skipped = model.automaticOutputDecision.skipped,
              skipped.device.id != current.id else {
            return "Using \(current.name)"
        }
        let reason = switch skipped.reason {
        case .off: "is off"
        case .neverAutoSelect: "is excluded from automatic switching"
        }
        return "Using \(current.name) · \(skipped.device.name) \(reason)"
    }
}

private struct VolumeControl: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
                .animation(.easeInOut(duration: 0.15), value: icon)
            Slider(
                value: Binding(
                    get: { Double(model.volume) },
                    set: { model.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .disabled(!model.isVolumeControllable)
            .accessibilityLabel("Output volume")
            .accessibilityValue(valueDescription)
            Text(
                model.isVolumeControllable
                    ? "\(Int(model.volume * 100))%"
                    : "—"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .background(ScrollWheelReceiver { delta in
            guard model.isVolumeControllable else { return }
            model.setVolume(max(0, min(1, model.volume + Float(delta * 0.02))))
        })
    }

    private var icon: String {
        if !model.isVolumeControllable { return "speaker.wave.3.fill" }
        if model.activeOutputCategory == .headphone {
            return "headphones"
        }
        return switch model.volume {
        case ...0: "speaker.fill"
        case ..<0.33: "speaker.wave.1.fill"
        case ..<0.66: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private var valueDescription: String {
        model.isVolumeControllable
            ? "\(Int(model.volume * 100)) percent"
            : "Unavailable"
    }
}

private struct Footer: View {
    @Bindable var model: AppModel
    let showSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "Show all",
                isOn: Binding(
                    get: { model.showAll },
                    set: {
                        model.showAll = $0
                        model.refreshDevices()
                    }
                )
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Show devices that are excluded or disconnected")

            Spacer()

            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help("Open settings")
            .accessibilityLabel("Settings")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
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
