import CryptoKit
import XCTest
@testable import ThirdHand

private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "e30." + CodexAuth.base64URL(payload) + ".sig"
}

private func tokenResponse(account: String = "acct_1", subject: String = "user_1", refresh: String? = "refresh_2") -> [String: Any] {
    var raw: [String: Any] = [
        "access_token": jwt(["sub": subject]),
        "id_token": jwt(["sub": subject, "email": "a@example.com",
                         "https://api.openai.com/auth": ["chatgpt_account_id": account]]),
        "expires_in": 3600.0
    ]
    if let refresh { raw["refresh_token"] = refresh }
    return raw
}

private func body(of request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

/// Serves canned responses; records every request.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        captured.httpBody = body(of: request)
        Self.requests.append(captured)
        let (status, data) = Self.handler!(captured)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session(_ handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        self.handler = handler
        requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

private func sse(_ events: [[String: Any]]) -> Data {
    Data(events.map { "event: \($0["type"]!)\ndata: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined().utf8)
}

private let fixtureTokens = CodexTokens(access: "access_1", refresh: "refresh_1", expires: Date().addingTimeInterval(3600),
                                        accountId: "acct_1", subject: "user_1", email: nil)

@MainActor
final class CodexAuthTests: XCTestCase {
    func testPKCEChallengeIsSHA256OfVerifierAndURLIdentifiesThirdHand() throws {
        let pkce = CodexAuth.makePKCE()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertEqual(pkce.challenge, CodexAuth.base64URL(Data(SHA256.hash(data: Data(pkce.verifier.utf8)))))
        let url = CodexAuth.authorizeURL(pkce: pkce, state: "state_1")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(items["client_id"], CodexAuth.clientID)
        XCTAssertEqual(items["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["scope"], "openid profile email offline_access")
        XCTAssertEqual(items["state"], "state_1")
        XCTAssertEqual(items["originator"], "third_hand")
    }

    func testTokensKeepAccountAndRejectAccountSwitchOnRefresh() throws {
        let first = try CodexAuth.normalize(tokenResponse())
        XCTAssertEqual(first.accountId, "acct_1")
        XCTAssertEqual(first.subject, "user_1")
        XCTAssertEqual(first.email, "a@example.com")
        let refreshed = try CodexAuth.normalize(tokenResponse(refresh: nil), previous: first)
        XCTAssertEqual(refreshed.refresh, "refresh_2", "A refresh without a new token keeps the previous one")
        XCTAssertThrowsError(try CodexAuth.normalize(tokenResponse(account: "acct_2"), previous: first))
        XCTAssertThrowsError(try CodexAuth.normalize(tokenResponse(subject: "user_2"), previous: first))
        XCTAssertThrowsError(try CodexAuth.normalize(["access_token": "opaque"]))
    }

    func testTokenRequestIsFormEncodedWithClientID() {
        let request = CodexAuth.tokenRequest(["grant_type": "refresh_token", "refresh_token": "a+b/c="])
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("client_id=\(CodexAuth.clientID)"))
        XCTAssertTrue(form.contains("refresh_token=a%2Bb/c%3D") || form.contains("refresh_token=a%2Bb%2Fc%3D"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }

    func testCallbackRequiresMatchingState() {
        let ok = CodexCallbackServer.evaluate(request: "GET /auth/callback?code=abc&state=s1 HTTP/1.1\r\nHost: localhost\r\n\r\n", state: "s1")
        XCTAssertEqual(try ok.2?.get(), "abc")
        let forged = CodexCallbackServer.evaluate(request: "GET /auth/callback?code=abc&state=other HTTP/1.1\r\n\r\n", state: "s1")
        XCTAssertThrowsError(try forged.2!.get())
        let denied = CodexCallbackServer.evaluate(request: "GET /auth/callback?error=access_denied&state=s1 HTTP/1.1\r\n\r\n", state: "s1")
        XCTAssertThrowsError(try denied.2!.get())
        XCTAssertNil(CodexCallbackServer.evaluate(request: "GET /favicon.ico HTTP/1.1\r\n\r\n", state: "s1").2)
    }

    func testLoopbackServerReceivesBrowserRedirect() async throws {
        let server = CodexCallbackServer(state: "s1")
        try await server.start()
        defer { server.stop() }
        let (_, favicon) = try await URLSession.shared.data(from: URL(string: "http://localhost:1455/favicon.ico")!)
        XCTAssertEqual((favicon as? HTTPURLResponse)?.statusCode, 404)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:1455/auth/callback?code=abc&state=s1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let code = try await server.code()
        XCTAssertEqual(code, "abc")
    }

    func testConcurrentRequestsShareOneRefresh() async throws {
        let session = StubProtocol.session { _ in (200, try! JSONSerialization.data(withJSONObject: tokenResponse())) }
        var expired = fixtureTokens
        expired.expires = Date().addingTimeInterval(-10)
        let saved = SavedTokens()
        let credentials = CodexCredentials(tokens: expired, session: session, persist: { saved.value = $0 })
        async let a = credentials.current()
        async let b = credentials.current()
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(saved.value?.refresh, "refresh_2")
        let form = String(decoding: StubProtocol.requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=refresh_1"))
    }
}

private final class SavedTokens: @unchecked Sendable { var value: CodexTokens? }

@MainActor
final class CodexClientTests: XCTestCase {
    func testStreamedFunctionCallAndRequestShape() async throws {
        let call: [String: Any] = ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "step",
                                   "arguments": #"{"instruction":"Type in the search field","text":"adele"}"#]
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "opaque", "summary": []]
        let session = StubProtocol.session { _ in (200, sse([
            ["type": "response.created", "response": ["id": "resp_1"]],
            ["type": "response.output_item.done", "item": reasoning],
            ["type": "response.output_item.done", "item": call],
            ["type": "response.completed", "response": ["id": "resp_1", "output": [reasoning, call]]]
        ])) }
        let client = CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: session, model: "gpt-test")
        let response = try await client.respond(instructions: "Be helpful", input: [CodexAgent.userMessage("hi")], tools: CodexAgent.tools)
        XCTAssertEqual(response.functionCalls, [CodexFunctionCall(callID: "call_1", name: "step", arguments: call["arguments"] as! String)])
        XCTAssertEqual(response.output.count, 2, "Reasoning items are kept for the next turn")

        let request = StubProtocol.requests[0]
        XCTAssertEqual(request.url, CodexClient.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access_1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "third_hand")
        XCTAssertFalse((request.value(forHTTPHeaderField: "User-Agent") ?? "").contains("opencode"))
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["instructions"] as? String, "Be helpful")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(json["include"] as? [String], ["reasoning.encrypted_content"])
    }

    func testFailedStreamAndHTTPErrorsSendNoAction() async throws {
        let failing = StubProtocol.session { _ in (200, sse([["type": "response.failed", "response": ["error": ["message": "boom"]]]])) }
        do {
            _ = try await CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: failing)
                .respond(instructions: "x", input: [], tools: [])
            XCTFail("A failed stream must not produce calls")
        } catch let error as CodexServiceError { XCTAssertEqual(error.status, 502) }

        let expired = StubProtocol.session { _ in (401, Data(#"{"detail":"Unauthorized"}"#.utf8)) }
        do {
            _ = try await CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: expired)
                .respond(instructions: "x", input: [], tools: [])
            XCTFail("Expected an auth error")
        } catch let error as CodexServiceError {
            XCTAssertEqual(error.status, 401)
            XCTAssertTrue(error.message.contains("Sign in again"))
        }
    }

    func testSSELineParsingIgnoresNonDataLines() {
        XCTAssertNil(CodexClient.event(fromLine: "event: response.completed"))
        XCTAssertNil(CodexClient.event(fromLine: "data: [DONE]"))
        XCTAssertEqual(CodexClient.event(fromLine: #"data: {"type":"x"}"#)?["type"] as? String, "x")
    }
}

@MainActor
private final class ScriptedPlanner: Planner {
    var turns: [[[String: Any]]]
    var inputs: [[[String: Any]]] = []
    init(_ turns: [[[String: Any]]]) { self.turns = turns }
    func respond(instructions: String, input: [[String: Any]], tools: [[String: Any]], effort: String) async throws -> CodexResponse {
        inputs.append(input)
        return CodexResponse(output: turns.isEmpty ? [] : turns.removeFirst())
    }
}

@MainActor
private final class RecordingLayer: ActionLayer {
    var steps: [(String, String?)] = []
    var status = "verified"
    func currentElements() async throws -> [AccessibilityElement] {
        [AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: nil, enabled: true, actions: [], axElement: nil)]
    }
    func perform(instruction: String, text: String?) async throws -> StepOutcome {
        steps.append((instruction, text))
        let value = text ?? "screen \(steps.count)"
        return StepOutcome(status: status, detail: "ok", elements: [
            AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: value, enabled: true, actions: [], axElement: nil)
        ])
    }
}

private func call(_ id: String, _ name: String, _ args: [String: Any?]) -> [String: Any] {
    let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: args.mapValues { $0 ?? NSNull() }), as: UTF8.self)
    return ["type": "function_call", "call_id": id, "name": name, "arguments": arguments]
}

@MainActor
final class CodexAgentTests: XCTestCase {
    func testPlannerTextIsTypedVerbatimAndDoneFinishes() async throws {
        let planner = ScriptedPlanner([
            [call("c1", "step", ["instruction": "Type in the Search field", "text": "Adele — Skyfall (2012)"])],
            [call("c2", "step", ["instruction": "Press Return", "text": nil])],
            [call("c3", "done", ["summary": "Searched for Skyfall."])]
        ])
        let layer = RecordingLayer()
        let outcome = try await CodexAgent(planner: planner).run(goal: "play skyfall", appName: "Music", layer: layer)
        XCTAssertEqual(outcome, .done("Searched for Skyfall."))
        XCTAssertEqual(layer.steps.map(\.0), ["Type in the Search field", "Press Return"])
        XCTAssertEqual(layer.steps[0].1, "Adele — Skyfall (2012)")
        XCTAssertNil(layer.steps[1].1)
    }

    func testOnlyNewestScreenIsSentInFull() async throws {
        let planner = ScriptedPlanner([
            [call("c1", "step", ["instruction": "Click Search", "text": nil])],
            [call("c2", "step", ["instruction": "Click Search again", "text": nil])],
            [call("c3", "done", ["summary": "ok"])]
        ])
        _ = try await CodexAgent(planner: planner).run(goal: "g", appName: "App", layer: RecordingLayer())
        let last = planner.inputs[2]
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: last), as: UTF8.self)
        XCTAssertFalse(serialized.contains("Current screen"), "The opening screen is compacted after a step")
        XCTAssertFalse(serialized.contains("screen 1"), "Older step screens are compacted")
        XCTAssertTrue(serialized.contains("screen 2"))
        let outputs = last.filter { $0["type"] as? String == "function_call_output" }.map { $0["call_id"] as? String }
        XCTAssertEqual(outputs, ["c1", "c2"])
    }

    func testEveryExtraCallGetsAnOutputAndIsNotExecuted() async throws {
        let planner = ScriptedPlanner([
            [call("c1", "step", ["instruction": "Click A", "text": nil]), call("c2", "step", ["instruction": "Click B", "text": nil])],
            [call("c3", "fail", ["reason": "Needs sign-in."])]
        ])
        let layer = RecordingLayer()
        let outcome = try await CodexAgent(planner: planner).run(goal: "g", appName: "App", layer: layer)
        XCTAssertEqual(outcome, .failed("Needs sign-in."))
        XCTAssertEqual(layer.steps.count, 1)
        let outputs = planner.inputs[1].filter { $0["type"] as? String == "function_call_output" }.map { $0["call_id"] as? String }
        XCTAssertEqual(outputs, ["c1", "c2"])
    }

    func testPlannerThatNeverCallsAToolStopsAfterOneNudge() async throws {
        let message: [String: Any] = ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "I can't do that."]]]
        let planner = ScriptedPlanner([[message], [message]])
        let layer = RecordingLayer()
        let outcome = try await CodexAgent(planner: planner).run(goal: "g", appName: "App", layer: layer)
        XCTAssertEqual(outcome, .failed("I can't do that."))
        XCTAssertEqual(planner.inputs.count, 2)
        XCTAssertTrue(layer.steps.isEmpty)
    }

    func testInvalidStepArgumentsAreRejectedWithoutInput() async throws {
        let planner = ScriptedPlanner([
            [call("c1", "step", ["instruction": "  ", "text": nil])],
            [call("c2", "done", ["summary": "ok"])]
        ])
        let layer = RecordingLayer()
        _ = try await CodexAgent(planner: planner).run(goal: "g", appName: "App", layer: layer)
        XCTAssertTrue(layer.steps.isEmpty)
        let output = planner.inputs[1].last?["output"] as? String
        XCTAssertTrue(output?.contains("rejected") == true)
    }

    func testStepToolRequiresExplicitNullableText() throws {
        let step = CodexAgent.tools.first { $0["name"] as? String == "step" }!
        let parameters = step["parameters"] as! [String: Any]
        XCTAssertEqual(parameters["required"] as? [String], ["instruction", "text"])
        XCTAssertEqual(step["strict"] as? Bool, true)
    }
}
