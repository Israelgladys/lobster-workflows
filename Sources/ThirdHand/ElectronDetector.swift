import AppKit
import Foundation

enum ElectronDetector {

    static func isElectron(_ target: AppTarget) -> Bool {
        guard let bundleId = target.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let frameworkPath = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
        return FileManager.default.fileExists(atPath: frameworkPath)
    }

    // Only connect to an explicitly enabled listener owned by the captured app.
    // Never scan common ports, terminate the app, or change its launch arguments.
    static func findDebugPort(pid: pid_t) async -> Int? {
        guard let port = portFromProcessArgs(pid: pid), ownsListener(pid: pid, port: port),
              await probePort(port) else { return nil }
        return port
    }

    static func debugPort(in arguments: String) -> Int? {
        let parts = arguments.split(whereSeparator: { $0.isWhitespace })
        guard let flag = parts.first(where: { $0.hasPrefix("--remote-debugging-port=") }),
              let port = Int(flag.dropFirst("--remote-debugging-port=".count)),
              (1...65535).contains(port) else { return nil }
        return port
    }

    private static func ownsListener(pid: pid_t, port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).contains(Substring(String(pid)))
    }

    private static func portFromProcessArgs(pid: pid_t) -> Int? {
        debugPort(in: processArguments(pid: pid))
    }

    private static func processArguments(pid: pid_t) -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Chromium-based apps (Electron or the Chromium Embedded Framework, like Spotify) can be driven
    /// in the background through a remote-debugging port.
    static func supportsDebugging(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        return ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains {
            FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
        }
    }

    static func debuggingArguments(port: Int) -> [String] {
        ["--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1"]
    }

    /// True when the app is running with a verified loopback debugging port.
    static func isReadyForBackground(pid: pid_t) async -> Bool {
        await findDebugPort(pid: pid) != nil
    }

    /// A free loopback port for the debugger to listen on.
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    /// Quits the app (asking it politely) and reopens it in the background with a loopback debugging port.
    /// Only called after the user accepts the relaunch.
    static func relaunchWithDebugging(bundleID: String, name: String) async throws -> (app: NSRunningApplication, port: Int) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
        for _ in 0..<100 where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw ControllerError.invalid("\(name) didn't quit, so it couldn't be relaunched for background control.")
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let port = freePort() else {
            throw ControllerError.invalid("\(name) couldn't be relaunched for background control.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = debuggingArguments(port: port)
        Log.info("Relaunching for background control bundle=\(bundleID)")
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<150 {
            try Task.checkCancellation()
            if WindowSnapshot.frontWindow(pid: app.processIdentifier) != nil, await probePort(port) { return (app, port) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ControllerError.invalid("\(name) reopened without a debugging connection, so it can't run in the background.")
    }

    static func probePort(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/json/version") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["Browser"] != nil || json?["webSocketDebuggerUrl"] != nil
        } catch {
            return false
        }
    }
}
