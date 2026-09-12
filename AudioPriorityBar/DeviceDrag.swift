import AudioPriorityCore
import SwiftUI

/// One of the panel's three device lists.
enum DeviceSection: Hashable {
    case speaker, headphone, input

    var category: OutputCategory? {
        switch self {
        case .speaker: .speaker
        case .headphone: .headphone
        case .input: nil
        }
    }

    var role: DeviceRole { self == .input ? .input : .output }
}

struct DropTarget: Equatable {
    let section: DeviceSection
    let index: Int
}

/// A row being dragged. Held by the panel rather than a section so the row can
/// be carried into another list.
struct DeviceDrag {
    let device: AudioDevice
    let section: DeviceSection
    let index: Int
    var target: DropTarget?
    var translation: CGSize = .zero
    var isForbidden = false

    mutating func update(
        hovered: DropTarget?,
        translation: CGSize
    ) {
        self.translation = translation
        isForbidden = hovered.map {
            $0.section.role != device.role
        } ?? false
        target = isForbidden ? nil : hovered
    }
}

/// The stacked lists' geometry, derived from the same row metrics the panel
/// lays out with. Computing it instead of measuring keeps the drop target and
/// the panel height in agreement, and avoids a layout-feedback loop where
/// opening a gap would move the rows the target is calculated from.
struct PanelLayout {
    static let space = "deviceLists"
    static let sectionGap: CGFloat = 10
    static let verticalPadding: CGFloat = 8

    let sections: [(section: DeviceSection, count: Int)]

    /// Nearest gap to `y`, measured from the top of a section.
    static func insertionIndex(y: CGFloat, rowCount: Int) -> Int {
        let top = DeviceRowMetrics.sectionHeader + DeviceRowMetrics.spacing
        let gap = ((y - top) / DeviceRowMetrics.pitch).rounded()
        return max(0, min(rowCount, Int(gap)))
    }

    private func height(_ count: Int) -> CGFloat {
        DeviceRowMetrics.sectionHeader
            + CGFloat(max(count, 1)) * DeviceRowMetrics.pitch
    }

    /// An empty list still reserves a placeholder row, so giving up a last
    /// device, or taking a first one, changes no height.
    private func shrink(_ count: Int) -> CGFloat {
        height(max(count - 1, 0)) - height(count)
    }

    private func grow(_ count: Int) -> CGFloat {
        height(count + 1) - height(count)
    }

    var contentHeight: CGFloat {
        let chrome = Self.verticalPadding * 2
            + CGFloat(max(sections.count - 1, 0)) * Self.sectionGap
        return sections.reduce(chrome) { $0 + height($1.count) }
    }

    func sectionTop(of section: DeviceSection) -> CGFloat? {
        var top = Self.verticalPadding
        for entry in sections {
            if entry.section == section { return top }
            top += height(entry.count) + Self.sectionGap
        }
        return nil
    }

    func contentTop(of section: DeviceSection) -> CGFloat? {
        sectionTop(of: section).map {
            $0 + DeviceRowMetrics.sectionHeader + DeviceRowMetrics.spacing
        }
    }

    func sectionOffset(
        for section: DeviceSection,
        drag: DeviceDrag
    ) -> CGFloat {
        guard let target = drag.target,
              target.section != drag.section,
              let sourceIndex = sections.firstIndex(where: {
                  $0.section == drag.section
              }),
              let targetIndex = sections.firstIndex(where: {
                  $0.section == target.section
              }),
              let sectionIndex = sections.firstIndex(where: {
                  $0.section == section
              }) else {
            return 0
        }
        var offset: CGFloat = 0
        if sourceIndex < sectionIndex {
            offset += shrink(sections[sourceIndex].count)
        }
        if targetIndex < sectionIndex {
            offset += grow(sections[targetIndex].count)
        }
        return offset
    }

    /// How much taller the lists become while `drag` previews its drop.
    func heightDelta(for drag: DeviceDrag) -> CGFloat {
        guard let target = drag.target,
              target.section != drag.section,
              let source = sections.first(where: {
                  $0.section == drag.section
              }),
              let destination = sections.first(where: {
                  $0.section == target.section
              }) else {
            return 0
        }
        return shrink(source.count) + grow(destination.count)
    }

    func rowOffset(
        at index: Int,
        in section: DeviceSection,
        drag: DeviceDrag
    ) -> CGFloat {
        guard let target = drag.target else { return 0 }
        var offset: CGFloat = 0
        if drag.section == section, index > drag.index {
            offset -= DeviceRowMetrics.pitch
        }
        if target.section == section, index >= target.index {
            offset += DeviceRowMetrics.pitch
        }
        return offset
    }

    func liftedOffset(for drag: DeviceDrag) -> CGSize {
        guard let target = drag.target,
              let sourceTop = contentTop(of: drag.section),
              let targetTop = contentTop(of: target.section) else {
            return CGSize(width: 0, height: drag.translation.height)
        }
        let sourceY = sourceTop
            + CGFloat(drag.index) * DeviceRowMetrics.pitch
            + sectionOffset(for: drag.section, drag: drag)
        var targetIndex = target.index
        if target.section == drag.section, targetIndex > drag.index {
            targetIndex -= 1
        }
        let targetY = targetTop
            + sectionOffset(for: target.section, drag: drag)
            + CGFloat(targetIndex) * DeviceRowMetrics.pitch
        return CGSize(width: 0, height: targetY - sourceY)
    }

    /// The list and row gap under `point`, before applying device-role rules.
    func target(at point: CGPoint) -> DropTarget? {
        var top = Self.verticalPadding
        for entry in sections {
            let bottom = top + height(entry.count) + Self.sectionGap
            if point.y < bottom {
                return DropTarget(
                    section: entry.section,
                    index: Self.insertionIndex(
                        y: point.y - top,
                        rowCount: entry.count
                    )
                )
            }
            top = bottom
        }
        return nil
    }
}
