import SwiftUI
import AppKit

// A compact always-on-top network widget with multiple visual skins.
struct NetworkOverlayView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        // All skins share the same data model, but each style chooses a different density
        // and icon hierarchy.
        layoutView
        .padding(containerPadding)
        .background(backgroundLayer)
        .overlay(borderLayer)
        .shadow(color: shadowColor, radius: 12, x: 0, y: 8)
        .fixedSize()
    }

    @ViewBuilder
    private var layoutView: some View {
        switch monitor.networkOverlaySettings.style {
            case .compact:
                HStack(spacing: itemSpacing) {
                    ForEach(entries) { entry in
                        compactBadge(entry)
                    }
                }
            case .stacked:
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        stackedBadge(entry)
                    }
                }
            case .split:
                HStack(spacing: 8) {
                    ForEach(entries) { entry in
                        splitBadge(entry)
                    }
                }
            case .minimal:
                HStack(spacing: minimalSpacing) {
                    ForEach(entries) { entry in
                        minimalBadge(entry)
                    }
                }
            case .capsule:
                VStack(spacing: 6) {
                    ForEach(entries) { entry in
                        capsuleBadge(entry)
                    }
                }
            case .hud:
                HStack(spacing: hudSpacing) {
                    ForEach(entries) { entry in
                        hudBadge(entry)
                    }
                }
        }
    }

    private func compactBadge(_ entry: OverlayEntry) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(entry.tint.opacity(0.18))
                    .frame(width: iconBoxSize, height: iconBoxSize)
                Image(systemName: entry.icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(entry.tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label)
                    .font(.system(size: compactLabelSize, weight: .bold, design: .monospaced))
                    .foregroundColor(labelColor)
                Text(entry.value)
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .foregroundColor(valueColor)
            }
        }
        .frame(width: badgeWidth, alignment: .leading)
    }

    private func stackedBadge(_ entry: OverlayEntry) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(entry.tint)
                .frame(width: dotSize, height: dotSize)
            Text(entry.label)
                .font(.system(size: stackedLabelSize, weight: .semibold, design: .monospaced))
                .foregroundColor(labelColor)
            Spacer(minLength: 8)
            Text(entry.value)
                .font(.system(size: stackedValueSize, weight: .semibold, design: .rounded))
                .foregroundColor(valueColor)
        }
        .frame(width: stackedWidth, alignment: .leading)
    }

    private func splitBadge(_ entry: OverlayEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry.icon)
                    .font(.system(size: iconSize - 1, weight: .semibold))
                    .foregroundColor(entry.tint)
                Text(entry.label)
                    .font(.system(size: labelSize, weight: .semibold, design: .monospaced))
                    .foregroundColor(labelColor)
            }
            Text(entry.value)
                .font(.system(size: valueSize + 2, weight: .bold, design: .rounded))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: splitWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(monitor.networkOverlaySettings.style == .split ? 0.06 : 0.0))
        )
    }

    private func minimalBadge(_ entry: OverlayEntry) -> some View {
        HStack(spacing: 6) {
            Text(entry.label)
                .font(.system(size: minimalLabelSize, weight: .bold, design: .monospaced))
                .foregroundColor(entry.tint)
            Text(entry.value)
                .font(.system(size: minimalValueSize, weight: .bold, design: .rounded))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func capsuleBadge(_ entry: OverlayEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(entry.tint)
            Text(entry.label)
                .font(.system(size: capsuleLabelSize, weight: .bold, design: .monospaced))
                .foregroundColor(labelColor)
            Spacer(minLength: 6)
            Text(entry.value)
                .font(.system(size: capsuleValueSize, weight: .bold, design: .rounded))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: capsuleWidth, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(entry.tint.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(entry.tint.opacity(0.28), lineWidth: 1)
        )
    }

    private func hudBadge(_ entry: OverlayEntry) -> some View {
        HStack(spacing: 4) {
            Text(hudLabel(for: entry))
                .font(.system(size: hudLabelSize, weight: .black, design: .monospaced))
                .foregroundColor(entry.tint)
                .frame(width: hudLabelWidth, alignment: .leading)
            Text(entry.value)
                .font(.system(size: hudValueSize, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.8)
                .frame(width: hudValueWidth, alignment: .trailing)
        }
        .padding(.horizontal, hudHorizontalPadding)
        .padding(.vertical, hudVerticalPadding)
        .frame(width: hudWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(entry.tint.opacity(0.45), lineWidth: 1)
        )
    }

    private func hudLabel(for entry: OverlayEntry) -> String {
        switch entry.id {
            case "upload":
                return "↑"
            case "download":
                return "↓"
            default:
                return entry.label
        }
    }

    private func formatCompactRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 {
            return "0K"
        }
        let units = ["B", "K", "M", "G"]
        var value = max(bytesPerSecond, 0)
        var unitIndex = 0

        while value >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "0K"
        }
        let unit = units[unitIndex]
        if value >= 100 {
            return String(format: "%.0f%@", value, unit)
        }
        if value >= 10 {
            return String(format: "%.0f%@", value, unit)
        }
        return String(format: "%.1f%@", value, unit)
    }

    private var entries: [OverlayEntry] {
        var result: [OverlayEntry] = []
        if monitor.networkOverlaySettings.showsUpload {
            result.append(
                OverlayEntry(
                    id: "upload",
                    icon: entryIcon(for: .upload),
                    label: "UP",
                    value: formatCompactRate(monitor.networkThroughput.uploadBytesPerSecond),
                    tint: Color(red: 0.98, green: 0.72, blue: 0.28)
                )
            )
        }
        if monitor.networkOverlaySettings.showsDownload {
            result.append(
                OverlayEntry(
                    id: "download",
                    icon: entryIcon(for: .download),
                    label: "DOWN",
                    value: formatCompactRate(monitor.networkThroughput.downloadBytesPerSecond),
                    tint: Color(red: 0.38, green: 0.84, blue: 1.0)
                )
            )
        }
        return result
    }

    private func entryIcon(for direction: NetworkDisplayMode) -> String {
        switch (monitor.networkOverlaySettings.style, direction) {
            case (.stacked, .upload), (.capsule, .upload):
                return "arrow.up"
            case (.stacked, .download), (.capsule, .download):
                return "arrow.down"
            case (.minimal, .upload):
                return "arrowtriangle.up.fill"
            case (.minimal, .download):
                return "arrowtriangle.down.fill"
            case (_, .upload):
                return "arrow.up.right"
            case (_, .download):
                return "arrow.down.left"
            case (_, .total):
                return "network"
        }
    }

    private var badgeWidth: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 72
            case .regular: return 78
            case .large: return 86
        }
    }

    private var splitWidth: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 70
            case .regular: return 78
            case .large: return 88
        }
    }

    private var stackedWidth: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 104
            case .regular: return 114
            case .large: return 126
        }
    }

    private var capsuleWidth: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 134
            case .regular: return 146
            case .large: return 160
        }
    }

    private var hudWidth: CGFloat {
        hudLabelWidth + 4 + hudValueWidth + hudHorizontalPadding * 2
    }

    private var hudLabelWidth: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 8
            case .regular: return 10
            case .large: return 12
        }
    }

    private var hudValueWidth: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 36
            case .regular: return 42
            case .large: return 50
        }
    }

    private var hudHorizontalPadding: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 5
            case .regular: return 6
            case .large: return 7
        }
    }

    private var hudVerticalPadding: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 4
            case .regular: return 5
            case .large: return 6
        }
    }

    private var itemSpacing: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 6
            case .regular: return 8
            case .large: return 10
        }
    }

    private var hudSpacing: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 6
            case .regular: return 7
            case .large: return 8
        }
    }

    private var minimalSpacing: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 6
            case .regular: return 7
            case .large: return 8
        }
    }

    private var containerPadding: EdgeInsets {
        switch monitor.networkOverlaySettings.style {
            case .stacked:
                return EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
            case .hud:
                return EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7)
            case .compact, .split, .minimal, .capsule:
                return EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        }
    }

    private var iconBoxSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 20
            case .regular: return 22
            case .large: return 26
        }
    }

    private var iconSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 8
            case .regular: return 9
            case .large: return 10
        }
    }

    private var labelSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 9
            case .regular: return 10
            case .large: return 11
        }
    }

    private var compactLabelSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 10.5
            case .regular: return 11.5
            case .large: return 12.5
        }
    }

    private var minimalLabelSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 10
            case .regular: return 11
            case .large: return 12
        }
    }

    private var capsuleLabelSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 10
            case .regular: return 11
            case .large: return 12
        }
    }

    private var valueSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 12
            case .regular: return 13
            case .large: return 15
        }
    }

    private var dotSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 8
            case .regular: return 9
            case .large: return 10
        }
    }

    private var stackedLabelSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 11.5
            case .regular: return 12.5
            case .large: return 13.5
        }
    }

    private var stackedValueSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 13
            case .regular: return 14
            case .large: return 16
        }
    }

    private var minimalValueSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 14
            case .regular: return 15
            case .large: return 17
        }
    }

    private var capsuleValueSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 13
            case .regular: return 14
            case .large: return 16
        }
    }

    private var hudLabelSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 10.5
            case .regular: return 12
            case .large: return 13.5
        }
    }

    private var hudValueSize: CGFloat {
        switch monitor.networkOverlaySettings.size {
            case .compact: return 11.5
            case .regular: return 13
            case .large: return 14.5
        }
    }

    private var cornerRadius: CGFloat {
        switch monitor.networkOverlaySettings.style {
            case .compact, .minimal: return 16
            case .stacked, .split: return 18
            case .capsule: return 20
            case .hud: return 10
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        switch monitor.networkOverlaySettings.style {
            case .compact:
                return AnyShapeStyle(Color.black.opacity(0.76))
            case .stacked:
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [Color(red: 0.17, green: 0.18, blue: 0.20), Color(red: 0.11, green: 0.12, blue: 0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            case .split:
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.09, blue: 0.11), Color(red: 0.12, green: 0.13, blue: 0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            case .minimal:
                return AnyShapeStyle(Color.black.opacity(0.62))
            case .capsule:
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.11, blue: 0.13), Color(red: 0.15, green: 0.10, blue: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            case .hud:
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [Color.black.opacity(0.42), Color(red: 0.06, green: 0.08, blue: 0.10).opacity(0.68)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }

    private var borderColor: Color {
        switch monitor.networkOverlaySettings.style {
            case .compact: return Color.white.opacity(0.08)
            case .stacked: return Color.white.opacity(0.10)
            case .split: return Color.white.opacity(0.12)
            case .minimal: return Color.white.opacity(0.05)
            case .capsule: return Color.white.opacity(0.10)
            case .hud: return Color.white.opacity(0.08)
        }
    }

    private var shadowColor: Color {
        switch monitor.networkOverlaySettings.style {
            case .stacked: return Color.black.opacity(0.18)
            case .minimal: return Color.black.opacity(0.14)
            case .hud: return Color.black.opacity(0.18)
            default: return Color.black.opacity(0.24)
        }
    }

    private var labelColor: Color {
        switch monitor.networkOverlaySettings.style {
            case .split, .capsule: return Color.white.opacity(0.74)
            case .minimal: return Color.white.opacity(0.82)
            case .hud: return Color.white.opacity(0.86)
            default: return Color.white.opacity(0.56)
        }
    }

    private var valueColor: Color {
        .white
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if monitor.networkOverlaySettings.style == .hud {
            EmptyView()
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundStyle)
        }
    }

    @ViewBuilder
    private var borderLayer: some View {
        if monitor.networkOverlaySettings.style == .hud {
            EmptyView()
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }
}

private struct OverlayEntry: Identifiable {
    let id: String
    let icon: String
    let label: String
    let value: String
    let tint: Color
}

final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: ((NSEvent, NSView) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event, self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}
