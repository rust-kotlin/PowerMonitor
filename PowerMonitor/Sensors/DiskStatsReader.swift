import Foundation
import DiskArbitration
import IOKit
import IOKit.storage
import Darwin

private struct DiskIOSnapshot {
    let readBytes: UInt64
    let writtenBytes: UInt64
}

final class DiskStatsReader {
    private let fileManager = FileManager.default
    private let diskSession = DASessionCreate(kCFAllocatorDefault)
    private var selectedVolumePath: String?
    private var lastSnapshot: DiskIOSnapshot?

    var selectedSourcePath: String? {
        selectedVolumePath
    }

    // Source selection stays volume-oriented because the detail panel still shows
    // capacity information for the selected mount point. Throughput is resolved
    // from the backing block device behind that volume.
    func availableVolumes() -> [DiskVolumeOption] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsBrowsableKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey
        ]

        guard let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        let options = urls.compactMap { url -> DiskVolumeOption? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                return nil
            }
            let name = values.volumeName ?? url.lastPathComponent
            let suffix = url.path == "/" ? "" : " (\(url.path))"
            return DiskVolumeOption(
                id: url.path,
                title: name + suffix,
                path: url.path
            )
        }

        return options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func setSelectedVolumePath(_ path: String?) {
        selectedVolumePath = path?.isEmpty == true ? nil : path
        lastSnapshot = nil
    }

    func read(intervalMs: Int) -> DiskStats {
        let volumeURL = resolvedVolumeURL()
        let values = try? volumeURL.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = Int64(values?.volumeAvailableCapacity ?? 0)
        let used = max(0, total - available)

        let currentSnapshot = currentSnapshot(for: volumeURL)
        defer { lastSnapshot = currentSnapshot }

        let throughput: (Double, Double)
        if let currentSnapshot, let previous = lastSnapshot {
            let interval = max(Double(intervalMs) / 1000.0, 0.1)
            let readDelta = currentSnapshot.readBytes >= previous.readBytes ? (currentSnapshot.readBytes - previous.readBytes) : 0
            let writeDelta = currentSnapshot.writtenBytes >= previous.writtenBytes ? (currentSnapshot.writtenBytes - previous.writtenBytes) : 0
            throughput = (Double(readDelta) / interval, Double(writeDelta) / interval)
        } else {
            throughput = (0, 0)
        }

        return DiskStats(
            volumeName: values?.volumeName ?? "Macintosh HD",
            totalBytes: total,
            availableBytes: available,
            usedBytes: used,
            readBytesPerSecond: throughput.0,
            writeBytesPerSecond: throughput.1
        )
    }

    private func resolvedVolumeURL() -> URL {
        let candidate = URL(fileURLWithPath: selectedVolumePath ?? NSHomeDirectory(), isDirectory: true)
        return mountedVolumeURL(containing: candidate) ?? candidate
    }

    // Disk Arbitration wants a mount point, not an arbitrary directory inside a volume.
    // Auto mode starts from the user's home path, so resolve it through statfs to the
    // actual mounted filesystem root (for example /System/Volumes/Data on APFS setups).
    private func mountedVolumeURL(containing url: URL) -> URL? {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else {
            return nil
        }

        return withUnsafePointer(to: &stats.f_mntonname) { pointer in
            let cString = UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            let mountPath = String(cString: cString)
            return mountPath.isEmpty ? nil : URL(fileURLWithPath: mountPath, isDirectory: true)
        }
    }

    // DADisk gives us the IOMedia for the selected mount point. Walking upward on
    // the service plane until IOBlockStorageDriver finds the underlying device
    // statistics that iostat-like tools also rely on.
    private func currentSnapshot(for volumeURL: URL) -> DiskIOSnapshot? {
        guard let session = diskSession,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL) else {
            return nil
        }

        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }

        guard let driver = findBlockStorageDriver(startingAt: media) else {
            IOObjectRelease(media)
            return nil
        }
        defer { IOObjectRelease(driver) }
        if driver != media {
            IOObjectRelease(media)
        }

        guard let statistics = IORegistryEntryCreateCFProperty(
            driver,
            kIOBlockStorageDriverStatisticsKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let readBytes = (statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber)?.uint64Value ?? 0
        let writtenBytes = (statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber)?.uint64Value ?? 0
        return DiskIOSnapshot(readBytes: readBytes, writtenBytes: writtenBytes)
    }

    private func findBlockStorageDriver(startingAt service: io_service_t) -> io_service_t? {
        var current: io_registry_entry_t = service

        while current != 0 {
            if IOObjectConformsTo(current, kIOBlockStorageDriverClass) != 0 {
                return current
            }

            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if result != KERN_SUCCESS || parent == 0 {
                if current != service {
                    IOObjectRelease(current)
                }
                return nil
            }

            if current != service {
                IOObjectRelease(current)
            }
            current = parent
        }

        return nil
    }
}
