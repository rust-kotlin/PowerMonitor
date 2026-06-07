import Foundation
import IOKit
import Darwin

private struct AppConfig: Decodable {
    let fanControl: FanControlSettingsPayload?
}

private struct FanControlSettingsPayload: Decodable {
    let helperToken: String?
    let manualRPM: Double?
}

private struct HelperRequest: Encodable {
    let token: String
    let mode: String
    let targetRPM: Int?
}

private struct HelperResponse: Decodable {
    let ok: Bool
    let message: String?
}

private struct FanSnapshot: CustomStringConvertible {
    let rpm: Double
    let minRPM: Double?
    let maxRPM: Double?

    var description: String {
        let minText = minRPM.map { String(format: "%.0f", $0) } ?? "--"
        let maxText = maxRPM.map { String(format: "%.0f", $0) } ?? "--"
        return String(format: "%.0f RPM (min %@ / max %@)", rpm, minText, maxText)
    }
}

private enum VerificationError: LocalizedError {
    case missingConfig
    case missingToken
    case helperSocketMissing(String)
    case helperRejected(String)
    case noFanData

    var errorDescription: String? {
        switch self {
            case .missingConfig:
                return "Unable to load PowerMonitor config."
            case .missingToken:
                return "Helper token is missing. Switch the app to Manual or Smart once so it can install the helper."
            case .helperSocketMissing(let path):
                return "Helper socket is missing at \(path)."
            case .helperRejected(let message):
                return message
            case .noFanData:
                return "Unable to read fan data from AppleSMC."
        }
    }
}

private final class FanSensorReader {
    private var connection: io_connect_t = 0
    private var didAttemptOpen = false

    func readFans() -> [FanSnapshot] {
        guard openIfNeeded() else { return [] }
        guard let fanCount = readNumericKey("FNum") else { return [] }

        let count = max(0, min(Int(fanCount), 8))
        var result: [FanSnapshot] = []
        for index in 0..<count {
            let currentKey = String(format: "F%dAc", index)
            let minKey = String(format: "F%dMn", index)
            let maxKey = String(format: "F%dMx", index)
            if let rpm = readNumericKey(currentKey) {
                result.append(
                    FanSnapshot(
                        rpm: rpm,
                        minRPM: readNumericKey(minKey),
                        maxRPM: readNumericKey(maxKey)
                    )
                )
            }
        }
        return result
    }

    private func openIfNeeded() -> Bool {
        if connection != 0 {
            return true
        }
        if didAttemptOpen {
            return false
        }
        didAttemptOpen = true

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        let openResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
        return openResult == kIOReturnSuccess
    }

    private func readNumericKey(_ key: String) -> Double? {
        guard let bytes = readValue(key) else { return nil }

        switch bytes.dataType {
            case "ui8 ":
                return Double(bytes.bytes[0])
            case "ui16":
                guard bytes.bytes.count >= 2 else { return nil }
                let raw = UInt16(bytes.bytes[0]) << 8 | UInt16(bytes.bytes[1])
                return Double(raw)
            case "si16":
                guard bytes.bytes.count >= 2 else { return nil }
                let raw = Int16(bitPattern: UInt16(bytes.bytes[0]) << 8 | UInt16(bytes.bytes[1]))
                return Double(raw)
            case "flt ":
                guard bytes.bytes.count >= 4 else { return nil }
                let raw = bytes.bytes[0..<4].enumerated().reduce(UInt32(0)) { partial, entry in
                    partial | (UInt32(entry.element) << (entry.offset * 8))
                }
                return Double(Float(bitPattern: raw))
            case "fpe2":
                guard bytes.bytes.count >= 2 else { return nil }
                let raw = UInt16(bytes.bytes[0]) << 8 | UInt16(bytes.bytes[1])
                return Double(raw) / 4.0
            default:
                return nil
        }
    }

    private func readValue(_ key: String) -> SMCValue? {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue

        var inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let keyInfoResult = withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(connection, 2, inputPointer, inputSize, outputPointer, &outputSize)
            }
        }
        guard keyInfoResult == kIOReturnSuccess else { return nil }

        var valueInput = SMCKeyData()
        var valueOutput = SMCKeyData()
        valueInput.key = fourCC(key)
        valueInput.data8 = SMCCommand.readBytes.rawValue
        valueInput.keyInfo.dataSize = output.keyInfo.dataSize

        inputSize = MemoryLayout<SMCKeyData>.stride
        outputSize = MemoryLayout<SMCKeyData>.stride

        let readResult = withUnsafeMutablePointer(to: &valueInput) { inputPointer in
            withUnsafeMutablePointer(to: &valueOutput) { outputPointer in
                IOConnectCallStructMethod(connection, 2, inputPointer, inputSize, outputPointer, &outputSize)
            }
        }
        guard readResult == kIOReturnSuccess else { return nil }

        let dataSize = Int(valueInput.keyInfo.dataSize)
        let type = fourCCString(output.keyInfo.dataType)
        let allBytes = mirrorBytes(valueOutput.bytes)
        return SMCValue(dataType: type, bytes: Array(allBytes.prefix(dataSize)))
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

private struct SMCValue {
    let dataType: String
    let bytes: [UInt8]
}

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case readKeyInfo = 9
}

private struct SMCKeyDataVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
    var padding: UInt16 = 0
}

private struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVersion()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataKeyInfo()
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

private func loadConfig() throws -> AppConfig {
    let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PowerMonitor/config.json")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        throw VerificationError.missingConfig
    }
    let data = try Data(contentsOf: configURL)
    return try JSONDecoder().decode(AppConfig.self, from: data)
}

private func sendHelperCommand(token: String, mode: String, targetRPM: Int?) throws {
    let socketPath = "/Library/Application Support/PowerMonitor/FanHelper.sock"
    guard FileManager.default.fileExists(atPath: socketPath) else {
        throw VerificationError.helperSocketMissing(socketPath)
    }

    let payload = HelperRequest(token: token, mode: mode, targetRPM: targetRPM)
    let data = try JSONEncoder().encode(payload) + Data([0x0A])

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw VerificationError.helperRejected("Unable to open helper socket.")
    }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw VerificationError.helperRejected("Helper socket path is too long.")
    }

    withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
        pathPointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { buffer in
            buffer.initialize(repeating: 0, count: pathBytes.count + 1)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = CChar(bitPattern: byte)
            }
        }
    }

    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, length)
        }
    }
    guard connected == 0 else {
        throw VerificationError.helperRejected("Unable to connect to helper.")
    }

    let writeResult = data.withUnsafeBytes { bytes in
        Darwin.write(fd, bytes.baseAddress, bytes.count)
    }
    guard writeResult == data.count else {
        throw VerificationError.helperRejected("Unable to send helper command.")
    }

    var responseBuffer = [UInt8](repeating: 0, count: 4096)
    let readCount = responseBuffer.withUnsafeMutableBytes { buffer in
        Darwin.read(fd, buffer.baseAddress, buffer.count)
    }
    guard readCount > 0 else {
        throw VerificationError.helperRejected("No response from helper.")
    }

    let responseData = Data(responseBuffer.prefix(readCount))
    let response = try JSONDecoder().decode(HelperResponse.self, from: responseData)
    if !response.ok {
        throw VerificationError.helperRejected(response.message ?? "Helper reported failure.")
    }
}

private func parseArgument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

private func peakRPM(from fans: [FanSnapshot]) -> Double? {
    fans.map(\.rpm).max()
}

private func main() throws {
    let config = try loadConfig()
    guard let token = config.fanControl?.helperToken, !token.isEmpty else {
        throw VerificationError.missingToken
    }

    let sensor = FanSensorReader()
    let baselineFans = sensor.readFans()
    guard let baselinePeak = peakRPM(from: baselineFans) else {
        throw VerificationError.noFanData
    }

    let configuredRPM = Int((config.fanControl?.manualRPM ?? 0).rounded())
    let requestedRPM = Int(parseArgument("--rpm") ?? "") ?? max(configuredRPM, Int(baselinePeak.rounded()) + 600)
    let duration = Double(parseArgument("--duration") ?? "") ?? 8.0

    print("Baseline peak: \(Int(baselinePeak.rounded())) RPM")
    if let first = baselineFans.first {
        print("Fan 1 before: \(first)")
    }
    print("Requesting manual target: \(requestedRPM) RPM")

    defer {
        try? sendHelperCommand(token: token, mode: "system", targetRPM: nil)
        usleep(300_000)
        let restored = sensor.readFans()
        if let restoredPeak = peakRPM(from: restored) {
            print("Restored system mode. Peak now: \(Int(restoredPeak.rounded())) RPM")
        } else {
            print("Restored system mode.")
        }
    }

    try sendHelperCommand(token: token, mode: "manual", targetRPM: requestedRPM)

    let deadline = Date().addingTimeInterval(duration)
    var bestPeak = baselinePeak
    var samples: [(seconds: Double, peak: Double)] = []

    while Date() < deadline {
        usleep(500_000)
        let fans = sensor.readFans()
        guard let peak = peakRPM(from: fans) else {
            continue
        }
        bestPeak = max(bestPeak, peak)
        let elapsed = duration - deadline.timeIntervalSinceNow
        samples.append((seconds: elapsed, peak: peak))
        print(String(format: "t=%.1fs peak=%.0f RPM", elapsed, peak))
    }

    let gain = bestPeak - baselinePeak
    let success = gain >= 250 || bestPeak >= Double(requestedRPM) * 0.88

    print("")
    print("Verification result: \(success ? "PASS" : "FAIL")")
    print("Peak before: \(Int(baselinePeak.rounded())) RPM")
    print("Peak after : \(Int(bestPeak.rounded())) RPM")
    print("Delta      : \(Int(gain.rounded())) RPM")
    print("Samples    : \(samples.count)")
}

do {
    try main()
} catch {
    fputs("verify_fan_helper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
