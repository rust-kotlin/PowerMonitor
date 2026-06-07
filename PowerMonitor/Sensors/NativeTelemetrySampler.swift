import Foundation
import IOKit
import Darwin

// Produces the same high-level payload shape as macmon, but entirely from in-process
// Swift readers so the app no longer depends on a helper binary for core telemetry.
final class NativeTelemetrySampler {
    private let socInfo = NativeSocInfo.current()
    private let ioReportSampler = IOReportSampler()
    private let memoryReader = MemoryStatsReader()
    private let smc = SMCConnection()
    private lazy var temperatureKeys = discoverTemperatureKeys()
    private let isoFormatter = ISO8601DateFormatter()

    func sample(durationMs: Int, request: NativeTelemetryRequest) -> MacMonData {
        let fallbackMemory = Memory(
            ramTotal: 0,
            ramUsage: 0,
            swapTotal: 0,
            swapUsage: 0,
            appMemory: nil,
            wiredMemory: nil,
            compressedMemory: nil,
            cachedFiles: nil,
            freeMemory: nil,
            pressureLevel: nil
        )

        let shouldReadIOReport = request.includeComputeMetrics || request.includePowerMetrics
        let ioMetrics = shouldReadIOReport
            ? ioReportSampler.sample(durationMs: durationMs, socInfo: socInfo)
            : NativeIOReportMetrics()
        let memory = request.includeMemoryMetrics
            ? memoryReader.read(fallback: fallbackMemory)
            : fallbackMemory
        let temp = request.includeTemperatureMetrics ? readTemperatures() : Temp(cpuTempAvg: 0, gpuTempAvg: 0)

        let cpuPower = request.includePowerMetrics ? ioMetrics.cpuPower : 0
        let gpuPower = request.includePowerMetrics ? ioMetrics.gpuPower : 0
        let anePower = request.includePowerMetrics ? ioMetrics.anePower : 0
        let ramPower = request.includePowerMetrics ? ioMetrics.ramPower : 0
        let gpuRamPower = request.includePowerMetrics ? ioMetrics.gpuRamPower : 0
        let allPower = cpuPower + gpuPower + anePower
        let sysPower = request.includePowerMetrics ? max(smc.readNumericValue("PSTR") ?? 0, allPower) : 0

        return MacMonData(
            timestamp: isoFormatter.string(from: Date()),
            temp: temp,
            memory: memory,
            ecpuUsage: request.includeComputeMetrics ? [Double(ioMetrics.ecpuFrequencyMHz), ioMetrics.ecpuUsage] : [0, 0],
            pcpuUsage: request.includeComputeMetrics ? [Double(ioMetrics.pcpuFrequencyMHz), ioMetrics.pcpuUsage] : [0, 0],
            gpuUsage: request.includeComputeMetrics ? [Double(ioMetrics.gpuFrequencyMHz), ioMetrics.gpuUsage] : [0, 0],
            cpuPower: cpuPower,
            gpuPower: gpuPower,
            anePower: anePower,
            allPower: allPower,
            sysPower: sysPower,
            ramPower: ramPower,
            gpuRamPower: gpuRamPower
        )
    }

    private func discoverTemperatureKeys() -> (cpu: [String], gpu: [String]) {
        let keys = smc.readAllKeys()
        var cpu: [String] = []
        var gpu: [String] = []

        for key in keys {
            guard let value = smc.readValue(key),
                  value.dataType == "flt ",
                  let numeric = smc.readNumericValue(key),
                  numeric > 0,
                  numeric <= 150
            else {
                continue
            }

            if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Ts") {
                cpu.append(key)
            } else if key.hasPrefix("Tg") {
                gpu.append(key)
            }
        }

        return (cpu, gpu)
    }

    private func readTemperatures() -> Temp {
        let cpuValues = temperatureKeys.cpu.compactMap(smc.readNumericValue).filter { $0 > 0 && $0 <= 150 }
        let gpuValues = temperatureKeys.gpu.compactMap(smc.readNumericValue).filter { $0 > 0 && $0 <= 150 }

        return Temp(
            cpuTempAvg: average(cpuValues),
            gpuTempAvg: average(gpuValues)
        )
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

struct NativeTelemetryRequest {
    let includeComputeMetrics: Bool
    let includeMemoryMetrics: Bool
    let includeTemperatureMetrics: Bool
    let includePowerMetrics: Bool
}

private struct NativeSocInfo {
    let chipName: String
    let macModel: String
    let ecpuCores: Int
    let pcpuCores: Int
    let ecpuFreqs: [UInt32]
    let pcpuFreqs: [UInt32]
    let gpuFreqs: [UInt32]

    static func current() -> NativeSocInfo {
        let chipName = sysctlString("machdep.cpu.brand_string") ?? "Unknown chip"
        let macModel = sysctlString("hw.model") ?? "Unknown model"
        let ecpuCores = Int(sysctlUInt64("hw.perflevel1.physicalcpu") ?? 0)
        let pcpuCores = Int(sysctlUInt64("hw.perflevel0.physicalcpu") ?? 0)

        let cpuScale: UInt32
        if chipName.contains("M1") || chipName.contains("M2") || chipName.contains("M3") || chipName.contains("A1") {
            cpuScale = 1_000_000
        } else {
            cpuScale = 1_000
        }

        let pmgrProps = PMGRReader.sharedProperties()
        let ecpuFreqs = PMGRReader.cpuFrequencies(from: pmgrProps, fallbackKey: "voltage-states1-sram", isECPU: true, scale: cpuScale)
        let pcpuFreqs = PMGRReader.cpuFrequencies(from: pmgrProps, fallbackKey: "voltage-states5-sram", isECPU: false, scale: cpuScale)
        let gpuFreqs = PMGRReader.dvfsFrequencies(from: pmgrProps, key: "voltage-states9", scale: 1_000_000) ?? []

        return NativeSocInfo(
            chipName: chipName,
            macModel: macModel,
            ecpuCores: ecpuCores,
            pcpuCores: pcpuCores,
            ecpuFreqs: ecpuFreqs,
            pcpuFreqs: pcpuFreqs,
            gpuFreqs: gpuFreqs
        )
    }
}

private enum PMGRReader {
    static func sharedProperties() -> [String: Any] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuffer)
            guard name == "pmgr" else { continue }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            return dict
        }
        return [:]
    }

    static func cpuFrequencies(from properties: [String: Any], fallbackKey: String, isECPU: Bool, scale: UInt32) -> [UInt32] {
        if let freqs = dvfsFrequencies(from: properties, key: fallbackKey, scale: scale), !freqs.isEmpty {
            return freqs
        }

        guard let clusterKeys = accClusterVoltageKeys(from: properties) else { return [] }
        let key = isECPU ? clusterKeys.ecpuKey : clusterKeys.pcpuKey
        return dvfsFrequencies(from: properties, key: key, scale: scale) ?? []
    }

    static func dvfsFrequencies(from properties: [String: Any], key: String, scale: UInt32) -> [UInt32]? {
        guard let data = properties[key] as? Data else { return nil }
        return stride(from: 0, to: data.count, by: 8).compactMap { offset in
            guard offset + 4 <= data.count else { return nil }
            let raw = data[offset..<(offset + 4)].withUnsafeBytes { $0.load(as: UInt32.self) }
            return raw / scale
        }
    }

    private static func accClusterVoltageKeys(from properties: [String: Any]) -> (ecpuKey: String, pcpuKey: String)? {
        guard let data = properties["acc-clusters"] as? Data, data.count >= 8 else { return nil }

        var clusters: [(type: UInt8, key: String)] = []
        for offset in stride(from: 0, to: data.count, by: 8) {
            guard offset + 2 <= data.count else { continue }
            let index = data[offset]
            let type = data[offset + 1]
            clusters.append((type: type, key: "voltage-states\(index)-sram"))
        }

        guard clusters.count >= 2 else { return nil }
        clusters.sort { $0.type < $1.type }
        return (clusters[clusters.count - 2].key, clusters[clusters.count - 1].key)
    }
}

private struct NativeIOReportMetrics {
    var ecpuFrequencyMHz: UInt32 = 0
    var ecpuUsage: Double = 0
    var pcpuFrequencyMHz: UInt32 = 0
    var pcpuUsage: Double = 0
    var gpuFrequencyMHz: UInt32 = 0
    var gpuUsage: Double = 0
    var cpuPower: Double = 0
    var gpuPower: Double = 0
    var anePower: Double = 0
    var ramPower: Double = 0
    var gpuRamPower: Double = 0
}

private final class IOReportSampler {
    private let bindings = IOReportBindings.shared
    private var channels: CFMutableDictionary?
    private var subscription: UnsafeRawPointer?
    private var previousSample: (CFDictionary, Date)?

    init() {
        guard let bindings else { return }
        let requested: [(String, String?)] = [
            ("Energy Model", nil),
            ("CPU Stats", "CPU Core Performance States"),
            ("GPU Stats", "GPU Performance States")
        ]
        self.channels = bindings.copyChannels(requested)
        if let channels {
            self.subscription = bindings.createSubscription(channels: channels)
        }
    }

    func sample(durationMs: Int, socInfo: NativeSocInfo) -> NativeIOReportMetrics {
        guard let bindings, let channels, let subscription else {
            return NativeIOReportMetrics()
        }

        let measures = max(1, min(4, durationMs / 250))
        let stepMs = max(50, durationMs / measures)
        var results: [NativeIOReportMetrics] = []

        var previous = previousSample ?? (bindings.createSample(subscription: subscription, channels: channels), Date())
        for _ in 0..<measures {
            usleep(useconds_t(stepMs * 1000))
            let next = (bindings.createSample(subscription: subscription, channels: channels), Date())
            let elapsedMs = max(1, Int(next.1.timeIntervalSince(previous.1) * 1000))
            let delta = bindings.createDelta(previous: previous.0, next: next.0)
            previous = next
            results.append(readMetrics(from: delta, elapsedMs: elapsedMs, socInfo: socInfo, bindings: bindings))
        }

        previousSample = previous

        guard !results.isEmpty else { return NativeIOReportMetrics() }
        return NativeIOReportMetrics(
            ecpuFrequencyMHz: average(results.map(\.ecpuFrequencyMHz)),
            ecpuUsage: average(results.map(\.ecpuUsage)),
            pcpuFrequencyMHz: average(results.map(\.pcpuFrequencyMHz)),
            pcpuUsage: average(results.map(\.pcpuUsage)),
            gpuFrequencyMHz: average(results.map(\.gpuFrequencyMHz)),
            gpuUsage: average(results.map(\.gpuUsage)),
            cpuPower: average(results.map(\.cpuPower)),
            gpuPower: average(results.map(\.gpuPower)),
            anePower: average(results.map(\.anePower)),
            ramPower: average(results.map(\.ramPower)),
            gpuRamPower: average(results.map(\.gpuRamPower))
        )
    }

    private func readMetrics(from sample: CFDictionary, elapsedMs: Int, socInfo: NativeSocInfo, bindings: IOReportBindings) -> NativeIOReportMetrics {
        var metrics = NativeIOReportMetrics()
        var ecpuUsages: [(UInt32, Double)] = []
        var pcpuUsages: [(UInt32, Double)] = []

        for item in bindings.iterateChannels(sample: sample) {
            if item.group == "CPU Stats", item.subgroup == "CPU Core Performance States" {
                if item.channel.contains("PCPU") {
                    pcpuUsages.append(calcFrequency(item.dictionary, freqs: socInfo.pcpuFreqs, bindings: bindings))
                    continue
                }
                if item.channel.contains("ECPU") || item.channel.contains("MCPU") {
                    ecpuUsages.append(calcFrequency(item.dictionary, freqs: socInfo.ecpuFreqs, bindings: bindings))
                    continue
                }
            }

            if item.group == "GPU Stats", item.subgroup == "GPU Performance States", item.channel == "GPUPH" {
                let gpuFreqs = socInfo.gpuFreqs.count > 1 ? Array(socInfo.gpuFreqs.dropFirst()) : socInfo.gpuFreqs
                let usage = calcFrequency(item.dictionary, freqs: gpuFreqs, bindings: bindings)
                metrics.gpuFrequencyMHz = usage.0
                metrics.gpuUsage = usage.1
                continue
            }

            if item.group == "Energy Model" {
                let watts = bindings.watts(from: item.dictionary, unit: item.unit, elapsedMs: elapsedMs)
                switch item.channel {
                case "GPU Energy":
                    metrics.gpuPower += watts
                case let channel where channel.hasSuffix("CPU Energy"):
                    metrics.cpuPower += watts
                case let channel where channel.hasPrefix("ANE"):
                    metrics.anePower += watts
                case let channel where channel.hasPrefix("DRAM"):
                    metrics.ramPower += watts
                case let channel where channel.hasPrefix("GPU SRAM"):
                    metrics.gpuRamPower += watts
                default:
                    break
                }
            }
        }

        ecpuUsages.removeAll { $0.1 <= 0 }
        let ecpuFinal = calcFrequencyFinal(ecpuUsages, freqs: socInfo.ecpuFreqs)
        let pcpuFinal = calcFrequencyFinal(pcpuUsages, freqs: socInfo.pcpuFreqs)
        metrics.ecpuFrequencyMHz = ecpuFinal.0
        metrics.ecpuUsage = ecpuFinal.1
        metrics.pcpuFrequencyMHz = pcpuFinal.0
        metrics.pcpuUsage = pcpuFinal.1
        return metrics
    }

    private func calcFrequency(_ item: CFDictionary, freqs: [UInt32], bindings: IOReportBindings) -> (UInt32, Double) {
        guard !freqs.isEmpty else { return (0, 0) }

        let residencies = bindings.residencies(for: item)
        guard let offset = residencies.firstIndex(where: { $0.name != "IDLE" && $0.name != "DOWN" && $0.name != "OFF" }) else {
            return (freqs.first ?? 0, 0)
        }

        // ArraySlice keeps the original indices, so convert it to a dense Array before
        // iterating with zero-based integer indices.
        let activeResidencies = Array(residencies.dropFirst(offset))
        let usage = activeResidencies.map(\.residency).reduce(0, +)
        let total = residencies.map(\.residency).reduce(0, +)
        guard usage > 0, total > 0 else {
            return (freqs.first ?? 0, 0)
        }

        var averageFrequency = 0.0
        for index in 0..<min(freqs.count, activeResidencies.count) {
            let percent = Double(activeResidencies[index].residency) / Double(usage)
            averageFrequency += percent * Double(freqs[index])
        }

        let minFreq = Double(freqs.first ?? 0)
        let maxFreq = Double(freqs.last ?? 1)
        let usageRatio = Double(usage) / Double(total)
        let fromMax = (max(averageFrequency, minFreq) * usageRatio) / max(maxFreq, 1)
        return (UInt32(averageFrequency.rounded()), fromMax)
    }

    private func calcFrequencyFinal(_ values: [(UInt32, Double)], freqs: [UInt32]) -> (UInt32, Double) {
        guard !values.isEmpty else { return (freqs.first ?? 0, 0) }
        let avgFreq = Double(values.map { $0.0 }.reduce(0, +)) / Double(values.count)
        let avgUsage = values.map { $0.1 }.reduce(0, +) / Double(values.count)
        return (UInt32(max(avgFreq, Double(freqs.first ?? 0)).rounded()), avgUsage)
    }

    private func average(_ values: [UInt32]) -> UInt32 {
        guard !values.isEmpty else { return 0 }
        return UInt32(Double(values.reduce(0, +)) / Double(values.count))
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

private struct IOReportChannelItem {
    let dictionary: CFDictionary
    let group: String
    let subgroup: String
    let channel: String
    let unit: String
}

private final class IOReportBindings {
    static let shared: IOReportBindings? = IOReportBindings()

    private let handle: UnsafeMutableRawPointer
    private let copyChannelsInGroupFn: CopyChannelsInGroupFn
    private let mergeChannelsFn: MergeChannelsFn
    private let createSubscriptionFn: CreateSubscriptionFn
    private let createSamplesFn: CreateSamplesFn
    private let createSamplesDeltaFn: CreateSamplesDeltaFn
    private let channelGetGroupFn: ChannelGetStringFn
    private let channelGetSubgroupFn: ChannelGetStringFn
    private let channelGetNameFn: ChannelGetStringFn
    private let channelGetUnitFn: ChannelGetStringFn
    private let simpleGetIntegerValueFn: SimpleGetIntegerValueFn
    private let stateGetCountFn: StateGetCountFn
    private let stateGetNameFn: StateGetNameFn
    private let stateGetResidencyFn: StateGetResidencyFn

    private typealias CopyChannelsInGroupFn = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias MergeChannelsFn = @convention(c) (CFMutableDictionary, CFDictionary, UnsafeRawPointer?) -> Void
    private typealias CreateSubscriptionFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias CreateSamplesFn = @convention(c) (UnsafeRawPointer, CFMutableDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    private typealias ChannelGetStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleGetIntegerValueFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

    private init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        self.handle = handle

        func load<T>(_ symbol: String, as type: T.Type) -> T? {
            guard let ptr = dlsym(handle, symbol) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }

        guard
            let copyChannelsInGroupFn = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroupFn.self),
            let mergeChannelsFn = load("IOReportMergeChannels", as: MergeChannelsFn.self),
            let createSubscriptionFn = load("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
            let createSamplesFn = load("IOReportCreateSamples", as: CreateSamplesFn.self),
            let createSamplesDeltaFn = load("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self),
            let channelGetGroupFn = load("IOReportChannelGetGroup", as: ChannelGetStringFn.self),
            let channelGetSubgroupFn = load("IOReportChannelGetSubGroup", as: ChannelGetStringFn.self),
            let channelGetNameFn = load("IOReportChannelGetChannelName", as: ChannelGetStringFn.self),
            let channelGetUnitFn = load("IOReportChannelGetUnitLabel", as: ChannelGetStringFn.self),
            let simpleGetIntegerValueFn = load("IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValueFn.self),
            let stateGetCountFn = load("IOReportStateGetCount", as: StateGetCountFn.self),
            let stateGetNameFn = load("IOReportStateGetNameForIndex", as: StateGetNameFn.self),
            let stateGetResidencyFn = load("IOReportStateGetResidency", as: StateGetResidencyFn.self)
        else {
            dlclose(handle)
            return nil
        }

        self.copyChannelsInGroupFn = copyChannelsInGroupFn
        self.mergeChannelsFn = mergeChannelsFn
        self.createSubscriptionFn = createSubscriptionFn
        self.createSamplesFn = createSamplesFn
        self.createSamplesDeltaFn = createSamplesDeltaFn
        self.channelGetGroupFn = channelGetGroupFn
        self.channelGetSubgroupFn = channelGetSubgroupFn
        self.channelGetNameFn = channelGetNameFn
        self.channelGetUnitFn = channelGetUnitFn
        self.simpleGetIntegerValueFn = simpleGetIntegerValueFn
        self.stateGetCountFn = stateGetCountFn
        self.stateGetNameFn = stateGetNameFn
        self.stateGetResidencyFn = stateGetResidencyFn
    }

    func copyChannels(_ requests: [(String, String?)]) -> CFMutableDictionary? {
        guard let first = requests.first else { return nil }
        guard let firstChannels = copyChannelsInGroupFn(first.0 as CFString, first.1 as CFString?, 0, 0, 0)?.takeRetainedValue() else {
            return nil
        }
        guard let merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(firstChannels), firstChannels) else {
            return nil
        }

        for request in requests.dropFirst() {
            guard let channels = copyChannelsInGroupFn(request.0 as CFString, request.1 as CFString?, 0, 0, 0)?.takeRetainedValue() else {
                continue
            }
            mergeChannelsFn(merged, channels, nil)
        }

        return merged
    }

    func createSubscription(channels: CFMutableDictionary) -> UnsafeRawPointer? {
        var outChannels: Unmanaged<CFMutableDictionary>?
        return createSubscriptionFn(nil, channels, &outChannels, 0, nil)
    }

    func createSample(subscription: UnsafeRawPointer, channels: CFMutableDictionary) -> CFDictionary {
        createSamplesFn(subscription, channels, nil)?.takeRetainedValue() ?? [:] as CFDictionary
    }

    func createDelta(previous: CFDictionary, next: CFDictionary) -> CFDictionary {
        createSamplesDeltaFn(previous, next, nil)?.takeRetainedValue() ?? [:] as CFDictionary
    }

    func iterateChannels(sample: CFDictionary) -> [IOReportChannelItem] {
        guard let channels = (sample as NSDictionary)["IOReportChannels"] as? [CFDictionary] else {
            return []
        }

        return channels.map { item in
            IOReportChannelItem(
                dictionary: item,
                group: readString(channelGetGroupFn(item)),
                subgroup: readString(channelGetSubgroupFn(item)),
                channel: readString(channelGetNameFn(item)),
                unit: readString(channelGetUnitFn(item))
            )
        }
    }

    func residencies(for item: CFDictionary) -> [(name: String, residency: Int64)] {
        let count = Int(stateGetCountFn(item))
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            (
                name: readString(stateGetNameFn(item, Int32(index))),
                residency: stateGetResidencyFn(item, Int32(index))
            )
        }
    }

    func watts(from item: CFDictionary, unit: String, elapsedMs: Int) -> Double {
        let raw = Double(simpleGetIntegerValueFn(item, 0))
        let value = raw / (Double(max(elapsedMs, 1)) / 1000.0)

        switch unit {
        case "mJ":
            return value / 1_000
        case "uJ":
            return value / 1_000_000
        case "nJ":
            return value / 1_000_000_000
        default:
            return 0
        }
    }

    private func readString(_ unmanaged: Unmanaged<CFString>?) -> String {
        guard let unmanaged else { return "" }
        return unmanaged.takeUnretainedValue() as String
    }

    deinit {
        dlclose(handle)
    }
}

private func sysctlString(_ name: String) -> String? {
    var size: Int = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        return nil
    }
    return String(cString: buffer)
}

private func sysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.stride
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
        return nil
    }
    return value
}
