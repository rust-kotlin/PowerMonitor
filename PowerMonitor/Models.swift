import Foundation

// Core telemetry models mirrored from macmon's JSON output.
struct MacMonData: Codable {
    let timestamp: String
    let temp: Temp
    var memory: Memory
    
    // Usage arrays contain [frequency, utilization].
    let ecpuUsage: [Double]
    let pcpuUsage: [Double]
    let gpuUsage: [Double]
    
    // Power fields are expressed in watts.
    let cpuPower: Double
    let gpuPower: Double
    let anePower: Double
    let allPower: Double
    let sysPower: Double
    let ramPower: Double
    let gpuRamPower: Double
    
    enum CodingKeys: String, CodingKey {
        case timestamp, temp, memory
        case ecpuUsage = "ecpu_usage"
        case pcpuUsage = "pcpu_usage"
        case gpuUsage = "gpu_usage"
        case cpuPower = "cpu_power"
        case gpuPower = "gpu_power"
        case anePower = "ane_power"
        case allPower = "all_power"
        case sysPower = "sys_power"
        case ramPower = "ram_power"
        case gpuRamPower = "gpu_ram_power"
    }
}

struct Temp: Codable {
    let cpuTempAvg: Double
    let gpuTempAvg: Double
    
    enum CodingKeys: String, CodingKey {
        case cpuTempAvg = "cpu_temp_avg"
        case gpuTempAvg = "gpu_temp_avg"
    }
}

struct Memory: Codable {
    let ramTotal: Int64
    let ramUsage: Int64
    let swapTotal: Int64
    let swapUsage: Int64
    let appMemory: Int64?
    let wiredMemory: Int64?
    let compressedMemory: Int64?
    let cachedFiles: Int64?
    let freeMemory: Int64?
    let pressureLevel: MemoryPressureLevel?
    
    enum CodingKeys: String, CodingKey {
        case ramTotal = "ram_total"
        case ramUsage = "ram_usage"
        case swapTotal = "swap_total"
        case swapUsage = "swap_usage"
        case appMemory = "app_memory"
        case wiredMemory = "wired_memory"
        case compressedMemory = "compressed_memory"
        case cachedFiles = "cached_files"
        case freeMemory = "free_memory"
        case pressureLevel = "pressure_level"
    }
}

enum MemoryPressureLevel: String, Codable {
    case normal
    case warning
    case critical

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

enum MonitorMetric: String, CaseIterable, Codable, Identifiable, Hashable {
    case disk
    case cpu
    case gpu
    case ram
    case power
    case fan
    case network

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
            case .disk: return "SSD"
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .ram: return "RAM"
            case .power: return "PWR"
            case .fan: return "FAN"
            case .network: return "NET"
        }
    }

    var menuTitle: String {
        switch self {
            case .disk: return "Disk"
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .ram: return "RAM"
            case .power: return "Power"
            case .fan: return "Fan"
            case .network: return "Network"
        }
    }

    var detailTitle: String {
        switch self {
            case .disk: return "Storage"
            case .cpu: return "CPU Status"
            case .gpu: return "GPU Status"
            case .ram: return "Memory"
            case .power: return "Power Info"
            case .fan: return "Fan Speed"
            case .network: return "Network Speed"
        }
    }
}

struct FanReading: Identifiable, Codable, Equatable {
    let id: Int
    let rpm: Double
    let minRPM: Double?
    let maxRPM: Double?

    var name: String {
        return "Fan \(id + 1)"
    }
}

enum FanSmartCurveDefaults {
    static let temperatures: [Int] = Array(stride(from: 40, through: 100, by: 5))
}

enum FanControlMode: String, Codable, CaseIterable {
    case system
    case manual
    case smart

    var title: String {
        switch self {
            case .system: return "System"
            case .manual: return "Manual"
            case .smart: return "Smart"
        }
    }
}

enum FanRuleSource: String, Codable, CaseIterable, Identifiable {
    case cpu
    case gpu

    var id: String { rawValue }

    var title: String {
        switch self {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
        }
    }
}

struct FanSmartCurvePoint: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var source: FanRuleSource
    var temperature: Int
    var targetRPM: Int
}

struct FanControlSettings: Codable, Equatable {
    private struct LegacyRule: Decodable {
        let source: FanRuleSource
        let minTemp: Double
        let maxTemp: Double
        let targetRPM: Int
    }

    var mode: FanControlMode
    var manualRPM: Double
    var smartRules: [FanSmartCurvePoint]
    var helperToken: String?

    static let defaults = FanControlSettings(
        mode: .system,
        manualRPM: 0,
        smartRules: [],
        helperToken: nil
    )

    enum CodingKeys: String, CodingKey {
        case mode
        case manualRPM
        case smartRules
        case helperToken
    }

    init(mode: FanControlMode, manualRPM: Double, smartRules: [FanSmartCurvePoint], helperToken: String?) {
        self.mode = mode
        self.manualRPM = manualRPM
        self.smartRules = smartRules
        self.helperToken = helperToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(FanControlMode.self, forKey: .mode) ?? .system
        manualRPM = try container.decodeIfPresent(Double.self, forKey: .manualRPM) ?? 0
        helperToken = try container.decodeIfPresent(String.self, forKey: .helperToken)

        if let points = try? container.decode([FanSmartCurvePoint].self, forKey: .smartRules) {
            smartRules = points
            return
        }

        let legacyRules = (try? container.decode([LegacyRule].self, forKey: .smartRules)) ?? []
        smartRules = Self.migrateLegacyRules(legacyRules)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(manualRPM, forKey: .manualRPM)
        try container.encode(smartRules, forKey: .smartRules)
        try container.encodeIfPresent(helperToken, forKey: .helperToken)
    }

    private static func migrateLegacyRules(_ rules: [LegacyRule]) -> [FanSmartCurvePoint] {
        guard !rules.isEmpty else { return [] }
        var migrated: [FanSmartCurvePoint] = []
        for source in FanRuleSource.allCases {
            let scoped = rules.filter { $0.source == source }
            for temperature in FanSmartCurveDefaults.temperatures {
                if let match = scoped.first(where: { Double(temperature) >= $0.minTemp && Double(temperature) < $0.maxTemp }) {
                    migrated.append(FanSmartCurvePoint(source: source, temperature: temperature, targetRPM: match.targetRPM))
                }
            }
        }
        return migrated
    }
}

struct NetworkThroughput: Equatable {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double

    var totalBytesPerSecond: Double {
        downloadBytesPerSecond + uploadBytesPerSecond
    }
}

struct NetworkInterfaceOption: Identifiable, Hashable {
    let id: String
    let title: String
}

struct DiskStats: Equatable {
    let volumeName: String
    let totalBytes: Int64
    let availableBytes: Int64
    let usedBytes: Int64
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double

    var totalBytesPerSecond: Double {
        readBytesPerSecond + writeBytesPerSecond
    }
}

struct DiskVolumeOption: Identifiable, Hashable {
    let id: String
    let title: String
    let path: String
}

enum NetworkDisplayMode: String, Codable, CaseIterable {
    case upload
    case download
    case total

    var menuTitle: String {
        switch self {
            case .upload: return "NET: Up"
            case .download: return "NET: Down"
            case .total: return "NET: Total"
        }
    }
}

enum DiskDisplayMode: String, Codable, CaseIterable {
    case readSpeed
    case usage

    var menuTitle: String {
        switch self {
            case .readSpeed: return "SSD: Read Speed"
            case .usage: return "SSD: Usage"
        }
    }
}

struct NetworkOverlaySettings: Codable, Equatable {
    var isEnabled: Bool
    var showsUpload: Bool
    var showsDownload: Bool
    var clickThrough: Bool
    var opacity: Double
    var style: NetworkOverlayStyle
    var size: NetworkOverlaySize
    // Persist the last panel origin so the overlay can reopen where the user left it.
    var originX: Double?
    var originY: Double?

    static let defaults = NetworkOverlaySettings(
        isEnabled: false,
        showsUpload: true,
        showsDownload: true,
        clickThrough: false,
        opacity: 0.88,
        style: .compact,
        size: .regular,
        originX: nil,
        originY: nil
    )
}

enum NetworkOverlayStyle: String, Codable, CaseIterable {
    case compact
    case stacked
    case split
    case minimal
    case capsule
    case hud

    var menuTitle: String {
        switch self {
            case .compact: return "Compact"
            case .stacked: return "Stacked"
            case .split: return "Split"
            case .minimal: return "Minimal"
            case .capsule: return "Capsule"
            case .hud: return "HUD"
        }
    }
}

enum NetworkOverlaySize: String, Codable, CaseIterable {
    case compact
    case regular
    case large

    var menuTitle: String {
        switch self {
            case .compact: return "Compact"
            case .regular: return "Regular"
            case .large: return "Large"
        }
    }
}

struct MetricThresholds: Codable, Equatable {
    var diskYellow: Double
    var diskRed: Double
    var diskUsageYellow: Double
    var diskUsageRed: Double
    var cpuYellow: Double
    var cpuRed: Double
    var gpuYellow: Double
    var gpuRed: Double
    var ramYellow: Double
    var ramRed: Double
    var powerYellow: Double
    var powerRed: Double
    var fanYellow: Double
    var fanRed: Double
    var networkYellow: Double
    var networkRed: Double

    static let defaults = MetricThresholds(
        diskYellow: 50_000_000,
        diskRed: 200_000_000,
        diskUsageYellow: 75,
        diskUsageRed: 90,
        cpuYellow: 50,
        cpuRed: 80,
        gpuYellow: 50,
        gpuRed: 80,
        ramYellow: 85,
        ramRed: 95,
        powerYellow: 8,
        powerRed: 16,
        fanYellow: 0.5,
        fanRed: 0.75,
        networkYellow: 3_000_000,
        networkRed: 10_000_000
    )

    enum CodingKeys: String, CodingKey {
        case diskYellow, diskRed
        case diskUsageYellow, diskUsageRed
        case cpuYellow, cpuRed
        case gpuYellow, gpuRed
        case ramYellow, ramRed
        case powerYellow, powerRed
        case fanYellow, fanRed
        case networkYellow, networkRed
    }

    init(
        diskYellow: Double,
        diskRed: Double,
        diskUsageYellow: Double,
        diskUsageRed: Double,
        cpuYellow: Double,
        cpuRed: Double,
        gpuYellow: Double,
        gpuRed: Double,
        ramYellow: Double,
        ramRed: Double,
        powerYellow: Double,
        powerRed: Double,
        fanYellow: Double,
        fanRed: Double,
        networkYellow: Double,
        networkRed: Double
    ) {
        self.diskYellow = diskYellow
        self.diskRed = diskRed
        self.diskUsageYellow = diskUsageYellow
        self.diskUsageRed = diskUsageRed
        self.cpuYellow = cpuYellow
        self.cpuRed = cpuRed
        self.gpuYellow = gpuYellow
        self.gpuRed = gpuRed
        self.ramYellow = ramYellow
        self.ramRed = ramRed
        self.powerYellow = powerYellow
        self.powerRed = powerRed
        self.fanYellow = fanYellow
        self.fanRed = fanRed
        self.networkYellow = networkYellow
        self.networkRed = networkRed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        diskYellow = try container.decodeIfPresent(Double.self, forKey: .diskYellow) ?? Self.defaults.diskYellow
        diskRed = try container.decodeIfPresent(Double.self, forKey: .diskRed) ?? Self.defaults.diskRed
        diskUsageYellow = try container.decodeIfPresent(Double.self, forKey: .diskUsageYellow) ?? Self.defaults.diskUsageYellow
        diskUsageRed = try container.decodeIfPresent(Double.self, forKey: .diskUsageRed) ?? Self.defaults.diskUsageRed
        cpuYellow = try container.decodeIfPresent(Double.self, forKey: .cpuYellow) ?? Self.defaults.cpuYellow
        cpuRed = try container.decodeIfPresent(Double.self, forKey: .cpuRed) ?? Self.defaults.cpuRed
        gpuYellow = try container.decodeIfPresent(Double.self, forKey: .gpuYellow) ?? Self.defaults.gpuYellow
        gpuRed = try container.decodeIfPresent(Double.self, forKey: .gpuRed) ?? Self.defaults.gpuRed
        ramYellow = try container.decodeIfPresent(Double.self, forKey: .ramYellow) ?? Self.defaults.ramYellow
        ramRed = try container.decodeIfPresent(Double.self, forKey: .ramRed) ?? Self.defaults.ramRed
        powerYellow = try container.decodeIfPresent(Double.self, forKey: .powerYellow) ?? Self.defaults.powerYellow
        powerRed = try container.decodeIfPresent(Double.self, forKey: .powerRed) ?? Self.defaults.powerRed
        fanYellow = try container.decodeIfPresent(Double.self, forKey: .fanYellow) ?? Self.defaults.fanYellow
        fanRed = try container.decodeIfPresent(Double.self, forKey: .fanRed) ?? Self.defaults.fanRed
        networkYellow = try container.decodeIfPresent(Double.self, forKey: .networkYellow) ?? Self.defaults.networkYellow
        networkRed = try container.decodeIfPresent(Double.self, forKey: .networkRed) ?? Self.defaults.networkRed
    }
}
