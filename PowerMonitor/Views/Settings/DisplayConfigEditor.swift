import SwiftUI
import AppKit

// This editor keeps the menu-bar item arrangement lightweight enough to live inside NSMenu.
final class DisplayConfigEditorModel: ObservableObject {
    @Published var visibleMetrics: [MonitorMetric]
    @Published var hiddenMetrics: [MonitorMetric]
    @Published private(set) var draggedMetric: MonitorMetric?
    var onCommit: (([MonitorMetric], [MonitorMetric]) -> Void)?

    init(visibleMetrics: [MonitorMetric], hiddenMetrics: [MonitorMetric]) {
        self.visibleMetrics = visibleMetrics
        self.hiddenMetrics = hiddenMetrics
    }

    func beginDrag(metric: MonitorMetric) {
        draggedMetric = metric
    }

    // Convert the final horizontal drag position into a destination column and insertion slot.
    func finishDrag(metric: MonitorMetric, sourceColumn: DisplayColumn, translationX: CGFloat, itemWidth: CGFloat, gapWidth: CGFloat) {
        guard draggedMetric == metric else { return }
        let sourceMetrics = sourceColumn == .visible ? visibleMetrics : hiddenMetrics
        guard let sourceIndex = sourceMetrics.firstIndex(of: metric) else { return }

        let baseOriginX = originX(for: sourceColumn, index: sourceIndex, itemWidth: itemWidth, gapWidth: gapWidth)
        let draggedRect = CGRect(x: baseOriginX + translationX, y: 0, width: itemWidth, height: 22)

        let visibleWithoutDragged = visibleMetrics.filter { $0 != metric }
        let hiddenWithoutDragged = hiddenMetrics.filter { $0 != metric }
        let currentVisibleWidth = width(for: visibleWithoutDragged, itemWidth: itemWidth)

        let visibleCandidates = candidateSlots(
            for: .visible,
            metrics: visibleWithoutDragged,
            itemWidth: itemWidth,
            originX: 0
        )
        let hiddenCandidates = candidateSlots(
            for: .hidden,
            metrics: hiddenWithoutDragged,
            itemWidth: itemWidth,
            originX: currentVisibleWidth + gapWidth
        )
        let candidates = visibleCandidates + hiddenCandidates

        // Decide which column the drop most likely targets before choosing a slot.
        let hiddenColumnStartX = currentVisibleWidth + gapWidth
        let preferredColumn: DisplayColumn = draggedRect.midX >= hiddenColumnStartX ? .hidden : .visible
        let preferredCandidates = candidates.filter { $0.column == preferredColumn }
        let best = bestCandidate(for: draggedRect, among: preferredCandidates.isEmpty ? candidates : preferredCandidates)
        guard let best else {
            endDrag()
            return
        }

        applyPlacement(metric: metric, targetColumn: best.column, targetIndex: best.index)
        onCommit?(visibleMetrics, hiddenMetrics)
        endDrag()
    }

    func endDrag() {
        draggedMetric = nil
    }

    private func width(for metrics: [MonitorMetric], itemWidth: CGFloat) -> CGFloat {
        if metrics.isEmpty {
            return itemWidth
        }
        let spacing: CGFloat = 8
        return CGFloat(metrics.count) * itemWidth + CGFloat(max(0, metrics.count - 1)) * spacing
    }

    private func originX(for column: DisplayColumn, index: Int, itemWidth: CGFloat, gapWidth: CGFloat) -> CGFloat {
        let stride = itemWidth + 8
        switch column {
            case .visible:
                return CGFloat(index) * stride
            case .hidden:
                let leftWidth = width(for: visibleMetrics, itemWidth: itemWidth)
                return leftWidth + gapWidth + CGFloat(index) * stride
        }
    }

    // Slot rectangles represent insertion targets rather than existing chip frames, which
    // keeps dropping into empty columns predictable.
    private func candidateSlots(for column: DisplayColumn, metrics: [MonitorMetric], itemWidth: CGFloat, originX: CGFloat) -> [SlotCandidate] {
        let stride = itemWidth + 8
        if metrics.isEmpty {
            return [
                SlotCandidate(
                    column: column,
                    index: 0,
                    rect: CGRect(x: originX, y: 0, width: itemWidth, height: 22)
                )
            ]
        }

        return (0...metrics.count).map { index in
            let centerX: CGFloat
            if index == 0 {
                centerX = originX + itemWidth / 2
            } else if index == metrics.count {
                centerX = originX + CGFloat(metrics.count) * stride - stride / 2 + itemWidth / 2
            } else {
                let previousCenter = originX + CGFloat(index - 1) * stride + itemWidth / 2
                let nextCenter = originX + CGFloat(index) * stride + itemWidth / 2
                centerX = (previousCenter + nextCenter) / 2
            }

            let slotWidth = stride
            return SlotCandidate(
                column: column,
                index: index,
                rect: CGRect(x: centerX - slotWidth / 2, y: 0, width: slotWidth, height: 22)
            )
        }
    }

    private func overlapWidth(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    }

    private func bestCandidate(for draggedRect: CGRect, among candidates: [SlotCandidate]) -> SlotCandidate? {
        guard !candidates.isEmpty else { return nil }
        let overlaps = candidates.map { (candidate: $0, overlap: overlapWidth(draggedRect, $0.rect)) }
        let maxOverlap = overlaps.map(\.overlap).max() ?? 0
        if maxOverlap > 0 {
            return overlaps.max {
                if $0.overlap == $1.overlap {
                    return abs($0.candidate.rect.midX - draggedRect.midX) > abs($1.candidate.rect.midX - draggedRect.midX)
                }
                return $0.overlap < $1.overlap
            }?.candidate
        }

        return candidates.min {
            abs($0.rect.midX - draggedRect.midX) < abs($1.rect.midX - draggedRect.midX)
        }
    }

    private func applyPlacement(metric: MonitorMetric, targetColumn: DisplayColumn, targetIndex: Int) {
        if targetColumn == .hidden, visibleMetrics.count == 1, visibleMetrics.contains(metric) {
            return
        }

        visibleMetrics.removeAll { $0 == metric }
        hiddenMetrics.removeAll { $0 == metric }

        switch targetColumn {
            case .visible:
                let insertIndex = max(0, min(visibleMetrics.count, targetIndex))
                visibleMetrics.insert(metric, at: insertIndex)
            case .hidden:
                let insertIndex = max(0, min(hiddenMetrics.count, targetIndex))
                hiddenMetrics.insert(metric, at: insertIndex)
        }
    }
}

private struct SlotCandidate {
    let column: DisplayColumn
    let index: Int
    let rect: CGRect
}

struct InlineDisplayConfigEditor: View {
    @ObservedObject var model: DisplayConfigEditorModel
    private let chipWidth: CGFloat = 46
    private let dividerWidth: CGFloat = 6
    private let columnSpacing: CGFloat = 8

    var body: some View {
        // This editor lives inside NSMenu, so it favors a compact horizontal interaction
        // over a larger window-based organizer.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: columnSpacing) {
                HorizontalChipRow(
                    metrics: model.visibleMetrics,
                    column: .visible,
                    draggedMetric: model.draggedMetric,
                    chipWidth: chipWidth,
                    onDragBegan: { metric in
                        model.beginDrag(metric: metric)
                    },
                    onDragEnded: { metric, translationX in
                        model.finishDrag(
                            metric: metric,
                            sourceColumn: .visible,
                            translationX: translationX,
                            itemWidth: chipWidth,
                            gapWidth: dividerWidth + columnSpacing * 2
                        )
                    }
                )

                DividerChipView()

                HorizontalChipRow(
                    metrics: model.hiddenMetrics,
                    column: .hidden,
                    draggedMetric: model.draggedMetric,
                    chipWidth: chipWidth,
                    onDragBegan: { metric in
                        model.beginDrag(metric: metric)
                    },
                    onDragEnded: { metric, translationX in
                        model.finishDrag(
                            metric: metric,
                            sourceColumn: .hidden,
                            translationX: translationX,
                            itemWidth: chipWidth,
                            gapWidth: dividerWidth + columnSpacing * 2
                        )
                    }
                )
            }
            .padding(.horizontal, 8)
        }
        .frame(width: 468, height: 38, alignment: .leading)
    }

    private func width(for metrics: [MonitorMetric]) -> CGFloat {
        if metrics.isEmpty {
            return chipWidth
        }
        return CGFloat(metrics.count) * chipWidth + CGFloat(max(0, metrics.count - 1)) * 8
    }
}

struct DisplayConfigPanelView: View {
    @ObservedObject var model: DisplayConfigEditorModel

    var body: some View {
        VStack(spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    labelChip(title: "Visible", icon: "eye")
                    Spacer()
                    labelChip(title: "Hidden", icon: "eye.slash")
                }
                InlineDisplayConfigEditor(model: model)
            }
            .frame(maxWidth: 468)

            Text("Drag chips to reorder or hide them.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .frame(maxWidth: 280)
        }
        .frame(width: 504, height: 190, alignment: .top)
    }

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.18),
                                Color.mint.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                Image(systemName: "rectangle.3.group.bubble.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.accentColor)
            }

            Text("Configure Display Items")
                .font(.system(size: 15, weight: .semibold))

            Text("Choose which metrics stay in the menu bar.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
    }

    private func labelChip(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

enum DisplayColumn {
    case visible
    case hidden
}

private struct HorizontalChipRow: View {
    let metrics: [MonitorMetric]
    let column: DisplayColumn
    let draggedMetric: MonitorMetric?
    let chipWidth: CGFloat
    let onDragBegan: (MonitorMetric) -> Void
    let onDragEnded: (MonitorMetric, CGFloat) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if metrics.isEmpty {
                EmptyChipPlaceholder(width: chipWidth, column: column)
            } else {
                ForEach(metrics, id: \.self) { metric in
                    DraggableMetricChip(
                        metric: metric,
                        chipWidth: chipWidth,
                        isGhosted: draggedMetric == metric,
                        onDragBegan: onDragBegan,
                        onDragEnded: onDragEnded
                    )
                }
            }
        }
        .frame(minWidth: column == .hidden ? 56 : chipWidth, alignment: .leading)
    }
}

private struct DraggableMetricChip: View {
    let metric: MonitorMetric
    let chipWidth: CGFloat
    let isGhosted: Bool
    let onDragBegan: (MonitorMetric) -> Void
    let onDragEnded: (MonitorMetric, CGFloat) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var hasBegun = false

    var body: some View {
        MetricChipView(metric: metric)
            .opacity(isGhosted ? 0.35 : 1.0)
            .offset(dragOffset)
            .scaleEffect(dragOffset == .zero ? 1.0 : 1.04)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: dragOffset)
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if !hasBegun {
                            hasBegun = true
                            onDragBegan(metric)
                        }
                        dragOffset = value.translation
                    }
                    .onEnded { _ in
                        let finalX = dragOffset.width
                        dragOffset = .zero
                        hasBegun = false
                        onDragEnded(metric, finalX)
                    }
            )
    }
}

private struct MetricChipView: View {
    let metric: MonitorMetric

    var body: some View {
        Text(metric.shortTitle.lowercased())
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
    }
}

private struct EmptyChipPlaceholder: View {
    let width: CGFloat
    let column: DisplayColumn

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: column == .hidden ? "eye.slash" : "eye")
                .font(.system(size: 9, weight: .semibold))
            if column == .hidden {
                Text("hide")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
        }
        .foregroundColor(.secondary.opacity(0.75))
        .frame(width: max(width, column == .hidden ? 56 : width), height: 22)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

private struct DividerChipView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 6, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}
