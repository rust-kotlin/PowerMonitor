import Foundation
import AppKit
import Darwin

// One logical command sent to the privileged helper.
struct FanControlCommand: Equatable {
    let mode: FanControlMode
    let targetRPM: Int?
}

final class FanControlService {
    private let label = "top.tomzz.PowerMonitor.FanHelper"
    private let installPath = "/Library/PrivilegedHelperTools/top.tomzz.PowerMonitor.FanHelper"
    private let plistPath = "/Library/LaunchDaemons/top.tomzz.PowerMonitor.FanHelper.plist"
    private let configPath = "/Library/Application Support/PowerMonitor/FanHelperConfig.json"
    private let versionPath = "/Library/Application Support/PowerMonitor/FanHelper.version"
    private let socketPath = "/Library/Application Support/PowerMonitor/FanHelper.sock"
    private let helperVersion = "6"
    private let queue = DispatchQueue(label: "top.tomzz.PowerMonitor.fan-control", qos: .userInitiated)

    // Treat the helper as installed only when both the binary and launchd plist are present.
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installPath) && FileManager.default.fileExists(atPath: plistPath)
    }

    var helperSocketPath: String {
        socketPath
    }

    func uninstallIfPresent() throws {
        guard isInstalled else { return }
        try runUninstallScript()
    }

    func installIfNeeded(token: String) throws {
        if isInstalled, installedVersion() == helperVersion {
            return
        }
        try installBundledHelper(token: token)
    }

    func apply(_ command: FanControlCommand, token: String, completion: ((Bool, String?) -> Void)? = nil) {
        queue.async {
            let result = self.send(command: command, token: token)
            completion?(result.ok, result.message)
        }
    }

    @discardableResult
    func applySynchronously(_ command: FanControlCommand, token: String) -> Bool {
        queue.sync {
            self.send(command: command, token: token).ok
        }
    }

    // Stage helper assets in a temporary directory first so the elevated copy step stays simple.
    private func installBundledHelper(token: String) throws {
        let fileManager = FileManager.default
        guard let binaryURL = Bundle.main.url(forResource: "PowerMonitorFanHelper", withExtension: nil) else {
            throw FanControlError.missingHelperBinary
        }

        let workingDir = fileManager.temporaryDirectory.appendingPathComponent("PowerMonitorFanHelper", isDirectory: true)
        try? fileManager.removeItem(at: workingDir)
        try fileManager.createDirectory(at: workingDir, withIntermediateDirectories: true)

        let stagedBinaryURL = workingDir.appendingPathComponent("PowerMonitorFanHelper")
        let plistURL = workingDir.appendingPathComponent("top.tomzz.PowerMonitor.FanHelper.plist")
        let configURL = workingDir.appendingPathComponent("FanHelperConfig.json")
        let versionURL = workingDir.appendingPathComponent("FanHelper.version")
        try fileManager.copyItem(at: binaryURL, to: stagedBinaryURL)
        try helperVersion.write(to: versionURL, atomically: true, encoding: .utf8)

        let config = HelperInstallConfig(
            token: token,
            socketPath: socketPath,
            clientUID: getuid(),
            clientGID: getgid()
        )
        let configData = try JSONEncoder().encode(config)
        try configData.write(to: configURL, options: .atomic)
        try makeLaunchDaemonPlist().write(to: plistURL, atomically: true, encoding: .utf8)

        try runInstallScript(binaryURL: stagedBinaryURL, plistURL: plistURL, configURL: configURL, versionURL: versionURL)
    }

    // Use AppleScript elevation because the app is distributed without a dedicated installer.
    private func runInstallScript(binaryURL: URL, plistURL: URL, configURL: URL, versionURL: URL) throws {
        let script = """
        set -e
        /bin/mkdir -p '/Library/PrivilegedHelperTools' '/Library/LaunchDaemons' '/Library/Application Support/PowerMonitor'
        /bin/launchctl bootout system '\(self.plistPath)' >/dev/null 2>&1 || true
        /bin/rm -f '\(self.socketPath)'
        /bin/cp '\(binaryURL.path)' '\(self.installPath)'
        /usr/sbin/chown root:wheel '\(self.installPath)'
        /bin/chmod 755 '\(self.installPath)'
        /bin/cp '\(configURL.path)' '\(self.configPath)'
        /usr/sbin/chown root:wheel '\(self.configPath)'
        /bin/chmod 600 '\(self.configPath)'
        /bin/cp '\(versionURL.path)' '\(self.versionPath)'
        /usr/sbin/chown root:wheel '\(self.versionPath)'
        /bin/chmod 644 '\(self.versionPath)'
        /bin/cp '\(plistURL.path)' '\(self.plistPath)'
        /usr/sbin/chown root:wheel '\(self.plistPath)'
        /bin/chmod 644 '\(self.plistPath)'
        /bin/launchctl bootstrap system '\(self.plistPath)'
        /bin/launchctl kickstart -k system/\(self.label) >/dev/null 2>&1 || true
        """

        let appleScriptSource = """
        do shell script \(quotedAppleScriptString(script)) with administrator privileges
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            throw FanControlError.installFailed("Unable to create install script")
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            throw FanControlError.installFailed(error.description)
        }
    }

    private func runUninstallScript() throws {
        let script = """
        set -e
        /bin/launchctl bootout system '\(self.plistPath)' >/dev/null 2>&1 || true
        /bin/rm -f '\(self.socketPath)' '\(self.installPath)' '\(self.plistPath)' '\(self.configPath)' '\(self.versionPath)'
        """

        let appleScriptSource = """
        do shell script \(quotedAppleScriptString(script)) with administrator privileges
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            throw FanControlError.installFailed("Unable to create uninstall script")
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            throw FanControlError.installFailed(error.description)
        }
    }

    // Retry helper RPCs briefly because launchd may still be spinning the helper up after install.
    private func send(command: FanControlCommand, token: String) -> (ok: Bool, message: String?) {
        var lastMessage = "Unable to reach fan helper."
        for _ in 0..<12 {
            let result = sendOnce(command: command, token: token)
            if result.ok {
                return result
            }
            if let message = result.message, !message.isEmpty {
                lastMessage = message
            }
            usleep(250_000)
        }
        return (false, lastMessage)
    }

    private func sendOnce(command: FanControlCommand, token: String) -> (ok: Bool, message: String?) {
        let payload = HelperRequest(
            token: token,
            mode: command.mode.rawValue,
            targetRPM: command.targetRPM
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            return (false, "Unable to encode fan control request.")
        }
        let message = data + Data([0x0A])

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return (false, "Unable to open the fan helper socket.") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return (false, "Fan helper socket path is too long.")
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
        guard connected == 0 else { return (false, "Unable to connect to the fan helper.") }

        let writeResult = message.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        guard writeResult == message.count else { return (false, "Failed to send the fan control command.") }

        var responseBuffer = [UInt8](repeating: 0, count: 4096)
        let readCount = responseBuffer.withUnsafeMutableBytes { buffer in
            Darwin.read(fd, buffer.baseAddress, buffer.count)
        }
        guard readCount > 0 else { return (false, "No response from the fan helper.") }
        let responseData = Data(responseBuffer.prefix(readCount))
        guard let response = try? JSONDecoder().decode(HelperResponse.self, from: responseData) else {
            return (false, "Invalid response from the fan helper.")
        }
        return (response.ok, response.message)
    }

    // launchd keeps the helper alive and recreates the control socket after reboots.
    private func makeLaunchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installPath)</string>
                <string>--config</string>
                <string>\(configPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private func quotedAppleScriptString(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func installedVersion() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: versionPath)),
              let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return nil
        }
        return version
    }
}

private struct HelperInstallConfig: Codable {
    let token: String
    let socketPath: String
    let clientUID: uid_t
    let clientGID: gid_t
}

private struct HelperRequest: Codable {
    let token: String
    let mode: String
    let targetRPM: Int?
}

private struct HelperResponse: Codable {
    let ok: Bool
    let message: String?
}

enum FanControlError: LocalizedError {
    case missingHelperBinary
    case installFailed(String)

    var errorDescription: String? {
        switch self {
            case .missingHelperBinary:
                return "The bundled fan helper binary is missing."
            case .installFailed(let message):
                return "Failed to install the fan helper: \(message)"
        }
    }
}
