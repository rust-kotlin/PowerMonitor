import SwiftUI
import AppKit
import Foundation
import SystemConfiguration

// Central application state and orchestration layer.
// This type owns telemetry sampling, persisted preferences, chart histories,
// and the fan control state machine.
class SystemMonitor: ObservableObject {
    @Published var data: MacMonData?
    @Published var isRunning = false
    @Published var intervalMs: Int = 1000
    @Published var isMock: Bool = false
    @Published var mockWarning: String? = nil
    @Published var useColoredValues: Bool = true
    @Published var showMetricDividers: Bool = true
    @Published var networkDisplayMode: NetworkDisplayMode = .total
    @Published var diskDisplayMode: DiskDisplayMode = .readSpeed
    @Published var networkOverlaySettings: NetworkOverlaySettings = .defaults
    @Published var networkSourceName: String? = nil
    @Published var diskSourcePath: String? = nil
    @Published var metricOrder: [MonitorMetric] = [.network, .cpu, .gpu, .ram, .power, .disk, .fan]
    @Published var hiddenMetrics = Set<MonitorMetric>()
    @Published var thresholds: MetricThresholds = .defaults
    @Published var fanReadings: [FanReading] = []
    @Published var networkThroughput = NetworkThroughput(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
    @Published var diskStats = DiskStats(volumeName: "Macintosh HD", totalBytes: 0, availableBytes: 0, usedBytes: 0, readBytesPerSecond: 0, writeBytesPerSecond: 0)
    @Published var fanControlSettings: FanControlSettings = .defaults
    @Published var fanControlError: String? = nil
    @Published private(set) var isFanHelperInstalled = false
    @Published private(set) var isFanHelperReady = false
    @Published private(set) var isFanHelperStatusPending = false

    @Published var cpuHistory: [ResourcePoint] = []
    @Published var gpuHistory: [ResourcePoint] = []
    @Published var ramHistory: [ResourcePoint] = []
    @Published var powerHistory: [ResourcePoint] = []
    @Published var fanHistory: [ResourcePoint] = []
    @Published var networkHistory: [ResourcePoint] = []
    @Published var diskHistory: [ResourcePoint] = []
    private var samplingTimer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "com.powerMonitor.telemetry", qos: .userInitiated)
    private var isSampling = false
    private var mockTimer: Timer?
    private let nativeSampler = NativeTelemetrySampler()
    private let fanSensor = FanSensorReader()
    private let networkReader = NetworkSpeedReader()
    private let diskReader = DiskStatsReader()
    private let fanControlService = FanControlService()
    private var lastAppliedFanCommand: FanControlCommand?
    private var wakeObserver: NSObjectProtocol?
    private var hiddenFanRestoreMode: FanControlMode?
    // Smart fan mode intentionally stages target changes:
    // first wait for a stable desired target, then ramp toward it gradually.
    private var pendingSmartTargetRPM: Int?
    private var pendingSmartTargetSince: Date?
    private var activeSmartTargetRPM: Int?
    private var smoothedSmartTargetRPM: Int?
    private var lastSmartRampAt: Date?
    private let smartTargetSettleDuration: TimeInterval = 2.5
    private let smartTargetRampRateRPMPerSecond: Double = 300

    private let storageDirName = "PowerMonitor"
    private let configFileName = "config.json"
    private lazy var storageDirURL: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(storageDirName, isDirectory: true)
    }()
    private lazy var configURL: URL = { storageDirURL.appendingPathComponent(configFileName) }()
    private let ioQueue = DispatchQueue(label: "com.powerMonitor.config", qos: .utility)

    // Only user-facing preferences belong in config. Runtime-only state stays transient.
    struct Config: Codable {
        var intervalMs: Int
        var useColoredValues: Bool
        var showMetricDividers: Bool?
        var networkDisplayMode: String
        var diskDisplayMode: String?
        var networkOverlay: NetworkOverlaySettings?
        var networkSourceName: String?
        var diskSourcePath: String?
        var metricOrder: [String]
        var hiddenMetrics: [String]
        var thresholds: MetricThresholds?
        var fanControl: FanControlSettings?
    }

    var orderedVisibleMetrics: [MonitorMetric] {
        metricOrder.filter { !hiddenMetrics.contains($0) }
    }

    var currentFanRPM: Double? {
        fanReadings.map(\.rpm).max()
    }

    var currentFanMaxRPM: Double? {
        fanReadings.compactMap(\.maxRPM).max()
    }

    var currentFanMinRPM: Double? {
        fanReadings.compactMap(\.minRPM).min()
    }

    var primaryNetworkInterfaceSummary: String {
        networkReader.primaryInterfaceSummary
    }

    var availableNetworkInterfaces: [NetworkInterfaceOption] {
        networkReader.availableInterfaces()
    }

    var availableDiskVolumes: [DiskVolumeOption] {
        diskReader.availableVolumes()
    }

    var currentSmartTargetRPM: Int? {
        smartTargetRPM(for: data)
    }

    var currentSmartCPUTargetRPM: Int? {
        smartTargetRPM(for: data, source: .cpu)
    }

    var currentSmartGPUTargetRPM: Int? {
        smartTargetRPM(for: data, source: .gpu)
    }

    // Hidden fan UI should stop polling SMC and fall back to system fan control.
    var shouldReadFanMetrics: Bool {
        !hiddenMetrics.contains(.fan)
    }

    var shouldReadDiskMetrics: Bool {
        !hiddenMetrics.contains(.disk)
    }

    var shouldReadRAMMetrics: Bool {
        !hiddenMetrics.contains(.ram)
    }

    var shouldReadTemperatureMetrics: Bool {
        !hiddenMetrics.contains(.cpu) || !hiddenMetrics.contains(.gpu) || fanControlSettings.mode == .smart
    }

    var shouldReadComputeMetrics: Bool {
        !hiddenMetrics.contains(.cpu) || !hiddenMetrics.contains(.gpu)
    }

    // Power sampling also feeds the CPU/GPU/RAM detail rows, so keep it alive when
    // any of those sections are visible.
    var shouldReadPowerMetrics: Bool {
        !hiddenMetrics.contains(.power) || !hiddenMetrics.contains(.cpu) || !hiddenMetrics.contains(.gpu) || !hiddenMetrics.contains(.ram)
    }

    // Network sampling is shared by the menu bar metric and the floating overlay.
    var shouldReadNetworkMetrics: Bool {
        !hiddenMetrics.contains(.network) || networkOverlaySettings.isEnabled
    }

    init() {
        do {
            try FileManager.default.createDirectory(at: storageDirURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            // non-fatal
        }

        if let cfg = loadConfigSync() {
            self.intervalMs = cfg.intervalMs
            self.useColoredValues = cfg.useColoredValues
            self.showMetricDividers = cfg.showMetricDividers ?? true
            self.networkDisplayMode = NetworkDisplayMode(rawValue: cfg.networkDisplayMode) ?? .total
            self.diskDisplayMode = DiskDisplayMode(rawValue: cfg.diskDisplayMode ?? "") ?? .readSpeed
            self.networkOverlaySettings = cfg.networkOverlay ?? .defaults
            self.networkSourceName = cfg.networkSourceName
            self.diskSourcePath = cfg.diskSourcePath
            self.metricOrder = Self.normalizedMetricOrder(from: cfg.metricOrder)
            self.hiddenMetrics = Set(cfg.hiddenMetrics.compactMap(MonitorMetric.init(rawValue:)))
            self.thresholds = cfg.thresholds ?? .defaults
            self.fanControlSettings = cfg.fanControl ?? .defaults
        }

        networkReader.setSelectedInterfaceName(networkSourceName)
        diskReader.setSelectedVolumePath(diskSourcePath)

        // Never restore into manual or smart mode while the fan metric is hidden.
        if hiddenMetrics.contains(.fan), fanControlSettings.mode != .system {
            hiddenFanRestoreMode = fanControlSettings.mode
            fanControlSettings.mode = .system
        }

        self.isFanHelperInstalled = fanControlService.isInstalled
        self.isFanHelperReady = false
        // Helper-managed fan control can drift after sleep/wake, so re-apply once macOS settles.
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.reapplyFanControlAfterWake()
            }
        }

        startMonitoring()
    }

    private static func normalizedMetricOrder(from rawValues: [String]) -> [MonitorMetric] {
        var result = rawValues.compactMap(MonitorMetric.init(rawValue:))
        let preferredOrder: [MonitorMetric] = [.network, .cpu, .gpu, .ram, .power, .disk, .fan]
        for metric in preferredOrder where !result.contains(metric) {
            result.append(metric)
        }
        return result
    }

    func startMonitoring() {
        stopMonitoring()
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        let interval = DispatchTimeInterval.milliseconds(max(intervalMs, 250))
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.sampleNativeMetrics()
        }
        samplingTimer = timer
        timer.resume()

        DispatchQueue.main.async {
            self.isRunning = true
            self.isMock = false
            self.mockWarning = nil
        }
    }

    func stopMonitoring() {
        samplingTimer?.cancel()
        samplingTimer = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    private func sampleNativeMetrics() {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }

        let decoded = nativeSampler.sample(
            durationMs: intervalMs,
            request: NativeTelemetryRequest(
                includeComputeMetrics: shouldReadComputeMetrics,
                includeMemoryMetrics: shouldReadRAMMetrics,
                includeTemperatureMetrics: shouldReadTemperatureMetrics,
                includePowerMetrics: shouldReadPowerMetrics
            )
        )
        applySample(decoded)
    }

    private func parseJSON(_ jsonString: String) {
        guard let raw = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MacMonData.self, from: raw) else {
            return
        }
        applySample(decoded)
    }

    // Convert one snapshot into both the latest UI state and the rolling 30-second histories.
    private func applySample(_ decoded: MacMonData) {
        let timestamp = Date().timeIntervalSince1970
        let fans = shouldReadFanMetrics ? fanSensor.readFans() : []
        let cpuY = averagedCPUUsage(for: decoded)
        let gpuY = usageValue(decoded.gpuUsage)
        let ramY = decoded.memory.ramTotal > 0 ? Double(decoded.memory.ramUsage) / Double(decoded.memory.ramTotal) : 0.0
        let powerY = decoded.sysPower
        let fanY = fans.map(\.rpm).max() ?? 0.0
        let disk = shouldReadDiskMetrics
            ? diskReader.read(intervalMs: intervalMs)
            : DiskStats(volumeName: diskStats.volumeName, totalBytes: 0, availableBytes: 0, usedBytes: 0, readBytesPerSecond: 0, writeBytesPerSecond: 0)
        let diskY = disk.readBytesPerSecond
        let network: NetworkThroughput

        if isMock {
            network = shouldReadNetworkMetrics
                ? NetworkThroughput(
                    downloadBytesPerSecond: Double.random(in: 100_000...8_000_000),
                    uploadBytesPerSecond: Double.random(in: 20_000...1_500_000)
                )
                : NetworkThroughput(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        } else {
            network = shouldReadNetworkMetrics
                ? networkReader.read(intervalMs: intervalMs)
                : NetworkThroughput(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        }
        let networkY = network.totalBytesPerSecond

        DispatchQueue.main.async {
            self.data = decoded
            self.fanReadings = fans
            self.networkThroughput = network
            self.diskStats = disk
            self.appendSample(&self.cpuHistory, value: cpuY, timestamp: timestamp)
            self.appendSample(&self.gpuHistory, value: gpuY, timestamp: timestamp)
            self.appendSample(&self.ramHistory, value: ramY, timestamp: timestamp)
            self.appendSample(&self.powerHistory, value: powerY, timestamp: timestamp)
            self.appendSample(&self.fanHistory, value: fanY, timestamp: timestamp)
            self.appendSample(&self.networkHistory, value: networkY, timestamp: timestamp)
            self.appendSample(&self.diskHistory, value: diskY, timestamp: timestamp)
            self.syncFanControl(with: decoded)
        }
    }

    private func averagedCPUUsage(for data: MacMonData) -> Double {
        let e = usageValue(data.ecpuUsage)
        let p = usageValue(data.pcpuUsage)
        if data.ecpuUsage.count >= 2 && data.pcpuUsage.count >= 2 {
            return (e + p) / 2.0
        }
        return max(e, p)
    }

    private func usageValue(_ usage: [Double]) -> Double {
        guard usage.count >= 2 else { return 0.0 }
        return usage[1]
    }

    // Every chart uses the same fixed-length rolling window for consistent visual rhythm.
    private func appendSample(_ history: inout [ResourcePoint], value: Double, timestamp: Double) {
        history.append(ResourcePoint(x: timestamp, y: value))
        let cutoff = timestamp - 30.0
        history.removeAll { $0.x < cutoff }
    }

    private func loadConfigSync() -> Config? {
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: configURL.path) {
                let data = try Data(contentsOf: configURL)
                let cfg = try JSONDecoder().decode(Config.self, from: data)
                if cfg.intervalMs >= 1 {
                    return cfg
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.mockWarning = "Failed to load config: \(error.localizedDescription)"
            }
        }
        return nil
    }

    // Persist settings off the main thread because menu edits can happen frequently.
    private func saveConfig() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let cfg = Config(
                    intervalMs: self.intervalMs,
                    useColoredValues: self.useColoredValues,
                    showMetricDividers: self.showMetricDividers,
                    networkDisplayMode: self.networkDisplayMode.rawValue,
                    diskDisplayMode: self.diskDisplayMode.rawValue,
                    networkOverlay: self.networkOverlaySettings,
                    networkSourceName: self.networkSourceName,
                    diskSourcePath: self.diskSourcePath,
                    metricOrder: self.metricOrder.map(\.rawValue),
                    hiddenMetrics: self.hiddenMetrics.map(\.rawValue),
                    thresholds: self.thresholds,
                    fanControl: self.fanControlSettings
                )
                let data = try JSONEncoder().encode(cfg)
                try data.write(to: self.configURL, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    self.mockWarning = "Failed to save config: \(error.localizedDescription)"
                }
            }
        }
    }

    func setInterval(ms: Int) {
        let newMs = max(500, ms)
        DispatchQueue.main.async {
            self.intervalMs = newMs
            self.saveConfig()
            if !self.isMock {
                self.startMonitoring()
            } else {
                self.startMockTimer()
            }
        }
    }

    func setUseColoredValues(_ enabled: Bool) {
        DispatchQueue.main.async {
            self.useColoredValues = enabled
            self.saveConfig()
        }
    }

    func setShowMetricDividers(_ enabled: Bool) {
        DispatchQueue.main.async {
            self.showMetricDividers = enabled
            self.saveConfig()
        }
    }

    func setNetworkDisplayMode(_ mode: NetworkDisplayMode) {
        DispatchQueue.main.async {
            self.networkDisplayMode = mode
            self.saveConfig()
        }
    }

    func setDiskDisplayMode(_ mode: DiskDisplayMode) {
        DispatchQueue.main.async {
            self.diskDisplayMode = mode
            self.saveConfig()
        }
    }

    func setNetworkSourceName(_ name: String?) {
        DispatchQueue.main.async {
            self.networkSourceName = name
            self.networkReader.setSelectedInterfaceName(name)
            self.saveConfig()
        }
    }

    func setDiskSourcePath(_ path: String?) {
        DispatchQueue.main.async {
            self.diskSourcePath = path
            self.diskReader.setSelectedVolumePath(path)
            self.saveConfig()
        }
    }

    func setNetworkOverlayEnabled(_ enabled: Bool) {
        DispatchQueue.main.async {
            self.networkOverlaySettings.isEnabled = enabled
            self.saveConfig()
        }
    }

    func setNetworkOverlayShowsUpload(_ showsUpload: Bool) {
        DispatchQueue.main.async {
            // Keep at least one traffic lane visible while the overlay is enabled.
            if !showsUpload && !self.networkOverlaySettings.showsDownload {
                return
            }
            self.networkOverlaySettings.showsUpload = showsUpload
            self.saveConfig()
        }
    }

    func setNetworkOverlayShowsDownload(_ showsDownload: Bool) {
        DispatchQueue.main.async {
            // Keep at least one traffic lane visible while the overlay is enabled.
            if !showsDownload && !self.networkOverlaySettings.showsUpload {
                return
            }
            self.networkOverlaySettings.showsDownload = showsDownload
            self.saveConfig()
        }
    }

    func setNetworkOverlayClickThrough(_ clickThrough: Bool) {
        DispatchQueue.main.async {
            self.networkOverlaySettings.clickThrough = clickThrough
            self.saveConfig()
        }
    }

    func setNetworkOverlayOpacity(_ opacity: Double) {
        DispatchQueue.main.async {
            self.networkOverlaySettings.opacity = min(max(opacity, 0.25), 1.0)
            self.saveConfig()
        }
    }

    func setNetworkOverlayStyle(_ style: NetworkOverlayStyle) {
        DispatchQueue.main.async {
            self.networkOverlaySettings.style = style
            self.saveConfig()
        }
    }

    func setNetworkOverlaySize(_ size: NetworkOverlaySize) {
        DispatchQueue.main.async {
            self.networkOverlaySettings.size = size
            self.saveConfig()
        }
    }

    func setNetworkOverlayOrigin(_ origin: CGPoint) {
        DispatchQueue.main.async {
            self.networkOverlaySettings.originX = origin.x
            self.networkOverlaySettings.originY = origin.y
            self.saveConfig()
        }
    }

    func setThresholds(_ thresholds: MetricThresholds) {
        DispatchQueue.main.async {
            self.thresholds = thresholds
            self.saveConfig()
        }
    }

    func setFanControlMode(_ mode: FanControlMode) {
        DispatchQueue.main.async {
            self.fanControlError = nil
            self.isFanHelperStatusPending = false

            if mode != .system {
                self.hiddenFanRestoreMode = nil
            }
            if mode != .smart {
                self.resetSmartTargetSmoothingState()
            }

            if mode != .system {
                if !self.fanControlService.isInstalled {
                    let alert = NSAlert()
                    alert.messageText = "Install Fan Helper?"
                    alert.informativeText = "Manual and Smart fan control need a privileged helper. You can manage it later from the status dot in Fan Control."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Install")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() != .alertFirstButtonReturn {
                        return
                    }
                }
                if self.fanControlSettings.helperToken == nil {
                    self.fanControlSettings.helperToken = UUID().uuidString
                }
                guard let token = self.fanControlSettings.helperToken else { return }
                do {
                    try self.fanControlService.installIfNeeded(token: token)
                    self.isFanHelperInstalled = self.fanControlService.isInstalled
                    self.isFanHelperReady = false
                    self.isFanHelperStatusPending = true
                } catch {
                    self.fanControlError = error.localizedDescription
                    self.isFanHelperInstalled = self.fanControlService.isInstalled
                    self.isFanHelperReady = false
                    self.isFanHelperStatusPending = false
                    return
                }
            }

            if mode == .smart, let error = Self.validateSmartRules(self.fanControlSettings.smartRules) {
                self.fanControlError = error
                return
            }

            // Seed a machine-aware default curve the first time smart mode is used.
            if mode == .smart, self.fanControlSettings.smartRules.isEmpty {
                self.fanControlSettings.smartRules = self.defaultSmartCurvePoints(
                    maxRPM: self.currentFanMaxRPM,
                    minRPM: self.currentFanMinRPM
                )
            }

            if mode == .manual, self.fanControlSettings.manualRPM <= 0 {
                let fallback = max(self.currentFanMinRPM ?? 0, (self.currentFanMaxRPM ?? 3000) * 0.6)
                self.fanControlSettings.manualRPM = fallback.rounded()
            }

            self.fanControlSettings.mode = mode
            self.saveConfig()
            self.applyCurrentFanControl()
        }
    }

    func installFanHelperIfNeeded() -> Bool {
        if fanControlSettings.helperToken == nil {
            fanControlSettings.helperToken = UUID().uuidString
        }
        guard let token = fanControlSettings.helperToken else { return false }
        do {
            try fanControlService.installIfNeeded(token: token)
            isFanHelperInstalled = fanControlService.isInstalled
            saveConfig()
            return isFanHelperInstalled
        } catch {
            fanControlError = error.localizedDescription
            isFanHelperInstalled = fanControlService.isInstalled
            return false
        }
    }

    func uninstallFanHelper() -> Bool {
        do {
            try fanControlService.uninstallIfPresent()
            isFanHelperInstalled = fanControlService.isInstalled
            isFanHelperReady = false
            isFanHelperStatusPending = false
            return !isFanHelperInstalled
        } catch {
            fanControlError = error.localizedDescription
            return false
        }
    }

    func setManualFanRPM(_ rpm: Double) {
        DispatchQueue.main.async {
            self.fanControlSettings.manualRPM = rpm
            self.saveConfig()
            guard self.fanControlSettings.mode == .manual else { return }
            self.applyCurrentFanControl()
        }
    }

    // Normalize editor output before saving so runtime logic can assume stable RPM steps.
    func setSmartFanRules(_ rules: [FanSmartCurvePoint]) -> Bool {
        let normalizedRules = Self.normalizedSmartRules(rules)
        if let error = Self.validateSmartRules(normalizedRules) {
            if Thread.isMainThread {
                self.fanControlError = error
            } else {
                DispatchQueue.main.async {
                    self.fanControlError = error
                }
            }
            return false
        }

        let applyChanges = {
            self.fanControlError = nil
            self.fanControlSettings.smartRules = normalizedRules
            self.saveConfig()
            if self.fanControlSettings.mode == .smart {
                self.applyCurrentFanControl()
            }
        }
        if Thread.isMainThread {
            applyChanges()
        } else {
            DispatchQueue.main.async(execute: applyChanges)
        }
        return true
    }

    func resetFanControlForExit() {
        guard let token = fanControlSettings.helperToken, isFanHelperInstalled else { return }
        resetSmartTargetSmoothingState()
        _ = fanControlService.applySynchronously(FanControlCommand(mode: .system, targetRPM: nil), token: token)
    }

    func reapplyFanControlAfterWake() {
        guard fanControlSettings.mode != .system else { return }
        applyCurrentFanControl(force: true)
    }

    func setMetricVisibility(_ metric: MonitorMetric, isVisible: Bool) {
        DispatchQueue.main.async {
            if isVisible {
                self.hiddenMetrics.remove(metric)
            } else {
                self.hiddenMetrics.insert(metric)
            }
            self.syncFanMetricVisibilityState()
            self.saveConfig()
        }
    }

    func applyDisplayConfiguration(visibleMetrics: [MonitorMetric], hiddenMetrics: [MonitorMetric]) {
        DispatchQueue.main.async {
            var combined: [MonitorMetric] = []
            for metric in visibleMetrics + hiddenMetrics where !combined.contains(metric) {
                combined.append(metric)
            }
            for metric in [MonitorMetric.network, .cpu, .gpu, .ram, .power, .disk, .fan] where !combined.contains(metric) {
                combined.append(metric)
            }

            self.metricOrder = combined
            self.hiddenMetrics = Set(hiddenMetrics)
            self.syncFanMetricVisibilityState()
            self.saveConfig()
        }
    }

    func moveMetric(_ metric: MonitorMetric, by offset: Int) {
        DispatchQueue.main.async {
            guard let currentIndex = self.metricOrder.firstIndex(of: metric) else { return }
            let newIndex = max(0, min(self.metricOrder.count - 1, currentIndex + offset))
            guard newIndex != currentIndex else { return }
            self.metricOrder.remove(at: currentIndex)
            self.metricOrder.insert(metric, at: newIndex)
            self.saveConfig()
        }
    }

    func canMoveMetric(_ metric: MonitorMetric, by offset: Int) -> Bool {
        guard let currentIndex = metricOrder.firstIndex(of: metric) else { return false }
        let newIndex = currentIndex + offset
        return metricOrder.indices.contains(newIndex)
    }

    func startMockTimer() {
        mockTimer?.invalidate()
        let seconds = Double(intervalMs) / 1000.0
        mockTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let mockJSON = """
            {
              "timestamp": "2025-02-24T20:38:15",
              "temp": { "cpu_temp_avg": \(Double.random(in: 40...80)), "gpu_temp_avg": \(Double.random(in: 35...60)) },
              "memory": { "ram_total": 17179869184, "ram_usage": \(Int64.random(in: 8000000000...16000000000)), "swap_total": 0, "swap_usage": 0 },
              "ecpu_usage": [1181, \(Double.random(in: 0...1))],
              "pcpu_usage": [1974, \(Double.random(in: 0...1))],
              "gpu_usage": [461, \(Double.random(in: 0...1))],
              "cpu_power": \(Double.random(in: 5...20)),
              "gpu_power": \(Double.random(in: 1...10)),
              "ane_power": 0.0,
              "all_power": \(Double.random(in: 10...40)),
              "sys_power": \(Double.random(in: 15...50)),
              "ram_power": 0.5,
              "gpu_ram_power": 0.1
            }
            """
            self.parseJSON(mockJSON)
        }
    }

    func stopMockTimer() {
        mockTimer?.invalidate()
        mockTimer = nil
    }

    deinit {
        mockTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func applyCurrentFanControl(force: Bool = false) {
        syncFanControl(with: data, force: force)
    }

    // Hiding fan UI is treated as an explicit "hands off" signal. Restore the previous
    // non-system mode automatically when the metric becomes visible again.
    private func syncFanMetricVisibilityState() {
        let isFanVisible = !hiddenMetrics.contains(.fan)
        if !isFanVisible {
            if fanControlSettings.mode != .system {
                hiddenFanRestoreMode = fanControlSettings.mode
                fanControlSettings.mode = .system
                resetSmartTargetSmoothingState()
                saveConfig()
                applyCurrentFanControl(force: true)
            }
            return
        }

        if fanControlSettings.mode == .system, let restoreMode = hiddenFanRestoreMode {
            hiddenFanRestoreMode = nil
            fanControlSettings.mode = restoreMode
            saveConfig()
            applyCurrentFanControl(force: true)
        }
    }

    // Avoid hammering the helper when nothing material changed, but re-apply if the
    // actual RPM drifts far enough away from the desired target.
    private func syncFanControl(with data: MacMonData?, force: Bool = false) {
        let command = resolvedFanControlCommand(for: data)

        if !force, lastAppliedFanCommand == command, !fanControlCommandNeedsReapply(command) {
            return
        }

        guard let token = fanControlSettings.helperToken, command.mode != .system || isFanHelperInstalled else {
            return
        }

        if command.mode != .system {
            isFanHelperInstalled = fanControlService.isInstalled
        }
        fanControlService.apply(command, token: token) { [weak self] ok, message in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.lastAppliedFanCommand = command
                    self.isFanHelperStatusPending = false
                    if self.fanControlSettings.mode != .system {
                        self.isFanHelperReady = true
                    }
                    if self.fanControlError == "Applying fan control failed." || self.fanControlError == message {
                        self.fanControlError = nil
                    }
                } else {
                    self.lastAppliedFanCommand = nil
                    self.isFanHelperStatusPending = false
                    if self.fanControlSettings.mode != .system {
                        self.isFanHelperReady = false
                    }
                    self.fanControlError = message ?? "Applying fan control failed."
                }
            }
        }
    }

    private func fanControlCommandNeedsReapply(_ command: FanControlCommand) -> Bool {
        guard fanControlSettings.mode != .system else {
            return false
        }
        guard let targetRPM = command.targetRPM else {
            return false
        }
        guard let currentRPM = currentFanRPM else {
            return true
        }

        let tolerance = max(150.0, Double(targetRPM) * 0.12)
        return abs(currentRPM - Double(targetRPM)) > tolerance
    }

    // Translate UI mode into one helper command. Smart mode may temporarily fall back to
    // system mode while waiting for a stable target.
    private func resolvedFanControlCommand(for data: MacMonData?) -> FanControlCommand {
        switch fanControlSettings.mode {
            case .system:
                resetSmartTargetSmoothingState()
                return FanControlCommand(mode: .system, targetRPM: nil)
            case .manual:
                resetSmartTargetSmoothingState()
                return FanControlCommand(mode: .manual, targetRPM: Int(fanControlSettings.manualRPM.rounded()))
            case .smart:
                guard let targetRPM = stabilizedSmartTargetRPM(for: smartTargetRPM(for: data), now: Date()) else {
                    return FanControlCommand(mode: .system, targetRPM: nil)
                }
                return FanControlCommand(mode: .smart, targetRPM: targetRPM)
        }
    }

    // Build a conservative per-machine default curve instead of assuming one RPM range
    // fits every Mac.
    func defaultSmartCurvePoints(maxRPM: Double?, minRPM: Double?) -> [FanSmartCurvePoint] {
        let maxValue = max(maxRPM ?? currentFanMaxRPM ?? 3000, 1000)
        let minValue = max(minRPM ?? currentFanMinRPM ?? 0, 0)
        let baselineRPM = Self.snapRPM(max(Int(minValue.rounded()), 0))
        let elevatedRPM = max(baselineRPM, Self.snapRPM(Int((maxValue * 0.5).rounded())))
        let hotRPM = max(elevatedRPM, Self.snapRPM(Int((maxValue * 0.75).rounded())))

        return FanRuleSource.allCases.flatMap { source in
            FanSmartCurveDefaults.temperatures.map { temperature in
                let rpm: Int
                switch temperature {
                    case 90...:
                        rpm = hotRPM
                    case 70...:
                        rpm = elevatedRPM
                    default:
                        rpm = baselineRPM
                }
                return FanSmartCurvePoint(source: source, temperature: temperature, targetRPM: rpm)
            }
        }
    }

    // CPU and GPU can request different RPMs; pick the safer higher target.
    private func smartTargetRPM(for data: MacMonData?) -> Int? {
        let cpuTarget = smartTargetRPM(for: data, source: .cpu)
        let gpuTarget = smartTargetRPM(for: data, source: .gpu)
        return [cpuTarget, gpuTarget].compactMap { $0 }.max()
    }

    // Combine hysteresis and rate limiting so temperatures near a boundary do not cause
    // immediate target flips or abrupt RPM jumps.
    private func stabilizedSmartTargetRPM(for desiredTargetRPM: Int?, now: Date) -> Int? {
        guard let desiredTargetRPM else {
            resetSmartTargetSmoothingState()
            return nil
        }

        if activeSmartTargetRPM == nil {
            activeSmartTargetRPM = desiredTargetRPM
            smoothedSmartTargetRPM = desiredTargetRPM
            pendingSmartTargetRPM = nil
            pendingSmartTargetSince = nil
            lastSmartRampAt = now
            return desiredTargetRPM
        }

        if activeSmartTargetRPM != desiredTargetRPM {
            if pendingSmartTargetRPM != desiredTargetRPM {
                pendingSmartTargetRPM = desiredTargetRPM
                pendingSmartTargetSince = now
            } else if let pendingSince = pendingSmartTargetSince,
                      now.timeIntervalSince(pendingSince) >= smartTargetSettleDuration {
                activeSmartTargetRPM = desiredTargetRPM
                pendingSmartTargetRPM = nil
                pendingSmartTargetSince = nil
            }
        } else {
            pendingSmartTargetRPM = nil
            pendingSmartTargetSince = nil
        }

        let targetRPM = activeSmartTargetRPM ?? desiredTargetRPM
        let currentRPM = smoothedSmartTargetRPM ?? targetRPM
        let elapsed = max(lastSmartRampAt.map { now.timeIntervalSince($0) } ?? (Double(intervalMs) / 1000.0), 0.1)
        lastSmartRampAt = now

        if currentRPM == targetRPM {
            smoothedSmartTargetRPM = currentRPM
            return currentRPM
        }

        let maxDelta = max(50, Int((smartTargetRampRateRPMPerSecond * elapsed).rounded()))
        let nextRPM: Int
        if currentRPM < targetRPM {
            nextRPM = min(currentRPM + maxDelta, targetRPM)
        } else {
            nextRPM = max(currentRPM - maxDelta, targetRPM)
        }

        let snappedNext = Self.snapRPM(nextRPM)
        let clampedNext: Int
        if currentRPM < targetRPM {
            clampedNext = min(snappedNext, targetRPM)
        } else {
            clampedNext = max(snappedNext, targetRPM)
        }

        smoothedSmartTargetRPM = clampedNext
        return clampedNext
    }

    // Resolve one curve point for the current source, falling back to the generated
    // default curve until the user customizes it.
    private func smartTargetRPM(for data: MacMonData?, source: FanRuleSource) -> Int? {
        guard let data else { return nil }
        let temperature = source == .cpu ? data.temp.cpuTempAvg : data.temp.gpuTempAvg
        let bucket = smartTemperatureBucket(for: temperature)
        if let target = fanControlSettings.smartRules
            .first(where: { $0.source == source && $0.temperature == bucket })?
            .targetRPM {
            return target
        }

        return defaultSmartCurvePoints(maxRPM: currentFanMaxRPM, minRPM: currentFanMinRPM)
            .first(where: { $0.source == source && $0.temperature == bucket })?
            .targetRPM
    }

    // Clamp into the editable 40...100°C range and snap to the 5°C curve buckets.
    private func smartTemperatureBucket(for temperature: Double) -> Int {
        let minTemperature = FanSmartCurveDefaults.temperatures.first ?? 40
        let maxTemperature = FanSmartCurveDefaults.temperatures.last ?? 100
        let clampedTemperature = min(max(temperature, Double(minTemperature)), Double(maxTemperature))
        let bucket = Int((clampedTemperature / 5.0).rounded(.down) * 5.0)
        return min(max(bucket, minTemperature), maxTemperature)
    }

    static func validateSmartRules(_ rules: [FanSmartCurvePoint]) -> String? {
        for rule in rules {
            if rule.targetRPM < 0 {
                return "Fan smart curve values cannot use negative RPM values."
            }
            if !FanSmartCurveDefaults.temperatures.contains(rule.temperature) {
                return "Smart curve temperatures must use 5°C steps."
            }
        }
        return nil
    }

    private static func normalizedSmartRules(_ rules: [FanSmartCurvePoint]) -> [FanSmartCurvePoint] {
        rules.map { rule in
            var normalized = rule
            normalized.targetRPM = snapRPM(rule.targetRPM)
            return normalized
        }
    }

    private static func snapRPM(_ rpm: Int, step: Int = 100) -> Int {
        let safeStep = max(step, 1)
        return max(0, Int((Double(rpm) / Double(safeStep)).rounded() * Double(safeStep)))
    }

    private func resetSmartTargetSmoothingState() {
        pendingSmartTargetRPM = nil
        pendingSmartTargetSince = nil
        activeSmartTargetRPM = nil
        smoothedSmartTargetRPM = nil
        lastSmartRampAt = nil
    }
}
