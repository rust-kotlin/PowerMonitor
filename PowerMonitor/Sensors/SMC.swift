import Foundation
import IOKit

// Thin AppleSMC wrapper shared by fan, temperature, and power readers.
final class SMCConnection {
    private var connection: io_connect_t = 0
    private var didAttemptOpen = false
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    func openIfNeeded() -> Bool {
        if connection != 0 {
            return true
        }
        if didAttemptOpen {
            return false
        }
        didAttemptOpen = true

        let iterator = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, iterator)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    func readNumericValue(_ key: String) -> Double? {
        guard let value = readValue(key) else { return nil }
        return decodeNumeric(value)
    }

    func readAllKeys() -> [String] {
        guard let keyCount = readUnsignedInteger("#KEY") else { return [] }

        return (0..<keyCount).compactMap { index in
            guard let key = keyByIndex(index) else { return nil }
            return readValue(key) != nil ? key : nil
        }
    }

    func readValue(_ key: String) -> SMCValue? {
        guard openIfNeeded(), key.count == 4 else { return nil }
        let fourCC = fourCC(key)

        let keyInfo = cachedKeyInfo(for: fourCC) ?? readKeyInfo(key: fourCC)
        guard let keyInfo else { return nil }

        var input = SMCKeyData()
        input.key = fourCC
        input.data8 = SMCCommand.readBytes.rawValue
        input.keyInfo = keyInfo

        guard let output = callSMC(input) else { return nil }
        let dataSize = Int(keyInfo.dataSize)
        let dataType = fourCCString(keyInfo.dataType)
        return SMCValue(dataType: dataType, bytes: Array(mirrorBytes(output.bytes).prefix(dataSize)))
    }

    private func readUnsignedInteger(_ key: String) -> UInt32? {
        guard let value = readValue(key) else { return nil }
        switch value.dataType {
        case "ui8 ":
            return UInt32(value.bytes.first ?? 0)
        case "ui16":
            guard value.bytes.count >= 2 else { return nil }
            return UInt32(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
        case "ui32":
            guard value.bytes.count >= 4 else { return nil }
            return UInt32(value.bytes[0]) << 24
                | UInt32(value.bytes[1]) << 16
                | UInt32(value.bytes[2]) << 8
                | UInt32(value.bytes[3])
        default:
            return nil
        }
    }

    private func keyByIndex(_ index: UInt32) -> String? {
        var input = SMCKeyData()
        input.data8 = SMCCommand.readIndex.rawValue
        input.data32 = index

        guard let output = callSMC(input) else { return nil }
        return fourCCString(output.key).trimmingCharacters(in: .controlCharacters)
    }

    private func cachedKeyInfo(for key: UInt32) -> SMCKeyInfo? {
        keyInfoCache[key]
    }

    private func readKeyInfo(key: UInt32) -> SMCKeyInfo? {
        var input = SMCKeyData()
        input.key = key
        input.data8 = SMCCommand.readKeyInfo.rawValue

        guard let output = callSMC(input) else { return nil }
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private func callSMC(_ input: SMCKeyData) -> SMCKeyData? {
        guard connection != 0 else { return nil }

        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    2,
                    inputPointer,
                    MemoryLayout<SMCKeyData>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }

        guard result == kIOReturnSuccess, output.result == 0 else {
            return nil
        }
        return output
    }

    private func decodeNumeric(_ value: SMCValue) -> Double? {
        switch value.dataType {
        case "ui8 ":
            return Double(value.bytes.first ?? 0)
        case "ui16":
            guard value.bytes.count >= 2 else { return nil }
            let raw = UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])
            return Double(raw)
        case "ui32":
            guard value.bytes.count >= 4 else { return nil }
            let raw = UInt32(value.bytes[0]) << 24
                | UInt32(value.bytes[1]) << 16
                | UInt32(value.bytes[2]) << 8
                | UInt32(value.bytes[3])
            return Double(raw)
        case "si16":
            guard value.bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
            return Double(raw)
        case "flt ":
            guard value.bytes.count >= 4 else { return nil }
            let raw = value.bytes[0..<4].enumerated().reduce(UInt32(0)) { partial, entry in
                partial | (UInt32(entry.element) << (entry.offset * 8))
            }
            return Double(Float(bitPattern: raw))
        case "fpe2":
            guard value.bytes.count >= 2 else { return nil }
            let raw = UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])
            return Double(raw) / 4.0
        default:
            return nil
        }
    }

    private func mirrorBytes(_ tuple: SMCBytes) -> [UInt8] {
        Mirror(reflecting: tuple).children.compactMap { $0.value as? UInt8 }
    }

    private func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCCString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? ""
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }
}

struct SMCValue {
    let dataType: String
    let bytes: [UInt8]
}

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case readIndex = 8
    case readKeyInfo = 9
}

struct SMCKeyDataVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
    var padding: UInt16 = 0
}

struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVersion()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
