import XCTest
import ApplicationServices
@testable import ThirdHand

private func control(_ id: Int, _ role: String, _ label: String = "Control", value: String? = nil,
                     enabled: Bool = true, focused: Bool = false, source: String = "accessibility") -> AccessibilityElement {
    AccessibilityElement(id: id, role: role, label: label, value: value, enabled: enabled, actions: [], axElement: nil,
                         frame: source == "ocr" ? CGRect(x: 0, y: 0, width: 40, height: 20) : nil, focused: focused, source: source)
}

private func requestBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@MainActor
final class JevTests: XCTestCase {
    func testOnlyCompatibleEnabledControlsAreOffered() {
        let controls = [control(1, "AXButton"), control(2, "AXTextField"), control(3, "AXTextField", enabled: false), control(4, "AXStaticText")]
        let targets = JevClient.targets(controls)
        XCTAssertEqual(Set(targets["CLICK"]!.keys), ["1", "2"])
        XCTAssertEqual(Set(targets["TYPE_TEXT"]!.keys), ["2"])
        XCTAssertTrue(JevClient.targets([control(1, "AXWebArea")]).isEmpty)
    }

    func testGroundRequestAsksOnlyForATargetWithNoneOption() throws {
        let candidates = [control(1, "AXButton", "Play"), control(2, "AXButton", "Pause")]
        let prepared = try JevClient.groundRequest(action: "click", target: "Play", role: "button", candidates: candidates, appName: "Spotify")
        let body = try JSONSerialization.jsonObject(with: prepared.data) as! [String: Any]
        let questions = body["questions"] as! [String: [String: Any]]
        XCTAssertEqual(Set(questions.keys), ["target"], "Jev never chooses the kind of action")
        let criteria = questions["target"]!["criteria"] as! [String: String]
        XCTAssertEqual(Set(criteria.keys), ["1", "2", JevClient.noneKey])
        let serialized = String(decoding: prepared.data, as: UTF8.self)
        for forbidden in ["image_url", "base64", "screenshot", "data:image"] { XCTAssertFalse(serialized.contains(forbidden)) }
    }

    func testEveryGroundRequestRespectsChoiceLimitAndKeepsRelevantLateTarget() throws {
        for count in [254, 255, 536] {
            var candidates = (1...count).map { control($0, "AXButton") }
            candidates.append(control(9000, "AXButton", "Export"))
            let prepared = try JevClient.groundRequest(action: "click", target: "Export", role: nil, candidates: candidates, appName: "App")
            let body = try JSONSerialization.jsonObject(with: prepared.data) as! [String: Any]
            let criteria = (body["questions"] as! [String: [String: Any]])["target"]!["criteria"] as! [String: String]
            XCTAssertLessThanOrEqual(criteria.count, JevClient.maxChoices)
            XCTAssertNotNil(criteria[JevClient.noneKey])
            XCTAssertNotNil(prepared.offered["9000"])
        }
    }

    func testOversizedGroundRequestIsBounded() throws {
        var candidates = (1...554).map { control($0, "AXButton", String(repeating: "🎵", count: 1000), value: String(repeating: "long", count: 1000)) }
        candidates.append(control(900, "AXTextField", "Search", focused: true))
        let prepared = try JevClient.groundRequest(action: "type", target: "Search", role: "textField", candidates: candidates, appName: "Spotify")
        XCTAssertLessThanOrEqual(prepared.data.count, JevClient.maxRequestBytes)
        XCTAssertNotNil(prepared.offered["900"])
    }

    func testDecodeGroundReturnsOfferedTargetOrNilForNone() throws {
        let offered = ["2": control(2, "AXButton", "Save")]
        XCTAssertEqual(try JevClient.decodeGround(Data(#"{"answers":{"target":{"choice":"2"}}}"#.utf8), offered: offered)?.id, 2)
        XCTAssertNil(try JevClient.decodeGround(Data(#"{"answers":{"target":{"choice":"__none__"}}}"#.utf8), offered: offered))
        XCTAssertThrowsError(try JevClient.decodeGround(Data(#"{"answers":{"target":{"choice":"7"}}}"#.utf8), offered: offered))
        for payload in ["{}", "not json", #"{"answers":{}}"#] {
            XCTAssertThrowsError(try JevClient.decodeGround(Data(payload.utf8), offered: offered))
        }
    }

    func testGroundCallIsTextOnlyAndReturnsOCRRegion() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GroundProtocol.self]
        let client = JevClient(apiKey: "selector-key", session: URLSession(configuration: config))
        let ocr = control(2, "AXStaticText", "Save", source: "ocr")
        let chosen = try await client.ground(action: "click", target: "Save", role: nil, candidates: [ocr], appName: "Test")
        XCTAssertEqual(chosen?.id, 2)
    }

    func testHTTP400RetainsValidationReasonAsServiceError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectedRequestProtocol.self]
        let client = JevClient(apiKey: "fixture-key", session: URLSession(configuration: config))
        do {
            _ = try await client.ground(action: "click", target: "Save", role: nil, candidates: [control(1, "AXButton")], appName: "Test")
            XCTFail("A rejected request must not become an action")
        } catch let error as JevServiceError {
            XCTAssertEqual(error.status, 400)
            XCTAssertTrue(error.detail.contains("255"))
        } catch { XCTFail("Expected a non-recoverable service error") }
    }

    func testValidationArrayPreservesReasonWithoutEchoingInput() {
        let data = Data(#"{"detail":[{"msg":"Context limit exceeded","input":"private input"}]}"#.utf8)
        XCTAssertEqual(JevClient.errorDetail(data, redacting: "key"), "Context limit exceeded")
    }

    func testServiceDiagnosticIsBoundedAndRedactsCredential() {
        let data = Data(#"{"error":{"message":"Too many choices for fixture-key"}}"#.utf8)
        XCTAssertEqual(JevClient.errorDetail(data, redacting: "fixture-key"), "Too many choices for [redacted]")
        XCTAssertFalse(JevClient.errorDetail(Data("not json".utf8), redacting: "").isEmpty)
    }
}

@MainActor
final class PlanStepTests: XCTestCase {
    func testActionsRequireTheirOwnFields() {
        XCTAssertEqual(try PlanStep.parse(["action": "type", "target": "Search", "role": "textField", "text": " Adele "]).get().text, " Adele ",
                       "Text is kept verbatim")
        XCTAssertThrowsError(try PlanStep.parse(["action": "type", "target": "Search"]).get())
        XCTAssertThrowsError(try PlanStep.parse(["action": "type", "text": "x"]).get())
        XCTAssertThrowsError(try PlanStep.parse(["action": "click", "target": NSNull()]).get())
        XCTAssertThrowsError(try PlanStep.parse(["action": "scroll", "direction": "left"]).get())
        XCTAssertThrowsError(try PlanStep.parse(["action": "drag"]).get())
        XCTAssertEqual(try PlanStep.parse(["action": "wait"]).get().action, "wait")
    }

    func testKeysAndShortcutsParseWithAliases() throws {
        let press = try PlanStep.parse(["action": "press", "key": "Cmd+Shift+Z"]).get()
        XCTAssertEqual(press.key, "z")
        XCTAssertEqual(press.modifiers, ["command", "shift"])
        XCTAssertEqual(try PlanStep.parse(["action": "press", "key": "return"]).get().modifiers, [])
        XCTAssertThrowsError(try PlanStep.parse(["action": "press", "key": "hyper+q"]).get())
        XCTAssertThrowsError(try PlanStep.parse(["action": "press", "key": "command+command+q"]).get())
        XCTAssertThrowsError(try PlanStep.parse(["action": "press", "key": "pageup"]).get())
    }

    func testExactMatchIgnoresCaseAndSpacingAndUsesRoleOnlyToBreakTies() {
        let pool = [control(1, "AXButton", "Play"), control(2, "AXRow", "Play"), control(3, "AXTextField", "What do you want to play?")]
        XCTAssertEqual(StepMatcher.exact(target: "what do  you want to play?", role: "textField", in: pool).map(\.id), [3])
        XCTAssertEqual(StepMatcher.exact(target: "Play", role: nil, in: pool).map(\.id), [1, 2], "Duplicates go to Jev")
        XCTAssertEqual(StepMatcher.exact(target: "Play", role: "row", in: pool).map(\.id), [2])
        XCTAssertEqual(StepMatcher.exact(target: "What do you want to play?", role: "button", in: pool).map(\.id), [3],
                       "A wrong role never hides the only label match")
        XCTAssertTrue(StepMatcher.exact(target: "Pla", role: nil, in: pool).isEmpty, "Near misses go to Jev")
    }

    func testFieldMatchesByLabelEvenWhenItShowsAValue() {
        let field = control(1, "AXTextField", "Search", value: "Frank Ocean")
        XCTAssertEqual(StepMatcher.exact(target: "Search", role: "textField", in: [field]).map(\.id), [1])
    }
}

private final class GroundProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "api.typesafe.ai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer selector-key")
        let body = requestBody(request)
        XCTAssertEqual(Set(body.keys), ["model", "questions", "state"])
        let criteria = ((body["questions"] as! [String: [String: Any]])["target"]!["criteria"]) as! [String: String]
        XCTAssertTrue(criteria["2"]!.contains("(ocr text)"))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"answers":{"target":{"choice":"2"}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RejectedRequestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Choice accepts at most 255 options"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
