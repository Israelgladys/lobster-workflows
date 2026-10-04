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

    /// The driver when it's enabled, running and able to work in the background; nil means background control
    /// is unavailable (Chromium apps can still use a debugging connection; others run on screen).
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

    /// The Python and arc-cua shipped in the app (Scripts/bundle-arc-cua.sh), when present.
    nonisolated static var bundledPython: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("arc-cua/python/bin/python3"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The server to run: the bundled runtime, or `uvx` with the pinned package (a development build, or an
    /// `ArcPackage` override). Nil when neither is available.
    nonisolated static func defaultCommand() -> (executable: URL, arguments: [String])? {
        // -I ignores the user's Python environment; -B writes no bytecode into the signed app.
        if UserDefaults.standard.string(forKey: "ArcPackage") == nil, let python = bundledPython {
            return (python, ["-I", "-B", "-m", "arc_cua", "mcp"])
        }
        return uvx().map { (URL(fileURLWithPath: $0), ["--from", package, "arc-cua", "mcp"]) }
    }

    private let command: () -> (executable: URL, arguments: [String])?
    private let startTimeout: TimeInterval
    private let callTimeout: TimeInterval

    /// Tests pass a fake server and short timeouts.
    init(command: @escaping () -> (executable: URL, arguments: [String])? = ArcDriver.defaultCommand,
         startTimeout: TimeInterval = 120, callTimeout: TimeInterval = 60) {
        self.command = command
        self.startTimeout = startTimeout
        self.callTimeout = callTimeout
    }

    func start() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let starting { return starting }
            let task = Task { try await self.launch() }
            starting = task
            return task
        }
        do { try await task.value } catch {
            // Only this start's failure; a newer start may already be under way.
            lock.withLock { if starting == task { starting = nil } }
            throw error
        }
    }

    private func launch() async throws {
        guard let command = command() else {
            throw ToolError(code: "not_installed", message: "arc-cua isn't in this build and uv isn't installed, so arc-cua can't run.")
        }
        // A write to a server that just exited must fail, not stop Third Hand.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = command.executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        process.standardError = FileHandle(forWritingAtPath: Self.logPath) ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Log.info("arc-cua exited status=\(process.terminationStatus)")
            self?.stopped(process)
        }
        try process.run()
        lock.withLock {
            self.process = process
            self.input = input.fileHandleForWriting
        }
        let reader = Thread { [weak self] in self?.read(output.fileHandleForReading) }
        reader.name = "arc-cua-output"
        reader.start()
        Log.info("arc-cua launched pid=\(process.processIdentifier) arguments=\(command.arguments.joined(separator: " "))")
        // The first launch may download and build the package.
        let started = Date()
        do {
            _ = try await AsyncTimeout.run(seconds: startTimeout, message: "arc-cua didn't start.") {
                try await self.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                      "clientInfo": ["name": "Third Hand", "version": "1"]])
            }
        } catch {
            // Don't leave a half-started server behind; the next call starts a fresh one.
            stop(process)
            throw error
        }
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        Log.info("arc-cua ready ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }

    /// Ends a server: closing its input lets it restore parked windows before exiting; it is killed if it doesn't.
    private func stop(_ process: Process) {
        let input = lock.withLock { self.process === process ? self.input : nil }
        try? input?.close()
        stopped(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }

    /// Fails the requests waiting on `process`; the next call starts a new server. A server that was
    /// already replaced changes nothing.
    private func stopped(_ process: Process) {
        let waiting: [CheckedContinuation<[String: Any], Error>] = lock.withLock {
            guard self.process === process else { return [] }
            let waiting = Array(pending.values)
            pending = [:]
            self.process = nil
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
        lock.withLock { write(message) }
    }

    /// Writes one message; the caller holds `lock`, so messages go out whole and in the order they were made.
    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? input?.write(contentsOf: data + Data("\n".utf8))
    }

    // MARK: - Requests

    /// One JSON-RPC request. Cancelling the task tells the server to drop it; a cancelled request gets no reply.
    /// The request is registered and written under one lock, so a cancellation can't reach the server before
    /// the request it cancels.
    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = lock.withLock { nextID += 1; return nextID }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let running = lock.withLock {
                    guard input != nil, !Task.isCancelled else { return false }
                    pending[id] = continuation
                    write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                    return true
                }
                guard running else {
                    continuation.resume(throwing: Task.isCancelled ? CancellationError()
                        : ToolError(code: "server_stopped", message: "arc-cua isn't running."))
                    return
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                let continuation = pending.removeValue(forKey: id)
                if continuation != nil {
                    write(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id]])
                }
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Calls a tool and returns its structured result and any image, starting the server if needed. A call that
    /// takes longer than `callTimeout` (the server stuck on an unresponsive app) restarts the server.
    func callWithImage(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> (result: [String: Any], image: Data?) {
        try await start()
        let server = lock.withLock { process }
        let reply = try await AsyncTimeout.run(seconds: callTimeout, message: "arc-cua didn't answer \(tool) in time.", onTimeout: {
            Log.info("arc-cua timed out tool=\(tool); restarting it")
            if let server { self.stop(server) }
        }) {
            try await self.request("tools/call", ["name": tool, "arguments": arguments])
        }
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
    /// In a `terminal`, the text area takes typing although arc offers no TYPE_TEXT (its value isn't
    /// settable): Third Hand types there with key events.
    nonisolated static func snapshot(_ result: [String: Any], terminal: Bool = false) -> Snapshot {
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
        let window = result["window_id"] as? Int ?? 0
        let elements = raw.compactMap { element -> AccessibilityElement? in
            guard let driverID = element["id"] as? String else { return nil }
            // arc's ids ("ax_14") stay the same while an element exists; keep the number when there is one.
            let number = Int(driverID.split(separator: "_").last ?? "") ?? 100_000 + next
            next += 1
            let label = element["name"] as? String
            let value = element["value"].map { "\($0)" }
            let role = "AX" + (element["role"] as? String ?? "Unknown")
            var actions = element["actions"] as? [String] ?? []
            if terminal, role == "AXTextArea", !actions.contains("TYPE_TEXT") { actions.append("TYPE_TEXT") }
            var mapped = AccessibilityElement(
                id: number, role: role,
                label: label.flatMap { $0.isEmpty ? nil : $0 }, value: value,
                enabled: element["enabled"] as? Bool ?? true, actions: actions,
                axElement: nil, focused: element["focused"] as? Bool ?? false)
            // arc numbers elements per window, so the window is part of the identity.
            mapped.driverID = "\(window)/\(driverID)"
            if let row = rowOf[driverID], let texts = rowText[row] {
                let own = mapped.displayLabel
                let context = texts.filter { $0 != own }.joined(separator: " · ")
                if !context.isEmpty { mapped.context = String(context.prefix(100)) }
            }
            return mapped
        }
        return Snapshot(id: result["snapshot"] as? String ?? "", windowID: window, elements: elements)
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
