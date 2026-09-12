import AudioPriorityCore
import SwiftUI

enum DeviceRowMetrics {
    static let height: CGFloat = 36
    static let spacing: CGFloat = 3
    static let pitch = height + spacing
    static let sectionHeader: CGFloat = 18
}

struct DeviceSectionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: AppModel
    let section: DeviceSection
    let title: String
    let emptyText: String
    let icon: String
    let devices: [AudioDevice]
    let currentID: UInt32?
    let layout: PanelLayout
    @Binding var drag: DeviceDrag?

    private var category: OutputCategory? { section.category }

    private var isTargeted: Bool {
        drag?.target?.section == section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeviceRowMetrics.spacing) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(height: DeviceRowMetrics.sectionHeader, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)

            if devices.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 32)
                    .frame(height: DeviceRowMetrics.height, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.accentColor.opacity(isTargeted ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            } else {
                ForEach(Array(devices.enumerated()), id: \.element.id) {
                    index, device in
                    let lifted = drag?.device.id == device.id
                    DeviceRow(
                        model: model,
                        device: device,
                        index: index,
                        count: devices.count,
                        isSelected: device.isConnected
                            && currentID == device.platformID,
                        category: category,
                        isLifted: lifted,
                        select: { select(device) },
                        move: { target in move(index, target) }
                    )
                    .overlay(alignment: .topTrailing) {
                        if lifted, drag?.isForbidden == true {
                            Image(systemName: "nosign")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(2)
                                .background(.regularMaterial, in: Circle())
                                .offset(x: 5, y: -5)
                                .accessibilityHidden(true)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .offset(offset(index: index, lifted: lifted))
                    .zIndex(lifted ? 1 : 0)
                    .gesture(dragGesture(device: device, index: index))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: drag.map {
            layout.sectionOffset(for: section, drag: $0)
        } ?? 0)
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.25, dampingFraction: 0.8),
            value: drag?.target
        )
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.25, dampingFraction: 0.8),
            value: drag?.device.id
        )
    }

    /// The lifted row snaps into the target gap; the rest close the source gap
    /// and open the destination gap.
    private func offset(index: Int, lifted: Bool) -> CGSize {
        guard let drag else { return .zero }
        if lifted { return layout.liftedOffset(for: drag) }
        return CGSize(
            width: 0,
            height: layout.rowOffset(at: index, in: section, drag: drag)
        )
    }

    private func dragGesture(device: AudioDevice, index: Int) -> some Gesture {
        DragGesture(
            minimumDistance: 8,
            coordinateSpace: .named(PanelLayout.space)
        )
        .onChanged { value in
            var session = drag ?? DeviceDrag(
                device: device,
                section: section,
                index: index
            )
            session.update(
                hovered: layout.target(at: value.location),
                translation: value.translation
            )
            drag = session
        }
        .onEnded { _ in
            if let session = drag, let target = session.target {
                _ = model.dropDevice(
                    session.device.id,
                    into: target.section.category,
                    at: target.index
                )
            }
            drag = nil
        }
    }

    private func select(_ device: AudioDevice) {
        model.selectManually(device)
    }

    private func move(_ source: Int, _ target: Int) {
        guard source != target else { return }
        let destination = target > source ? target + 1 : target
        let offsets = IndexSet(integer: source)
        if let category {
            model.moveOutput(
                in: category,
                from: offsets,
                to: destination
            )
        } else {
            model.moveInput(from: offsets, to: destination)
        }
    }
}
