import Foundation
import SystemConfiguration

private struct NetworkCounterSnapshot {
    let sentBytes: UInt64
    let receivedBytes: UInt64
}

final class NetworkSpeedReader {
    private var lastSnapshot: NetworkCounterSnapshot?
    private(set) var primaryInterfaceSummary: String = "--"
    private var selectedInterfaceName: String?

    var selectedSourceName: String? {
        selectedInterfaceName
    }

    // Expose interfaces that are meaningful to users in the menu. Auxiliary
    // and loopback devices are skipped so the picker stays readable.
    func availableInterfaces() -> [NetworkInterfaceOption] {
        var seen = Set<String>()
        var options: [NetworkInterfaceOption] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            let flags = Int32(interface.pointee.ifa_flags)
            let name = String(cString: interface.pointee.ifa_name)

            if (flags & IFF_LOOPBACK) == 0,
               interface.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               !name.hasPrefix("awdl"),
               !name.hasPrefix("llw"),
               seen.insert(name).inserted {
                options.append(NetworkInterfaceOption(id: name, title: name))
            }

            current = interface.pointee.ifa_next
        }

        return options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func setSelectedInterfaceName(_ name: String?) {
        selectedInterfaceName = name?.isEmpty == true ? nil : name
        lastSnapshot = nil
    }

    // Throughput comes from byte deltas between successive snapshots of the current
    // primary network path, with a fallback when the route cannot be resolved.
    func read(intervalMs: Int) -> NetworkThroughput {
        let snapshot = currentSnapshot()
        defer { lastSnapshot = snapshot }

        guard let previous = lastSnapshot else {
            return NetworkThroughput(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        }

        let interval = max(Double(intervalMs) / 1000.0, 0.1)
        let downloadDelta = snapshot.receivedBytes >= previous.receivedBytes ? (snapshot.receivedBytes - previous.receivedBytes) : 0
        let uploadDelta = snapshot.sentBytes >= previous.sentBytes ? (snapshot.sentBytes - previous.sentBytes) : 0
        return NetworkThroughput(
            downloadBytesPerSecond: Double(downloadDelta) / interval,
            uploadBytesPerSecond: Double(uploadDelta) / interval
        )
    }

    private func currentSnapshot() -> NetworkCounterSnapshot {
        var sent: UInt64 = 0
        var received: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>?
        let activeInterfaces = selectedInterfaces()
        if let selectedInterfaceName {
            primaryInterfaceSummary = selectedInterfaceName
        } else {
            primaryInterfaceSummary = activeInterfaces.isEmpty ? "--" : activeInterfaces.sorted().joined(separator: ", ")
        }

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return NetworkCounterSnapshot(sentBytes: 0, receivedBytes: 0)
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            let flags = Int32(interface.pointee.ifa_flags)
            let name = String(cString: interface.pointee.ifa_name)

            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               interface.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let opaqueData = interface.pointee.ifa_data {
                let data = opaqueData.assumingMemoryBound(to: if_data.self)
                let isFilteredAuxiliary = name.hasPrefix("awdl") || name.hasPrefix("llw")
                let isPrimary = activeInterfaces.isEmpty || activeInterfaces.contains(name)
                if !isFilteredAuxiliary && isPrimary {
                    sent = sent.addingReportingOverflow(UInt64(data.pointee.ifi_obytes)).partialValue
                    received = received.addingReportingOverflow(UInt64(data.pointee.ifi_ibytes)).partialValue
                }
            }

            current = interface.pointee.ifa_next
        }

        return NetworkCounterSnapshot(sentBytes: sent, receivedBytes: received)
    }

    private func selectedInterfaces() -> Set<String> {
        if let selectedInterfaceName {
            return [selectedInterfaceName]
        }
        return currentPrimaryInterfaces()
    }

    private func currentPrimaryInterfaces() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "PowerMonitorNetworkReader" as CFString, nil, nil) else {
            return []
        }

        var interfaces = Set<String>()
        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6"
        ]

        for key in keys {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let primary = value["PrimaryInterface"] as? String else {
                continue
            }
            interfaces.insert(primary)
        }

        return interfaces
    }
}
