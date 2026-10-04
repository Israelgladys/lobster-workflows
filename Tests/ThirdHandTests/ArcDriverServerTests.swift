import XCTest
@testable import ThirdHand

/// ArcDriver against a fake MCP server: a small Python script that answers by tool name and logs every
/// message it reads, so tests can check replies, errors, cancellation, server exit and timeouts.
final class ArcDriverServerTests: XCTestCase {
    private var directory: URL!
    private var log: URL { directory.appendingPathComponent("messages.log") }

    private static let server = #"""
    import json, os, sys
    log = open(sys.argv[1], "a", buffering=1)
    log.write(f"pid {os.getpid()}\n")
    silent = len(sys.argv) > 2 and sys.argv[2] == "silent"
    for line in sys.stdin:
        message = json.loads(line)
        method, ident = message.get("method"), message.get("id")
        log.write(f"{method} {ident if ident is not None else (message.get('params') or {}).get('requestId')}\n")
        def reply(result):
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}) + "\n"); sys.stdout.flush()
        if method == "initialize":
            if not silent: reply({"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}})
        elif method == "tools/call":
            name, arguments = message["params"]["name"], message["params"].get("arguments", {})
            if name == "echo":
                reply({"content": [], "structuredContent": {"arguments": arguments, "pid": os.getpid()}})
            elif name == "fail":
                reply({"content": [], "isError": True, "structuredContent": {"code": "target_unavailable", "message": "gone"}})
            elif name == "exit":
                sys.exit(0)
            # "hang" never answers.
    """#

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("arc-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.server.write(to: directory.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func driver(silent: Bool = false, startTimeout: TimeInterval = 5, callTimeout: TimeInterval = 5) -> ArcDriver {
        let script = directory.appendingPathComponent("server.py").path, log = log.path
        return ArcDriver(command: { (URL(fileURLWithPath: "/usr/bin/python3"), [script, log] + (silent ? ["silent"] : [])) },
                         startTimeout: startTimeout, callTimeout: callTimeout)
    }

    private func messages() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func pids() -> [Int32] {
        messages().filter { $0.hasPrefix("pid ") }.compactMap { Int32($0.dropFirst(4)) }
    }

    func testRepliesAndToolErrors() async throws {
        let arc = driver()
        let echoed = try await arc.call("echo", ["x": 1])
        XCTAssertEqual((echoed["arguments"] as? [String: Any])?["x"] as? Int, 1)
        do {
            try await arc.call("fail")
            XCTFail("expected a tool error")
        } catch let error as ArcDriver.ToolError {
            XCTAssertEqual(error.code, "target_unavailable")
            XCTAssertEqual(error.message, "gone")
        }
    }

    func testCancellationIsSentAfterItsRequestAndTheServerKeepsWorking() async throws {
        let arc = driver()
        _ = try await arc.call("echo")
        let call = Task { try await arc.call("hang") }
        try await Task.sleep(nanoseconds: 300_000_000)
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        _ = try await arc.call("echo")
        let lines = messages()
        let request = try XCTUnwrap(lines.firstIndex(of: "tools/call 3"))
        let cancel = try XCTUnwrap(lines.firstIndex(of: "notifications/cancelled 3"))
        XCTAssertLessThan(request, cancel)
    }

    func testServerExitFailsTheCallAndTheNextCallRestartsIt() async throws {
        let arc = driver()
        _ = try await arc.call("echo")
        do {
            try await arc.call("exit")
            XCTFail("expected the call to fail when the server exits")
        } catch let error as ArcDriver.ToolError {
            XCTAssertEqual(error.code, "server_stopped")
        }
        let echoed = try await arc.call("echo")
        XCTAssertEqual(pids().count, 2)
        XCTAssertEqual(echoed["pid"] as? Int, pids().last.map(Int.init))
    }

    func testStartupTimeoutStopsTheServer() async throws {
        let arc = driver(silent: true, startTimeout: 0.5)
        do {
            try await arc.call("echo")
            XCTFail("expected the start to time out")
        } catch {}
        let pid = try XCTUnwrap(pids().first)
        // Closing its input ends the fake server.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "the half-started server is still running")
    }

    func testStuckCallRestartsTheServer() async throws {
        let arc = driver(callTimeout: 0.5)
        _ = try await arc.call("echo")
        do {
            try await arc.call("hang")
            XCTFail("expected a timeout")
        } catch {}
        let echoed = try await arc.call("echo")
        XCTAssertEqual(pids().count, 2)
        XCTAssertEqual(echoed["pid"] as? Int, pids().last.map(Int.init))
    }
}
