import SwiftUI
import AppKit

// Shared settings sheet UI used by the interval and threshold editors.
final class ThresholdEditorModel: ObservableObject {
    private let sourceThresholds: MetricThresholds
    @Published var diskSpeedYellow: String
    @Published var diskSpeedRed: String
    @Published var diskUsageYellow: String
    @Published var diskUsageRed: String
    @Published var cpuYellow: String
    @Published var cpuRed: String
    @Published var gpuYellow: String
    @Published var gpuRed: String
    @Published var powerYellow: String
    @Published var powerRed: String
    @Published var fanYellow: String
    @Published var fanRed: String
    @Published var networkYellow: String
    @Published var networkRed: String

    init(thresholds: MetricThresholds) {
        sourceThresholds = thresholds
        diskSpeedYellow = Self.formatMB(thresholds.diskYellow)
        diskSpeedRed = Self.formatMB(thresholds.diskRed)
        diskUsageYellow = Self.format(thresholds.diskUsageYellow)
        diskUsageRed = Self.format(thresholds.diskUsageRed)
        cpuYellow = Self.format(thresholds.cpuYellow)
        cpuRed = Self.format(thresholds.cpuRed)
        gpuYellow = Self.format(thresholds.gpuYellow)
        gpuRed = Self.format(thresholds.gpuRed)
        powerYellow = Self.format(thresholds.powerYellow)
        powerRed = Self.format(thresholds.powerRed)
        fanYellow = Self.format(thresholds.fanYellow)
        fanRed = Self.format(thresholds.fanRed)
        networkYellow = Self.formatMB(thresholds.networkYellow)
        networkRed = Self.formatMB(thresholds.networkRed)
    }

    func makeThresholds() -> MetricThresholds {
        MetricThresholds(
            diskYellow: Self.parse(diskSpeedYellow, fallback: MetricThresholds.defaults.diskYellow / 1_000_000) * 1_000_000,
            diskRed: Self.parse(diskSpeedRed, fallback: MetricThresholds.defaults.diskRed / 1_000_000) * 1_000_000,
            diskUsageYellow: Self.parse(diskUsageYellow, fallback: MetricThresholds.defaults.diskUsageYellow),
            diskUsageRed: Self.parse(diskUsageRed, fallback: MetricThresholds.defaults.diskUsageRed),
            cpuYellow: Self.parse(cpuYellow, fallback: MetricThresholds.defaults.cpuYellow),
            cpuRed: Self.parse(cpuRed, fallback: MetricThresholds.defaults.cpuRed),
            gpuYellow: Self.parse(gpuYellow, fallback: MetricThresholds.defaults.gpuYellow),
            gpuRed: Self.parse(gpuRed, fallback: MetricThresholds.defaults.gpuRed),
            ramYellow: sourceThresholds.ramYellow,
            ramRed: sourceThresholds.ramRed,
            powerYellow: Self.parse(powerYellow, fallback: MetricThresholds.defaults.powerYellow),
            powerRed: Self.parse(powerRed, fallback: MetricThresholds.defaults.powerRed),
            fanYellow: Self.parse(fanYellow, fallback: MetricThresholds.defaults.fanYellow),
            fanRed: Self.parse(fanRed, fallback: MetricThresholds.defaults.fanRed),
            networkYellow: Self.parse(networkYellow, fallback: MetricThresholds.defaults.networkYellow / 1_000_000) * 1_000_000,
            networkRed: Self.parse(networkRed, fallback: MetricThresholds.defaults.networkRed / 1_000_000) * 1_000_000
        )
    }

    private static func format(_ value: Double) -> String {
        String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }

    private static func formatMB(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f", bytesPerSecond / 1_000_000)
    }

    private static func parse(_ value: String, fallback: Double) -> Double {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }
}

struct SettingsPanelContainer<Content: View>: View {
    let saveTitle: String
    let onCancel: () -> Void
    let onSave: () -> Void
    let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Rectangle()
                .fill(Color.secondary.opacity(0.14))
                .frame(height: 1)
                .padding(.horizontal, 18)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button(saveTitle, action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(NSColor.windowBackgroundColor),
                            Color(NSColor.controlBackgroundColor).opacity(0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .padding(10)
        .background(Color.clear)
    }
}

struct ThresholdEditorView: View {
    @ObservedObject var model: ThresholdEditorModel

    var body: some View {
        VStack(spacing: 14) {
            header

            ThresholdHeaderRow()
                .frame(maxWidth: 360)

            // Keep this scrollable so adding future metrics does not force a larger window.
            ScrollView {
                VStack(spacing: 10) {
                    ThresholdRow(title: "SSD Usage", subtitle: "%", yellow: $model.diskUsageYellow, red: $model.diskUsageRed)
                    ThresholdRow(title: "SSD Speed", subtitle: "MB/s", yellow: $model.diskSpeedYellow, red: $model.diskSpeedRed)
                    ThresholdRow(title: "CPU", subtitle: "%", yellow: $model.cpuYellow, red: $model.cpuRed)
                    ThresholdRow(title: "GPU", subtitle: "%", yellow: $model.gpuYellow, red: $model.gpuRed)
                    ThresholdRow(title: "Power", subtitle: "W", yellow: $model.powerYellow, red: $model.powerRed)
                    ThresholdRow(title: "Fan", subtitle: "ratio", yellow: $model.fanYellow, red: $model.fanRed)
                    ThresholdRow(title: "Network", subtitle: "MB/s", yellow: $model.networkYellow, red: $model.networkRed)
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: 360)
        }
        .frame(width: 452, height: 518, alignment: .top)
    }

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.yellow.opacity(0.18),
                                Color.red.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                Image(systemName: "dial.medium.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.orange)
            }

            Text("Set Thresholds")
                .font(.system(size: 15, weight: .semibold))

            Text("Customize the yellow and red limits for each metric.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ThresholdHeaderRow: View {
    var body: some View {
        HStack {
            Text("Metric")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 90, alignment: .leading)
            Spacer()
            Text("Yellow")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 96)
            Text("Red")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 96)
        }
        .foregroundColor(.secondary)
    }
}

private struct ThresholdRow: View {
    let title: String
    let subtitle: String
    @Binding var yellow: String
    @Binding var red: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(width: 90, alignment: .leading)

            thresholdField(color: .yellow, text: $yellow)
            thresholdField(color: .red, text: $red)
        }
        .padding(10)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func thresholdField(color: Color, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 96, height: 28)
        }
    }
}

final class IntervalEditorModel: ObservableObject {
    @Published var value: String

    init(currentValue: Int) {
        self.value = "\(currentValue)"
    }
}

struct IntervalEditorView: View {
    @ObservedObject var model: IntervalEditorModel

    var body: some View {
        VStack(spacing: 14) {
            header

            HStack(spacing: 10) {
                Text("ms")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.yellow.opacity(0.14))
                    )
                TextField("", text: $model.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(width: 120)
                Spacer()
            }
            .frame(maxWidth: 240)

            Text("Current minimum: 500 ms")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: 240, alignment: .leading)
        }
        .frame(width: 352, height: 220, alignment: .top)
    }

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.18),
                                Color.blue.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                Image(systemName: "timer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.accentColor)
            }

            Text("Set Interval")
                .font(.system(size: 15, weight: .semibold))

            Text("Lower values refresh faster but use more power.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
