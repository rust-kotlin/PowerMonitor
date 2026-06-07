import SwiftUI
import AppKit

// Detail popovers reuse one shell and swap the metric-specific content inside it.
struct DetailPopupView: View {
    let metric: MonitorMetric
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        Group {
            if let data = monitor.data {
                content(data: data)
            } else {
                VStack {
                    Text("Waiting for data...")
                        .padding()
                    if monitor.isMock, let msg = monitor.mockWarning {
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding([.leading, .trailing], 8)
                    }
                }
            }
        }
        .frame(width: 260)
        .padding(12)
    }

    private let chartDetailRow = DetailRow(icon: "chart.bar", label: "Chart", value: "30s")

    @ViewBuilder
    private func content(data: MacMonData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(metric.detailTitle)
                    .font(.headline)
                Spacer()
                Button {
                    openInActivityMonitor()
                } label: {
                    Image(systemName: "gauge")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .help("Open in Activity Monitor")
                        .accessibilityLabel(Text("Open in Activity Monitor"))
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Each metric uses a short summary block followed by a shared chart section.
            switch metric {
                case .disk:
                    VStack(spacing: 6) {
                        DetailRow(icon: "internaldrive", label: "Volume", value: monitor.diskStats.volumeName)
                        DetailRow(icon: "externaldrive.fill.badge.checkmark", label: "Used", value: formatBytes(monitor.diskStats.usedBytes))
                        DetailRow(icon: "tray.full", label: "Available", value: formatBytes(monitor.diskStats.availableBytes))
                        DetailRow(icon: "archivebox", label: "Total", value: formatBytes(monitor.diskStats.totalBytes))
                        Divider().opacity(0.5)
                        DetailRow(icon: "chart.pie.fill", label: "Usage", value: formatDiskUsage(usedBytes: monitor.diskStats.usedBytes, totalBytes: monitor.diskStats.totalBytes))
                        Divider().opacity(0.5)
                        DetailRow(icon: "arrow.down.circle", label: "Read", value: formatRate(monitor.diskStats.readBytesPerSecond))
                        DetailRow(icon: "arrow.up.circle", label: "Write", value: formatRate(monitor.diskStats.writeBytesPerSecond))
                        DetailRow(icon: "opticaldiscdrive.fill", label: "Total I/O", value: formatRate(monitor.diskStats.totalBytesPerSecond))
                    }
                    .padding(.top, 4)
                    Divider()
                    chartDetailRow
                    ResourceChartSection(points: monitor.diskHistory, yDomain: paddedDomain(from: monitor.diskHistory, minimumUpperBound: 100_000), accent: .teal, yUnit: .bytesPerSecond)

                case .cpu:
                    VStack(spacing: 6) {
                        DetailRow(icon: "cpu", label: "E-Core", value: formatUsage(data.ecpuUsage))
                        DetailRow(icon: "cpu.fill", label: "P-Core", value: formatUsage(data.pcpuUsage))
                        Divider().opacity(0.5)
                        DetailRow(icon: "thermometer", label: "Temp", value: String(format: "%.1f°C", data.temp.cpuTempAvg))
                        DetailRow(icon: "bolt", label: "Power", value: String(format: "%.2f W", data.cpuPower))
                    }
                    .padding(.top, 4)
                    Divider()
                    chartDetailRow
                    ResourceChartSection(points: monitor.cpuHistory, yDomain: percentDomain(from: monitor.cpuHistory), accent: .accentColor, yUnit: .percent)

                case .gpu:
                    VStack(spacing: 6) {
                        DetailRow(icon: "display", label: "Usage", value: formatUsage(data.gpuUsage))
                        DetailRow(icon: "thermometer", label: "Temp", value: String(format: "%.1f°C", data.temp.gpuTempAvg))
                        DetailRow(icon: "memorychip", label: "VRAM Power", value: String(format: "%.2f W", data.gpuRamPower))
                        DetailRow(icon: "bolt", label: "Power", value: String(format: "%.2f W", data.gpuPower))
                    }
                    .padding(.top, 4)
                    Divider()
                    chartDetailRow
                    ResourceChartSection(points: monitor.gpuHistory, yDomain: percentDomain(from: monitor.gpuHistory), accent: .purple, yUnit: .percent)

                case .ram:
                    VStack(spacing: 6) {
                        DetailRow(icon: "memorychip", label: "Used", value: formatBytes(data.memory.ramUsage))
                        DetailRow(icon: "archivebox", label: "Total", value: formatBytes(data.memory.ramTotal))
                        if let appMemory = data.memory.appMemory {
                            Divider().opacity(0.5)
                            DetailRow(icon: "app.badge", label: "App", value: formatBytes(appMemory))
                        }
                        if let wiredMemory = data.memory.wiredMemory {
                            DetailRow(icon: "cable.connector", label: "Wired", value: formatBytes(wiredMemory))
                        }
                        if let compressedMemory = data.memory.compressedMemory {
                            DetailRow(icon: "arrow.down.circle", label: "Compressed", value: formatBytes(compressedMemory))
                        }
                        if let cachedFiles = data.memory.cachedFiles {
                            DetailRow(icon: "externaldrive.badge.timemachine", label: "Cached", value: formatBytes(cachedFiles))
                        }
                        if let freeMemory = data.memory.freeMemory {
                            DetailRow(icon: "circle.dotted", label: "Free", value: formatBytes(freeMemory))
                        }
                        if data.memory.swapTotal > 0 || data.memory.swapUsage > 0 {
                            Divider().opacity(0.5)
                            DetailRow(icon: "arrow.triangle.2.circlepath", label: "Swap", value: formatBytes(data.memory.swapUsage))
                        }
                        if let pressure = data.memory.pressureLevel {
                            DetailRow(icon: "gauge.badge.minus", label: "Pressure", value: pressure.title)
                        }
                        DetailRow(icon: "bolt", label: "Power", value: String(format: "%.2f W", data.ramPower))
                    }
                    .padding(.top, 4)
                    Divider()
                    chartDetailRow
                    ResourceChartSection(points: monitor.ramHistory, yDomain: 0...1, accent: .green, yUnit: .percent)

                case .power:
                    VStack(spacing: 6) {
                        DetailRow(icon: "powerplug", label: "System", value: String(format: "%.2f W", data.sysPower))
                        DetailRow(icon: "cpu.fill", label: "SOC Total", value: String(format: "%.2f W", data.allPower))
                        DetailRow(icon: "brain", label: "ANE", value: String(format: "%.2f W", data.anePower))
                    }
                    .padding(.top, 4)
                    Divider()
                    chartDetailRow
                    ResourceChartSection(points: monitor.powerHistory, yDomain: paddedDomain(from: monitor.powerHistory, minimumUpperBound: 1.0), accent: .orange, yUnit: .watts)

                case .fan:
                    VStack(spacing: 6) {
                        if monitor.fanReadings.isEmpty {
                            DetailRow(icon: "questionmark.circle", label: "Status", value: "No fan data")
                        } else {
                            ForEach(monitor.fanReadings) { fan in
                                DetailRow(
                                    icon: "fanblades.fill",
                                    label: fan.name,
                                    value: formatFanValue(currentRPM: fan.rpm, maxRPM: fan.maxRPM)
                                )
                            }
                        }
                    }
                    .padding(.top, 4)
                    Divider()
                    FanControlSection(monitor: monitor)
                    Divider()
                    chartDetailRow
                    ResourceChartSection(points: monitor.fanHistory, yDomain: paddedDomain(from: monitor.fanHistory, minimumUpperBound: 1000.0), accent: .cyan, yUnit: .rpm)

                case .network:
                    VStack(spacing: 6) {
                        DetailRow(icon: "point.3.filled.connected.trianglepath.dotted", label: "Interface", value: monitor.primaryNetworkInterfaceSummary)
                        DetailRow(icon: "arrow.up.circle", label: "Upload", value: formatRate(monitor.networkThroughput.uploadBytesPerSecond))
                        DetailRow(icon: "arrow.down.circle", label: "Download", value: formatRate(monitor.networkThroughput.downloadBytesPerSecond))
                        Divider().opacity(0.5)
                        DetailRow(icon: "network", label: "Total", value: formatRate(monitor.networkThroughput.totalBytesPerSecond))
                    }
                    .padding(.top, 4)
                    Divider()
                    chartDetailRow
                    ResourceChartSection(points: monitor.networkHistory, yDomain: paddedDomain(from: monitor.networkHistory, minimumUpperBound: 100_000), accent: .mint, yUnit: .bytesPerSecond)
            }
        }
    }

    private func openInActivityMonitor() {
        let script = """
        tell application "Activity Monitor" to activate
        """
        if let apple = NSAppleScript(source: script) {
            var err: NSDictionary? = nil
            _ = apple.executeAndReturnError(&err)
        }
    }

    private func formatUsage(_ usage: [Double]) -> String {
        guard usage.count >= 2 else { return "0%" }
        return String(format: "%.2f%% @ %.0f MHz", usage[1] * 100, usage[0])
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func formatRPM(_ rpm: Double?) -> String {
        guard let rpm else { return "--" }
        return String(format: "%.0f RPM", rpm)
    }

    private func formatFanValue(currentRPM: Double, maxRPM: Double?) -> String {
        if let maxRPM {
            return String(format: "%.0f / %.0f RPM", currentRPM, maxRPM)
        }
        return String(format: "%.0f RPM", currentRPM)
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 {
            return "0 KB/s"
        }

        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(bytesPerSecond, 0)
        var unitIndex = 0

        while value >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }

        let unit = units[unitIndex]
        if value >= 100 || unitIndex == 0 {
            return String(format: "%.0f %@", value, unit)
        }
        if value >= 10 {
            return String(format: "%.1f %@", value, unit)
        }
        return String(format: "%.2f %@", value, unit)
    }

    private func formatDiskUsage(usedBytes: Int64, totalBytes: Int64) -> String {
        guard totalBytes > 0 else { return "0%" }
        let percent = Double(usedBytes) / Double(totalBytes) * 100
        return String(format: "%.1f%%", percent)
    }

    private func paddedDomain(from points: [ResourcePoint], minimumUpperBound: Double) -> ClosedRange<Double> {
        let maxY = points.map(\.y).max() ?? minimumUpperBound
        return 0...max(minimumUpperBound, maxY * 1.15)
    }

    private func percentDomain(from points: [ResourcePoint]) -> ClosedRange<Double> {
        let maxY = points.map(\.y).max() ?? 1.0
        return 0...max(1.0, maxY * 1.1)
    }
}

private struct FanControlSection: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var smartSource: FanRuleSource = .cpu

    // Manual mode falls back to a machine-aware starting point before the user chooses
    // an explicit RPM target.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: {
                let fallback = max(monitor.currentFanMinRPM ?? 0, (monitor.currentFanMaxRPM ?? 3000) * 0.6)
                return monitor.fanControlSettings.manualRPM > 0 ? monitor.fanControlSettings.manualRPM : fallback
            },
            set: { monitor.setManualFanRPM($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fan Control")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(modeSummaryText)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                FanHelperStatusDot(monitor: monitor)
            }
            .padding(.bottom, 2)

            Picker("Fan mode", selection: Binding(
                get: { monitor.fanControlSettings.mode },
                set: { monitor.setFanControlMode($0) }
            )) {
                ForEach(FanControlMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if monitor.fanControlSettings.mode == .manual {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Target")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(sliderBinding.wrappedValue.rounded())) RPM")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                    }

                    FanManualSlider(
                        value: sliderBinding,
                        in: 0...max(1000, monitor.currentFanMaxRPM ?? 3000),
                        step: 50
                    )
                    .frame(height: 18)
                }
            }

            if monitor.fanControlSettings.mode == .smart {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("Curve source", selection: $smartSource) {
                            Text("CPU").tag(FanRuleSource.cpu)
                            Text("GPU").tag(FanRuleSource.gpu)
                        }
                        .pickerStyle(.segmented)

                        Spacer()
                        Text(smartTargetTagText)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(smartTargetTagColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(smartTargetTagBackground)
                            )
                    }

                    SmartCurveMiniEditor(
                        source: smartSource,
                        monitor: monitor
                    )
                }
            }

            if let error = monitor.fanControlError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeSummaryText: String {
        switch monitor.fanControlSettings.mode {
            case .system:
                return "Automatic thermal control"
            case .manual:
                return "Lock a fixed fan target"
            case .smart:
                return "Temperature curve control"
        }
    }

    private var smartTargetTagText: String {
        guard let target = monitor.currentSmartTargetRPM else {
            return "--"
        }
        return "\(target)"
    }

    private var smartTargetTagColor: Color {
        guard let target = monitor.currentSmartTargetRPM else {
            return .secondary
        }
        let maxRPM = max(monitor.currentFanMaxRPM ?? 3000, 1)
        let ratio = Double(target) / maxRPM
        if ratio >= monitor.thresholds.fanRed {
            return Color(red: 0.95, green: 0.50, blue: 0.50)
        }
        if ratio >= monitor.thresholds.fanYellow {
            return Color(red: 0.95, green: 0.90, blue: 0.55)
        }
        return Color(red: 0.35, green: 0.90, blue: 0.45)
    }

    private var smartTargetTagBackground: Color {
        guard monitor.currentSmartTargetRPM != nil else {
            return Color.primary.opacity(0.08)
        }
        return smartTargetTagColor.opacity(0.14)
    }
}

private struct FanHelperStatusDot: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 14, height: 14)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.92), lineWidth: 2)
            )
            .help(helpText)
            .contextMenu {
                Button("Install / Update Helper") {
                    _ = monitor.installFanHelperIfNeeded()
                }
                Button("Uninstall Helper") {
                    _ = monitor.uninstallFanHelper()
                }
            }
    }

    // The dot only represents helper availability, not whether the current target is high or low.
    private var statusColor: Color {
        if monitor.isFanHelperStatusPending {
            return .yellow
        }
        if monitor.isFanHelperReady {
            return .green
        }
        if monitor.isFanHelperInstalled {
            return .orange
        }
        return .red
    }

    private var helpText: String {
        if monitor.isFanHelperStatusPending {
            return "Fan helper is being prepared. Right-click to manage the helper."
        }
        if monitor.isFanHelperReady {
            return "Fan helper is ready. Right-click to install, update, or uninstall the helper."
        }
        if monitor.isFanHelperInstalled {
            return "Fan helper is installed but not ready yet. Right-click to manage the helper."
        }
        return "Fan helper is not installed. Right-click to install or uninstall the helper."
    }
}

private struct FanManualSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        self._value = value
        self.range = range
        self.step = step
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, step: step)
    }

    // AppKit gives tighter visual and focus control here than the stock SwiftUI slider.
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.focusRingType = .none
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        if abs(nsView.doubleValue - value) > 0.1 {
            nsView.doubleValue = value
        }
        context.coordinator.step = step
    }

    final class Coordinator: NSObject {
        @Binding var value: Double
        var step: Double

        init(value: Binding<Double>, step: Double) {
            self._value = value
            self.step = step
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let stepped = (sender.doubleValue / step).rounded() * step
            sender.doubleValue = stepped
            value = stepped
        }
    }
}

private struct SmartCurveMiniEditor: View {
    let source: FanRuleSource
    @ObservedObject var monitor: SystemMonitor

    private let temperatures = FanSmartCurveDefaults.temperatures

    var body: some View {
        GeometryReader { geo in
            let leftInset: CGFloat = 40
            let bottomInset: CGFloat = 26
            let topInset: CGFloat = 14
            let rightInset: CGFloat = 14
            let chartWidth = max(geo.size.width - leftInset - rightInset, 1)
            let chartHeight = max(geo.size.height - topInset - bottomInset, 1)
            let minRPM = 0
            let maxRPM = max(Int((monitor.currentFanMaxRPM ?? 4900).rounded()), 1000)
            let stepX = temperatures.count > 1 ? chartWidth / CGFloat(temperatures.count - 1) : 0
            let points = temperatures.enumerated().map { index, temperature in
                let rpm = pointRPM(for: temperature)
                let x = leftInset + CGFloat(index) * stepX
                let y = pointY(for: rpm, minRPM: minRPM, maxRPM: maxRPM, chartHeight: chartHeight)
                return MiniCurvePointLayout(temperature: temperature, rpm: rpm, x: x, y: y)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((source == .cpu ? Color.orange : Color.blue).opacity(0.05))

                // Keep the grid coarse so the chart stays readable while points snap to 100 RPM.
                ForEach(0..<5, id: \.self) { line in
                    let progress = CGFloat(line) / 4
                    let y = topInset + progress * chartHeight
                    let tickRPM = Int((Double(maxRPM) * Double(1 - progress) / 100.0).rounded() * 100.0)
                    Path { path in
                        path.move(to: CGPoint(x: leftInset, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width - rightInset, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    Text("\(tickRPM)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .position(x: 18, y: y)
                }

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: topInset + first.y))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x, y: topInset + point.y))
                    }
                }
                .stroke(source == .cpu ? .orange : .blue, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                ForEach(points) { point in
                    SmartCurvePointHandle(
                        color: source == .cpu ? .orange : .blue,
                        layout: point,
                        chartHeight: chartHeight,
                        minRPM: minRPM,
                        maxRPM: maxRPM,
                        binding: binding(for: point.temperature)
                    )
                }

                Text("RPM")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .position(x: 18, y: 6)

                HStack {
                    ForEach(Array(temperatures.enumerated()), id: \.offset) { index, temperature in
                        if index == 0 || index == temperatures.count - 1 || temperature % 10 == 0 {
                            Text("\(temperature)")
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                        } else {
                            Spacer(minLength: 0)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(width: chartWidth)
                .position(x: leftInset + chartWidth / 2, y: geo.size.height - 10)
            }
        }
        .frame(height: 214)
    }

    private func pointRPM(for temperature: Int) -> Int {
        monitor.fanControlSettings.smartRules
            .first(where: { $0.source == source && $0.temperature == temperature })?
            .targetRPM
        ?? monitor.defaultSmartCurvePoints(
            maxRPM: monitor.currentFanMaxRPM,
            minRPM: monitor.currentFanMinRPM
        )
        .first(where: { $0.source == source && $0.temperature == temperature })?
        .targetRPM
        ?? 0
    }

    // Backfill missing default points before editing so legacy partial curves can still
    // be dragged safely across the full editable temperature range.
    private func binding(for temperature: Int) -> Binding<Double> {
        Binding(
            get: { Double(pointRPM(for: temperature)) },
            set: { newValue in
                var updated = monitor.fanControlSettings.smartRules
                if updated.count < FanRuleSource.allCases.count * temperatures.count {
                    updated = monitor.defaultSmartCurvePoints(
                        maxRPM: monitor.currentFanMaxRPM,
                        minRPM: monitor.currentFanMinRPM
                    )
                    .map { defaultPoint in
                        updated.first(where: { $0.source == defaultPoint.source && $0.temperature == defaultPoint.temperature }) ?? defaultPoint
                    }
                }
                if let index = updated.firstIndex(where: { $0.source == source && $0.temperature == temperature }) {
                    updated[index].targetRPM = Int(newValue.rounded())
                }
                _ = monitor.setSmartFanRules(updated)
            }
        )
    }

    private func pointY(for rpm: Int, minRPM: Int, maxRPM: Int, chartHeight: CGFloat) -> CGFloat {
        let span = max(maxRPM - minRPM, 1)
        let normalized = CGFloat(max(0, min(rpm - minRPM, span))) / CGFloat(span)
        return chartHeight - normalized * chartHeight
    }
}

private struct MiniCurvePointLayout: Identifiable {
    let temperature: Int
    let rpm: Int
    let x: CGFloat
    let y: CGFloat

    var id: Int { temperature }
}

private struct SmartCurvePointHandle: View {
    let color: Color
    let layout: MiniCurvePointLayout
    let chartHeight: CGFloat
    let minRPM: Int
    let maxRPM: Int
    let binding: Binding<Double>
    @State private var previewRPM: Int?
    @State private var dragStartRPM: Int?

    var body: some View {
        let displayedRPM = previewRPM ?? layout.rpm
        let displayedY = pointY(for: displayedRPM)
        Circle()
            .fill(Color.white)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(color, lineWidth: 2.8))
            .contentShape(Rectangle().inset(by: -8))
            .help("\(layout.temperature)°C · \(displayedRPM) RPM")
        .position(x: layout.x, y: 14 + displayedY)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartRPM == nil {
                        dragStartRPM = layout.rpm
                    }
                    let nextRPM = rpm(for: value.translation.height, from: dragStartRPM ?? layout.rpm)
                    previewRPM = nextRPM
                    binding.wrappedValue = Double(nextRPM)
                }
                .onEnded { _ in
                    let finalRPM = previewRPM ?? layout.rpm
                    binding.wrappedValue = Double(finalRPM)
                    previewRPM = nil
                    dragStartRPM = nil
                }
        )
    }

    private func pointY(for rpm: Int) -> CGFloat {
        let span = max(maxRPM - minRPM, 1)
        let normalized = CGFloat(max(0, min(rpm - minRPM, span))) / CGFloat(span)
        return chartHeight - normalized * chartHeight
    }

    // Drag gestures snap directly to 100 RPM increments to match the saved smart curve model.
    private func rpm(for translationY: CGFloat, from startingRPM: Int) -> Int {
        let rpmPerPoint = Double(max(maxRPM - minRPM, 1)) / Double(max(chartHeight, 1))
        let rawRPM = Double(startingRPM) - Double(translationY) * rpmPerPoint
        let snappedRPM = Int((rawRPM / 100.0).rounded() * 100.0)
        return min(max(snappedRPM, minRPM), maxRPM)
    }
}

struct DetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundColor(.accentColor)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}

struct ResourceChartSection: View {
    var points: [ResourcePoint]
    var yDomain: ClosedRange<Double>
    var accent: Color
    var yUnit: ChartYUnit

    var body: some View {
        let normalizedPoints = normalized(points: points)
        ResourceUsageChartView(data: normalizedPoints, width: nil, height: 80, accentColor: accent, yDomain: yDomain, yUnit: yUnit)
            .frame(height: 80)
    }

    // Shift samples into a local 30-second window so charts do not expose absolute timestamps.
    private func normalized(points: [ResourcePoint]) -> [ResourcePoint] {
        guard let last = points.last else { return [] }
        let cutoff = last.x - 30.0
        return points.map { ResourcePoint(x: $0.x - cutoff, y: $0.y) }
    }
}
