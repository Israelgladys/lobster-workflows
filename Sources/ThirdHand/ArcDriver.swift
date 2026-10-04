import AppKit
import Foundation

/// arc-cua's macOS driver, run as one long-lived `arc-cua mcp` child process and spoken to over MCP
/// (JSON-RPC, one message per line). It reads and acts on an exact window in the background, parking
/// minimized or hidden windows out of sight; `release` puts them back. As a child of Third Hand it
/// uses Third Hand's Accessibility and Screen Recording access.
final class ArcDriver: @unchecked Sendable {
    /// On unless `defaults write com.thirdhand.app ArcDriver -bool NO`.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "ArcDriver") as? Bool ?? true }
    static let defaultPackage = "arc-cua[macos] @ git+https://github.com/shhivv/arc-cua@4f313bd"
    /// `defaults write com.thirdhand.app ArcPackage "arc-cua[macos] @ file:///path/to/arc-cua"` runs a local checkout.
    static var package: String { UserDefaults.standard.string(forKey: "ArcPackage") ?? defaultPackage }
    /// Off with `defaults write com.thirdhand.app ArcSettle -bool NO`: input returns at once and the screen is
    /// watched instead (needed for arc-cua versions before settling).
    static var settles: Bool { UserDefaults.standard.object(forKey: "ArcSettle") as? Bool ?? true }
    static let logPath = NSHomeDirectory() + "/Library/Logs/Third Hand arc-cua.log"

    static let shared = ArcDriver()

    struct ToolError: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    /// The app changed under the snapshot (`changed` or `stale`), so nothing was done.
    struct Changed: Error {
        let status: String
    }

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var starting: Task<Void, Error>?

    /// The driver when it's enabled, running and able to work in the background; nil means use the built-in path.
    static func connect() async -> ArcDriver? {
        guard enabled else { return nil }
        do {
            try await shared.start()
            let status = try await shared.call("status")
            let permissions = status["permissions"] as? [String: Any]
            let accessibility = permissions?["accessibility"] as? Bool == true
            let background = status["background_input"] as? Bool == true
            Log.info("arc-cua status version=\(status["version"] ?? "?") accessibility=\(accessibility) "
                     + "screen=\(permissions?["screen_recording"] ?? "?") background=\(background) "
                     + "virtual_display=\(status["virtual_display"] ?? "?")")
            return accessibility && background ? shared : nil
        } catch {
            Log.info("arc-cua unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Process

    nonisolated static func uvx() -> String? {
        [NSHomeDirectory() + "/.local/bin/uvx", "/opt/homebrew/bin/uvx", "/usr/local/bin/uvx"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let starting { return starting }
            let task = Task { try await self.launch() }
            starting = task
            return task
        }
        do { try await task.value } catch {
            lock.withLock { starting = nil }
            throw error
        }
    }

    private func launch() async throws {
        guard let uvx = Self.uvx() else {
            throw ToolError(code: "not_installed", message: "uv isn't installed, so arc-cua can't run.")
        }
        // A write to a server that just exited must fail, not stop Third Hand.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvx)
        process.arguments = ["--from", Self.package, "arc-cua", "mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (uvx as NSString).deletingLastPathComponent + ":/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        process.standardError = FileHandle(forWritingAtPath: Self.logPath) ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Log.info("arc-cua exited status=\(process.terminationStatus)")
            self?.stopped()
        }
        try process.run()
        lock.withLock {
            self.process = process
            self.input = input.fileHandleForWriting
        }
        let reader = Thread { [weak self] in self?.read(output.fileHandleForReading) }
        reader.name = "arc-cua-output"
        reader.start()
        Log.info("arc-cua launched pid=\(process.processIdentifier) package=\(Self.package)")
        // The first launch may download and build the package.
        let started = Date()
        _ = try await AsyncTimeout.run(seconds: 120, message: "arc-cua didn't start.") {
            try await self.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                  "clientInfo": ["name": "Third Hand", "version": "1"]])
        }
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        Log.info("arc-cua ready ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }

    /// Fails waiting requests; the next call starts a new server.
    private func stopped() {
        let waiting = lock.withLock {
            let waiting = Array(pending.values)
            pending = [:]
            process = nil
            input = nil
            starting = nil
            return waiting
        }
        for continuation in waiting {
            continuation.resume(throwing: ToolError(code: "server_stopped", message: "arc-cua stopped unexpectedly."))
        }
    }

    private func read(_ handle: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                let continuation = lock.withLock { pending.removeValue(forKey: id) }
                continuation?.resume(returning: message)
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        lock.withLock {
            try? input?.write(contentsOf: data + Data("\n".utf8))
        }
    }

    // MARK: - Requests

    /// One JSON-RPC request. Cancelling the task tells the server to drop it; a cancelled request gets no reply.
    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = lock.withLock { nextID += 1; return nextID }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let running = lock.withLock {
                    guard input != nil, !Task.isCancelled else { return false }
                    pending[id] = continuation
                    return true
                }
                guard running else {
                    continuation.resume(throwing: Task.isCancelled ? CancellationError()
                        : ToolError(code: "server_stopped", message: "arc-cua isn't running."))
                    return
                }
                send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        } onCancel: {
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            guard let continuation else { return }
            send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id]])
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Calls a tool and returns its structured result and any image, starting the server if needed.
    func callWithImage(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> (result: [String: Any], image: Data?) {
        try await start()
        let reply = try await request("tools/call", ["name": tool, "arguments": arguments])
        if let error = reply["error"] as? [String: Any] {
            throw ToolError(code: "protocol_error", message: error["message"] as? String ?? "arc-cua request failed.")
        }
        let result = reply["result"] as? [String: Any] ?? [:]
        let structured = result["structuredContent"] as? [String: Any] ?? [:]
        if result["isError"] as? Bool == true {
            throw ToolError(code: structured["code"] as? String ?? "internal_error",
                            message: structured["message"] as? String ?? "arc-cua couldn't complete \(tool).")
        }
        let image = (result["content"] as? [[String: Any]])?
            .first { $0["type"] as? String == "image" }
            .flatMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        return (structured, image)
    }

    @discardableResult
    func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try await callWithImage(tool, arguments).result
    }

    /// Calls an input tool; throws `Changed` when the app changed under the snapshot and nothing was done.
    /// With `settle`, arc waits until the app has finished reacting and the result carries a fresh
    /// snapshot (`fresh`) and `settled: {reacted, timed_out, elapsed_ms}`.
    @discardableResult
    func input(_ tool: String, _ arguments: [String: Any], settle: Bool = false) async throws -> [String: Any] {
        var arguments = arguments
        if settle { arguments["settle"] = true }
        let result = try await call(tool, arguments)
        let status = result["status"] as? String ?? "done"
        guard status == "done" else { throw Changed(status: status) }
        return result
    }

    // MARK: - Mapping

    struct Snapshot {
        let id: String
        let windowID: Int
        let elements: [AccessibilityElement]
    }

    private nonisolated static let rowRoles: Set<String> = ["Row", "Cell", "OutlineRow", "TableRow"]

    /// arc elements as Third Hand's: roles regain their AX prefix, arc's ids are kept for acting, and each
    /// element in a row gets the row's other text as context, which tells identical controls apart.
    nonisolated static func snapshot(_ result: [String: Any]) -> Snapshot {
        let raw = result["elements"] as? [[String: Any]] ?? []
        var byID: [String: [String: Any]] = [:]
        for element in raw { if let id = element["id"] as? String { byID[id] = element } }
        func text(_ element: [String: Any]) -> String? {
            let name = element["name"] as? String
            if let name, !name.isEmpty { return name }
            return element["value"].map { "\($0)" }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func row(of id: String) -> String? {
            var current: String? = id
            for _ in 0..<12 {
                guard let key = current, let element = byID[key] else { return nil }
                if rowRoles.contains(element["role"] as? String ?? "") { return key }
                current = element["parent"] as? String
            }
            return nil
        }
        var rowOf: [String: String] = [:]
        var rowText: [String: [String]] = [:]
        for element in raw {
            guard let id = element["id"] as? String, let row = row(of: id) else { continue }
            rowOf[id] = row
            if let text = text(element), (rowText[row]?.count ?? 0) < 6 { rowText[row, default: []].append(String(text.prefix(60))) }
        }
        var next = 1
        let elements = raw.compactMap { element -> AccessibilityElement? in
            guard let driverID = element["id"] as? String else { return nil }
            // arc's ids ("ax_14") stay the same while an element exists; keep the number when there is one.
            let number = Int(driverID.split(separator: "_").last ?? "") ?? 100_000 + next
            next += 1
            let label = element["name"] as? String
            let value = element["value"].map { "\($0)" }
            var mapped = AccessibilityElement(
                id: number, role: "AX" + (element["role"] as? String ?? "Unknown"),
                label: label.flatMap { $0.isEmpty ? nil : $0 }, value: value,
                enabled: element["enabled"] as? Bool ?? true, actions: element["actions"] as? [String] ?? [],
                axElement: nil, focused: element["focused"] as? Bool ?? false)
            mapped.driverID = driverID
            if let row = rowOf[driverID], let texts = rowText[row] {
                let own = mapped.displayLabel
                let context = texts.filter { $0 != own }.joined(separator: " · ")
                if !context.isEmpty { mapped.context = String(context.prefix(100)) }
            }
            return mapped
        }
        return Snapshot(id: result["snapshot"] as? String ?? "", windowID: result["window_id"] as? Int ?? 0, elements: elements)
    }

    /// A Third Hand key and modifiers ("return", ["command"]) as an arc chord ("MOD+ENTER").
    nonisolated static func chord(key: String, modifiers: [String]) -> String? {
        let names = ["return": "ENTER", "tab": "TAB", "space": "SPACE", "delete": "BACKSPACE", "escape": "ESCAPE",
                     "left": "ARROW_LEFT", "right": "ARROW_RIGHT", "up": "ARROW_UP", "down": "ARROW_DOWN"]
        let lower = key.lowercased()
        let name: String
        if let named = names[lower] { name = named }
        else if lower.count == 1, lower.first.map({ $0.isLetter || $0.isNumber }) == true { name = lower.uppercased() }
        else if lower.hasPrefix("f"), let number = Int(lower.dropFirst()), (1...20).contains(number) { name = "F\(number)" }
        else { return nil }
        let order = [("command", "MOD"), ("control", "CTRL"), ("option", "ALT"), ("shift", "SHIFT")]
        guard modifiers.allSatisfy({ modifier in order.contains { $0.0 == modifier } }) else { return nil }
        return (order.filter { modifiers.contains($0.0) }.map(\.1) + [name]).joined(separator: "+")
    }
}
