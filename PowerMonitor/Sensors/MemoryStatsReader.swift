import Foundation
import Darwin

// Mirrors the memory buckets users expect from Activity Monitor while keeping the
// existing "used / total / swap" fields compatible with the old macmon payload.
final class MemoryStatsReader {
    func read(fallback: Memory) -> Memory {
        guard
            let totalBytes = totalMemoryBytes(),
            let vmStats = vmStatistics(),
            let pageSize = hostPageSize()
        else {
            return fallback
        }

        let pageBytes = Int64(pageSize)
        let activeBytes = Int64(vmStats.active_count) * pageBytes
        let inactiveBytes = Int64(vmStats.inactive_count) * pageBytes
        let wiredBytes = Int64(vmStats.wire_count) * pageBytes
        let speculativeBytes = Int64(vmStats.speculative_count) * pageBytes
        let compressedBytes = Int64(vmStats.compressor_page_count) * pageBytes
        let purgeableBytes = Int64(vmStats.purgeable_count) * pageBytes
        let cachedBytes = Int64(vmStats.external_page_count) * pageBytes
        let internalBytes = Int64(vmStats.internal_page_count) * pageBytes
        let freeBytes = Int64(vmStats.free_count) * pageBytes

        // This follows macmon's "used memory" calculation so the menu bar ratio stays
        // visually consistent while we expand the detail sheet with richer buckets.
        let usedBytes = max(
            0,
            activeBytes
                + inactiveBytes
                + wiredBytes
                + speculativeBytes
                + compressedBytes
                - purgeableBytes
                - cachedBytes
        )

        // Activity Monitor's app bucket is roughly "internal minus purgeable".
        let appBytes = max(0, internalBytes - purgeableBytes)
        let swap = swapUsage() ?? (used: fallback.swapUsage, total: fallback.swapTotal)

        return Memory(
            ramTotal: totalBytes,
            ramUsage: usedBytes,
            swapTotal: swap.total,
            swapUsage: swap.used,
            appMemory: appBytes,
            wiredMemory: wiredBytes,
            compressedMemory: compressedBytes,
            cachedFiles: cachedBytes,
            freeMemory: freeBytes,
            pressureLevel: currentPressureLevel()
        )
    }

    private func currentPressureLevel() -> MemoryPressureLevel {
        let rawPressure = sysctlInt32("vm.memory_pressure") ?? 0
        if rawPressure <= 0 {
            return .normal
        }

        let memorystatusLevel = sysctlInt32("kern.memorystatus_level") ?? 0
        if memorystatusLevel > 0 && memorystatusLevel <= 10 {
            return .critical
        }
        return .warning
    }

    private func totalMemoryBytes() -> Int64? {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        let result = sysctlbyname("hw.memsize", &total, &size, nil, 0)
        guard result == 0 else { return nil }
        return Int64(clamping: total)
    }

    private func hostPageSize() -> vm_size_t? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return nil
        }
        return pageSize
    }

    private func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return stats
    }

    private func swapUsage() -> (used: Int64, total: Int64)? {
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride

        let result = sysctl(&mib, u_int(mib.count), &swap, &size, nil, 0)
        guard result == 0 else { return nil }

        return (used: Int64(clamping: swap.xsu_used), total: Int64(clamping: swap.xsu_total))
    }

    private func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
