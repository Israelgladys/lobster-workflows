import XCTest
import ApplicationServices
@testable import ThirdHand

@MainActor
final class JevTests: XCTestCase {
    func element(_ id: Int, _ role: String, enabled: Bool = true) -> AccessibilityElement {
        AccessibilityElement(id: id, role: role, label: "Control", value: "", enabled: enabled, actions: [], axElement: AXUIElementCreateSystemWide())
    }

    func testLargeOCRRecoveryRequestIsBoundedAndRetainsRelevantLateTarget() throws {
        var controls = (1...554).map { id in
            AccessibilityElement(id: id, role: "AXButton", label: String(repeating: "🎵", count: 1000),
                value: String(repeating: "long content", count: 1000), enabled: true, actions: [], axElement: nil)
        }
        controls.append(AccessibilityElement(id: 900, role: "AXStaticText", label: "Play Skyfall Adele", value: nil,
            enabled: true, actions: [], axElement: nil, frame: CGRect(x: 1, y: 1, width: 40, height: 20), source: "ocr"))
        controls.append(AccessibilityElement(id: 901, role: "AXTextField", label: "Search", value: "Adele",
            enabled: true, actions: [], axElement: nil, focused: true))
        let prepared = try JevClient.preparedRequest(goal: "Play Skyfall by Adele", elements: controls, appName: "Spotify",
            history: (1...30).map { _ in ActionHistory(action: String(repeating: "old", count: 1000), result: "unverified") })
        XCTAssertLessThanOrEqual(prepared.data.count, JevClient.maxRequestBytes)
        XCTAssertNotNil(prepared.offered["CLICK_TEXT"]?["900"])
        XCTAssertNotNil(prepared.offered["TYPE_TEXT"]?["901"])
        let body = try JSONSerialization.jsonObject(with: prepared.data) as! [String: Any]
        let questions = body["questions"] as! [String: [String: Any]]
        for (operation, targets) in prepared.offered {
            let criteria = questions[operation.lowercased() + "_target"]!["criteria"] as! [String: String]
            XCTAssertEqual(Set(criteria.keys).subtracting(["__none__"]), Set(targets.keys))
        }
        let response = Data(#"{"answers":{"operation":{"choice":"CLICK"},"click_target":{"choice":"554"}}}"#.utf8)
        XCTAssertThrowsError(try JevClient.decode(response, elements: controls, offered: prepared.offered))
    }

    func testOversizedGoalIsRejectedWithoutSilentlyChangingIt() {
        XCTAssertThrowsError(try JevClient.preparedRequest(goal: String(repeating: "a", count: 4001),
            elements: [], appName: "Test", history: []))
    }

    func testValidationArrayPreservesReasonWithoutEchoingInput() {
        let data = Data(#"{"detail":[{"msg":"Context limit exceeded","input":"private input"}]}"#.utf8)
        XCTAssertEqual(JevClient.errorDetail(data, redacting: "key"), "Context limit exceeded")
    }

    func testPlaybackEvidenceSurvivesRequestCompaction() throws {
        var controls = (1...500).map { element($0, "AXButton") }
        controls.append(AccessibilityElement(id: 700, role: "AXGroup", label: "Now playing: Skyfall by Adele",
            value: nil, enabled: true, actions: [], axElement: nil))
        controls.append(AccessibilityElement(id: 701, role: "AXButton", label: "Pause",
            value: nil, enabled: true, actions: [], axElement: nil))
        let request = try JevClient.preparedRequest(goal: "Play Skyfall by Adele", elements: controls, appName: "Spotify", history: [])
        let body = try JSONSerialization.jsonObject(with: request.data) as! [String: Any]
        let state = body["state"] as! [String: Any]
        let ids = (state["elements"] as! [[String: Any]]).compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("700"))
        XCTAssertTrue(ids.contains("701"))
    }

    func testOnlyCompatibleEnabledControlsAreOffered() {
        let controls = [element(1, "AXButton"), element(2, "AXTextField"), element(3, "AXTextField", enabled: false), element(4, "AXStaticText")]
        let targets = JevClient.targets(controls)
        XCTAssertEqual(Set(targets["CLICK"]!.keys), ["1", "2"])
        XCTAssertEqual(Set(targets["TYPE_TEXT"]!.keys), ["2"])
        XCTAssertTrue(JevClient.targets([element(1, "AXWebArea")]).isEmpty)
    }

    func testSelectorDoesNotGenerateTextOrSendScreenshots() throws {
        let body = JevClient.requestBody(goal: "Search music", elements: [element(1, "AXTextField")], appName: "Example", history: [])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        let questions = body["questions"] as! [String: Any]
        XCTAssertNotNil(questions["type_text_target"])
        XCTAssertNil(questions["type_text_value"])
        XCTAssertNil(body["messages"])
    }

    func testTextDecisionRetainsTargetForSeparateGenerator() throws {
        let data = Data(#"{"answers":{"operation":{"choice":"TYPE_TEXT","confidence":0.99},"type_text_target":{"choice":"2","confidence":0.99}}}"#.utf8)
        let decision = try JevClient.decode(data, elements: [element(2, "AXTextField")]).decision
        XCTAssertEqual(decision.targetIndex, "2")
        XCTAssertNil(decision.textValue)
    }

    func testRejectsWrongTargetAndUnsupportedOperation() {
        let wrongTarget = Data(#"{"answers":{"operation":{"choice":"TYPE_TEXT","confidence":0.99},"type_text_target":{"choice":"1","confidence":0.99}}}"#.utf8)
        XCTAssertThrowsError(try JevClient.decode(wrongTarget, elements: [element(1, "AXButton"), element(2, "AXTextField")]))
        let unsupported = Data(#"{"answers":{"operation":{"choice":"TYPE_TEXT","confidence":0.99}}}"#.utf8)
        XCTAssertThrowsError(try JevClient.decode(unsupported, elements: [element(1, "AXButton")]))
    }

    func testSelectorRequestIsTextOnlyEvenForOCR() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TextOnlyProtocol.self]
        let client = JevClient(apiKey: "selector-key", session: URLSession(configuration: config))
        let ocr = AccessibilityElement(id: 2, role: "AXStaticText", label: "Save", value: nil, enabled: true,
            actions: [], axElement: nil, frame: CGRect(x: 0, y: 0, width: 40, height: 20), source: "ocr")
        let result = try await client.decide(goal: "Click Save", elements: [ocr], appName: "Test", history: [])
        XCTAssertEqual(result.decision.operation, "CLICK_TEXT")
        XCTAssertEqual(result.decision.targetIndex, "2")
    }

    func testEveryChoiceQuestionRespectsAPILimitIncludingNone() throws {
        for count in [254, 255, 500, 536] {
            let controls = (1...count).map { element($0, "AXTextField") }
            let body = JevClient.requestBody(goal: "Search", elements: controls, appName: "Test", history: [])
            let questions = body["questions"] as! [String: [String: Any]]
            for question in questions.values where question["type"] as? String == "choice" {
                XCTAssertLessThanOrEqual((question["criteria"] as! [String: String]).count, 255)
            }
            let criteria = questions["click_target"]!["criteria"] as! [String: String]
            XCTAssertNotNil(criteria["__none__"])
        }
    }

    func testRelevantControlBeyondFirst254IsRetainedAndUnofferedResponseRejected() throws {
        var controls = (1...500).map { element($0, "AXButton") }
        controls.append(AccessibilityElement(id: 501, role: "AXButton", label: "Export", value: nil, enabled: true, actions: [], axElement: nil))
        let offered = JevClient.offeredTargets(controls, goal: "Click Export")
        XCTAssertNotNil(offered["CLICK"]?["501"])
        XCTAssertNil(offered["CLICK"]?["500"])
        let response = Data(#"{"answers":{"operation":{"choice":"CLICK"},"click_target":{"choice":"500"}}}"#.utf8)
        XCTAssertThrowsError(try JevClient.decode(response, elements: controls, offered: offered))
    }

    func testOCRChoicesAlsoLeaveRoomForNone() {
        let regions = (1...536).map { id in
            AccessibilityElement(id: id, role: "AXStaticText", label: "Label", value: nil, enabled: true, actions: [], axElement: nil,
                frame: CGRect(x: 0, y: 0, width: 30, height: 10), source: "ocr")
        }
        let body = JevClient.requestBody(goal: "Click label", elements: regions, appName: "Test", history: [])
        let questions = body["questions"] as! [String: [String: Any]]
        XCTAssertEqual((questions["click_text_target"]!["criteria"] as! [String: String]).count, 255)
    }

    func testHTTP400RetainsValidationReasonAsServiceError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectedRequestProtocol.self]
        let client = JevClient(apiKey: "fixture-key", session: URLSession(configuration: config))
        do {
            _ = try await client.decide(goal: "Test", elements: [], appName: "Test", history: [])
            XCTFail("A rejected request must not become an action")
        } catch let error as JevServiceError {
            XCTAssertEqual(error.status, 400)
            XCTAssertTrue(error.detail.contains("255"))
        } catch { XCTFail("Expected a non-recoverable service error") }
    }

    func testServiceDiagnosticIsBoundedAndRedactsCredential() {
        let data = Data(#"{"error":{"message":"Too many choices for fixture-key"}}"#.utf8)
        XCTAssertEqual(JevClient.errorDetail(data, redacting: "fixture-key"), "Too many choices for [redacted]")
        XCTAssertFalse(JevClient.errorDetail(Data("not json".utf8), redacting: "").isEmpty)
    }

    func testSearchSubmissionDoesNotRequireAnotherTextCall() throws {
        let data = Data(#"{"answers":{"operation":{"choice":"PRESS_RETURN","confidence":0.99}}}"#.utf8)
        let decision = try JevClient.decode(data, elements: []).decision
        XCTAssertEqual(decision.operation, "KEY_PRESS")
        XCTAssertEqual(decision.key, "return")
        try decision.validate(elements: [], hasScreenshot: false)
    }
}

private final class TextOnlyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "api.typesafe.ai")
        XCTAssertEqual(request.url?.path, "/v1/systemone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer selector-key")
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
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["model", "questions", "state"])
        let state = body["state"] as! [String: Any]
        let elements = state["elements"] as! [[String: Any]]
        XCTAssertEqual(elements[0]["source"] as? String, "ocr")
        XCTAssertEqual(elements[0]["role"] as? String, "staticText")
        XCTAssertEqual(elements[0]["label"] as? String, "Save")
        let serialized = String(decoding: data, as: UTF8.self)
        for forbidden in ["image_url", "base64", "screenshot", "data:image"] { XCTAssertFalse(serialized.contains(forbidden)) }
        let payload = #"{"answers":{"operation":{"choice":"CLICK_TEXT"},"click_text_target":{"choice":"2"}}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
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
