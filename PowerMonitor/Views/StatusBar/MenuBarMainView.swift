import SwiftUI
import AppKit
import Combine

// The menu bar view stays presentation-only so AppDelegate can focus on menu wiring.
struct MenuBarMainView: View {
    @ObservedObject var monitor: SystemMonitor
    var onBlockClick: (MonitorMetric, CGRect?) -> Void
    var onFramesUpdate: (([MonitorMetric: CGRect]) -> Void)? = nil

    @State private var blockFrames: [MonitorMetric: CGRect] = [:]

    var body: some View {
        HStack(spacing: 0) {
            if monitor.data != nil {
                let visibleMetrics = monitor.orderedVisibleMetrics
                if visibleMetrics.isEmpty {
                    Text("...")
                        .font(.system(size: 10))
                        .frame(width: 30)
                } else {
                    ForEach(Array(visibleMetrics.enumerated()), id: \.element) { index, metric in
                        if index > 0, monitor.showMetricDividers {
                            Divider().frame(height: 12).opacity(0.3)
                        }

                        MenuBarBlockView(
                            title: metric.shortTitle,
                            value: valueText(for: metric),
                            valueColor: monitor.useColoredValues ? colorFor(metric: metric) : nil,
                            width: metric == .fan ? 38 : (metric == .disk ? 36 : 32)
                        )
                        .background(GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    DispatchQueue.main.async {
                                        blockFrames[metric] = geo.frame(in: .named("menuHostingSpace"))
                                        onFramesUpdate?(blockFrames)
                                    }
                                }
                                .onChange(of: geo.frame(in: .named("menuHostingSpace"))) { _, newValue in
                                    DispatchQueue.main.async {
                                        blockFrames[metric] = newValue
                                        onFramesUpdate?(blockFrames)
                                    }
                                }
                        })
                    }
                }
            } else {
                Text("...")
                    .font(.system(size: 10))
                    .frame(width: 30)
            }

            if monitor.isMock {
                Divider().frame(height: 12).opacity(0.0)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))
                    .padding(.leading, 4)
                    .help(monitor.mockWarning ?? "Using mock data")
            }
        }
        .coordinateSpace(name: "menuHostingSpace")
    }

    private func valueText(for metric: MonitorMetric) -> String {
        guard let data = monitor.data else { return "--" }
        switch metric {
            case .disk:
                switch monitor.diskDisplayMode {
                case .readSpeed:
                    return formatCompactRate(monitor.diskStats.readBytesPerSecond)
                case .usage:
                    let percent = monitor.diskStats.totalBytes > 0
                        ? Double(monitor.diskStats.usedBytes) / Double(monitor.diskStats.totalBytes) * 100
                        : 0
                    return String(format: "%.0f%%", percent)
                }
            case .cpu:
                return String(format: "%.0f%%", cpuPercent(from: data) * 100)
            case .gpu:
                return String(format: "%.0f%%", usageValue(data.gpuUsage) * 100)
            case .ram:
                let percent = data.memory.ramTotal > 0 ? Double(data.memory.ramUsage) / Double(data.memory.ramTotal) * 100 : 0
                return String(format: "%.0f%%", percent)
            case .power:
                return data.sysPower > 10 ? String(format: "%.0fW", data.sysPower) : String(format: "%.1fW", data.sysPower)
            case .fan:
                guard let rpm = monitor.currentFanRPM else { return "--" }
                return rpm >= 1000 ? String(format: "%.1fk", rpm / 1000.0) : String(format: "%.0f", rpm)
            case .network:
                let rate: Double
                switch monitor.networkDisplayMode {
                    case .download:
                        rate = monitor.networkThroughput.downloadBytesPerSecond
                    case .upload:
                        rate = monitor.networkThroughput.uploadBytesPerSecond
                    case .total:
                        rate = monitor.networkThroughput.totalBytesPerSecond
                }
                return formatCompactRate(rate)
        }
    }

    // Match the same threshold-driven color language used elsewhere in the app so the
    // menu bar reflects the same alert state as the popovers and overlay tags.
    private func colorFor(metric: MonitorMetric) -> Color {
        let glowGreen = Color(red: 0.35, green: 0.90, blue: 0.45)
        let glowYellow = Color(red: 0.95, green: 0.90, blue: 0.55)
        let glowRed = Color(red: 0.95, green: 0.50, blue: 0.50)

        let value: Double
        switch metric {
            case .disk:
                switch monitor.diskDisplayMode {
                case .readSpeed:
                    value = monitor.diskStats.readBytesPerSecond
                    if value >= monitor.thresholds.diskRed { return glowRed }
                    if value >= monitor.thresholds.diskYellow { return glowYellow }
                    return glowGreen
                case .usage:
                    value = monitor.diskStats.totalBytes > 0
                        ? Double(monitor.diskStats.usedBytes) / Double(monitor.diskStats.totalBytes) * 100
                        : 0
                    if value >= monitor.thresholds.diskUsageRed { return glowRed }
                    if value >= monitor.thresholds.diskUsageYellow { return glowYellow }
                    return glowGreen
                }
            case .cpu:
                value = (monitor.data.map(cpuPercent(from:)) ?? 0) * 100
                if value >= monitor.thresholds.cpuRed { return glowRed }
                if value >= monitor.thresholds.cpuYellow { return glowYellow }
                return glowGreen
            case .gpu:
                value = (monitor.data.map { usageValue($0.gpuUsage) } ?? 0) * 100
                if value >= monitor.thresholds.gpuRed { return glowRed }
                if value >= monitor.thresholds.gpuYellow { return glowYellow }
                return glowGreen
            case .ram:
                switch monitor.data?.memory.pressureLevel ?? .normal {
                case .normal:
                    return glowGreen
                case .warning:
                    return glowYellow
                case .critical:
                    return glowRed
                }
            case .power:
                value = monitor.data?.sysPower ?? 0
                if value >= monitor.thresholds.powerRed { return glowRed }
                if value >= monitor.thresholds.powerYellow { return glowYellow }
                return glowGreen
            case .fan:
                value = monitor.currentFanRPM ?? 0
                let maxRPM = max(monitor.currentFanMaxRPM ?? 3000, 1)
                let ratio = value / maxRPM
                if ratio >= monitor.thresholds.fanRed { return glowRed }
                if ratio >= monitor.thresholds.fanYellow { return glowYellow }
                return glowGreen
            case .network:
                value = currentNetworkRate()
                if value >= monitor.thresholds.networkRed { return glowRed }
                if value >= monitor.thresholds.networkYellow { return glowYellow }
                return glowGreen
        }
    }

    private func usageValue(_ usage: [Double]) -> Double {
        guard usage.count >= 2 else { return 0 }
        return usage[1]
    }

    private func cpuPercent(from data: MacMonData) -> Double {
        let e = usageValue(data.ecpuUsage)
        let p = usageValue(data.pcpuUsage)
        if data.ecpuUsage.count >= 2 && data.pcpuUsage.count >= 2 {
            return (e + p) / 2.0
        }
        return max(e, p)
    }

    private func currentNetworkRate() -> Double {
        switch monitor.networkDisplayMode {
            case .download:
                return monitor.networkThroughput.downloadBytesPerSecond
            case .upload:
                return monitor.networkThroughput.uploadBytesPerSecond
            case .total:
                return monitor.networkThroughput.totalBytesPerSecond
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

}
