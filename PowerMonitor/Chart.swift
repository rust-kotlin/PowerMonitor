import SwiftUI
import Charts

// Shared chart point model used by all detail views.
struct ResourcePoint: Identifiable, Equatable {
    let id = UUID()
    let x: Double
    let y: Double
}

// All charts reuse the same renderer but choose different labels and domains.
enum ChartYUnit {
    case percent
    case watts
    case rpm
    case bytesPerSecond
    case custom(String)
}

struct ResourceUsageChartView: View {
    var data: [ResourcePoint]
    var width: CGFloat? = nil
    var height: CGFloat = 80
    var accentColor: Color = .blue
    /// Optional explicit y domain.
    var yDomain: ClosedRange<Double>? = nil
    /// Optional explicit unit; if nil, derive a simple default from the visible range.
    var yUnit: ChartYUnit? = nil
    
    private var areaGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [accentColor.opacity(0.45), accentColor.opacity(0.05)]),
            startPoint: .top, endPoint: .bottom
        )
    }
    
    private var detectedUnit: ChartYUnit {
        if let u = yUnit { return u }
        let maxY = data.map { $0.y }.max() ?? 0.0
        return maxY <= 1.0 ? .percent : .watts
    }

    // Keep the zero label aligned with the chart scale so MB/s charts do not show "0 KB/s".
    private var byteRateZeroLabel: String {
        let reference = max(
            data.map { $0.y }.max() ?? 0,
            yDomain?.upperBound ?? 0
        )
        if reference >= 1_000_000_000 {
            return "0 GB/s"
        }
        if reference >= 1_000_000 {
            return "0 MB/s"
        }
        return "0 KB/s"
    }
    
    private func formatLabel(_ v: Double, unit: ChartYUnit) -> String {
        switch unit {
            case .percent:
                return String(format: "%.0f%%", v * 100)
            case .watts:
                return v >= 10 ? String(format: "%.0f W", v) : String(format: "%.1f W", v)
            case .rpm:
                return String(format: "%.0f RPM", v)
            case .bytesPerSecond:
                if v < 1 {
                    return byteRateZeroLabel
                }
                let units = ["B/s", "KB/s", "MB/s", "GB/s"]
                var value = max(v, 0)
                var unitIndex = 0
                while value >= 1000, unitIndex < units.count - 1 {
                    value /= 1000
                    unitIndex += 1
                }
                if unitIndex == 0 {
                    return String(format: "%.0f %@", value, units[unitIndex])
                }
                if value >= 100 {
                    return String(format: "%.0f %@", value, units[unitIndex])
                }
                if value >= 10 {
                    return String(format: "%.1f %@", value, units[unitIndex])
                }
                return String(format: "%.2f %@", value, units[unitIndex])
            case .custom(let s):
                return String(format: "%.2f %@", v, s)
        }
    }
    
    var body: some View {
        let unit = detectedUnit
        
        Chart {
            ForEach(data) { point in
                AreaMark(x: .value("Time", point.x), y: .value("Usage", point.y))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(areaGradient)
                
                LineMark(x: .value("Time", point.x), y: .value("Usage", point.y))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(accentColor)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(formatLabel(d, unit: unit))
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .padding(5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.05))
        .cornerRadius(8)
        .applyIfLet(yDomain) { view, domain in
            view.chartYScale(domain: domain)
        }
    }
}

fileprivate extension View {
    // Tiny helper for conditional modifiers without nesting whole view trees.
    @ViewBuilder
    func applyIfLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let v = value { transform(self, v) }
        else { self }
    }
}
