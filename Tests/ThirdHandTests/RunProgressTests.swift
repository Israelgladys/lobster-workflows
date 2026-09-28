import XCTest
@testable import ThirdHand

final class RunProgressTests: XCTestCase {
    private func control(id: Int = 1, label: String = "Search", value: String = "", focused: Bool = false) -> AccessibilityElement {
        AccessibilityElement(id: id, role: "AXTextField", label: label, value: value, enabled: true, actions: [], axElement: nil, frame: CGRect(x: 10, y: 20, width: 100, height: 20), focused: focused)
    }

    func testSignatureIgnoresSnapshotIDsAndOrder() {
        XCTAssertEqual(ObservationState.signature([control(id: 1), control(id: 2, label: "Name")]),
                       ObservationState.signature([control(id: 99, label: "Name"), control(id: 88)]))
    }

    func testTextVerificationRequiresExactValueInCorrectField() {
        let action = AgentDecision(operation: "TYPE_TEXT", targetIndex: "1", textValue: "Boards of Canada")
        let before = [control(), control(id: 2, label: "Other")]
        XCTAssertFalse(ObservationState.verify(action, before: before, after: [control(value: "Boards"), control(id: 2, label: "Other", value: "Boards of Canada")]).verified)
        XCTAssertTrue(ObservationState.verify(action, before: before, after: [control(id: 90, value: "Boards of Canada")]).verified)
    }

    func testAmbiguousFieldsAreNotVerifiedByLabelAlone() {
        let field = AccessibilityElement(id: 1, role: "AXTextField", label: "Name", value: "", enabled: true, actions: [], axElement: nil)
        XCTAssertNil(ObservationState.matching(field, in: [field, field]))
    }

    func testFocusAndNoEffectAreDistinguished() {
        let action = AgentDecision(operation: "CLICK", targetIndex: "1")
        XCTAssertFalse(ObservationState.verify(action, before: [control()], after: [control(id: 8)]).verified)
        XCTAssertTrue(ObservationState.verify(action, before: [control()], after: [control(focused: true)]).verified)
    }

    func testAlternatingActionsAreDetectedDespiteRenumbering() {
        var progress = RunProgress()
        for step in 0..<2 {
            let value = step % 2 == 0 ? "A" : "B"
            let id = step + 1
            XCTAssertNil(progress.problem(decision: AgentDecision(operation: "TYPE_TEXT", targetIndex: String(id), textValue: value), elements: [control(id: id, value: value)]))
        }
        XCTAssertNotNil(progress.problem(decision: AgentDecision(operation: "TYPE_TEXT", targetIndex: "99", textValue: "A"), elements: [control(id: 99, value: "A")]))
    }

    func testFirstRepeatIsBlockedBeforeExecutionAndSurvivesRecovery() {
        var progress = RunProgress()
        let click = AgentDecision(operation: "CLICK", targetIndex: "1")
        XCTAssertNil(progress.problem(decision: click, elements: [control()]))
        progress.record(ActionVerification(verified: true, detail: "focus changed"))
        XCTAssertNotNil(progress.problem(decision: click, elements: [control()]))
        XCTAssertTrue(progress.beginRecovery())
        let ocr = AccessibilityElement(id: 2, role: "AXStaticText", label: "OCR text", value: nil,
            enabled: true, actions: [], axElement: nil, source: "ocr")
        XCTAssertNotNil(progress.problem(decision: click, elements: [control(), ocr]))
        XCTAssertNil(progress.problem(decision: AgentDecision(operation: "KEY_PRESS", key: "tab"), elements: [control()]))
    }

    func testClockChangesCannotAuthorizeTheSameClickAgain() {
        var progress = RunProgress()
        let click = AgentDecision(operation: "CLICK", targetIndex: "1")
        func screen(_ time: String) -> [AccessibilityElement] {
            [control(), AccessibilityElement(id: 2, role: "AXStaticText", label: time, value: nil,
                enabled: true, actions: [], axElement: nil)]
        }
        XCTAssertNil(progress.problem(decision: click, elements: screen("0:01")))
        progress.record(ActionVerification(verified: true, detail: "clock changed"))
        XCTAssertNotNil(progress.problem(decision: click, elements: screen("0:02")))
    }

    func testChangedFieldAllowsNewActionState() {
        var progress = RunProgress()
        let click = AgentDecision(operation: "CLICK", targetIndex: "1")
        XCTAssertNil(progress.problem(decision: click, elements: [control(value: "old")]))
        progress.record(ActionVerification(verified: false, detail: "no effect"))
        XCTAssertNil(progress.problem(decision: click, elements: [control(value: "new")]))
    }

    func testChangingClockCannotHideRepeatedFailedActions() {
        var progress = RunProgress()
        progress.record(ActionVerification(verified: false, detail: "no effect"))
        progress.record(ActionVerification(verified: false, detail: "no effect"))
        XCTAssertNotNil(progress.problem(decision: AgentDecision(operation: "WAIT"), elements: [control(value: "new unrelated clock value")]))
        XCTAssertTrue(progress.beginRecovery())
        XCTAssertFalse(progress.beginRecovery())
    }

    func testLegitimateScrollingWithChangingContentIsAllowed() {
        var progress = RunProgress()
        for step in 0..<10 {
            XCTAssertNil(progress.problem(decision: AgentDecision(operation: "SCROLL_DOWN"), elements: [control(), AccessibilityElement(id: 2, role: "AXStaticText", label: "row \(step)", value: nil, enabled: true, actions: [], axElement: nil)]))
        }
    }

    func testDebugPortRequiresExplicitValidFlag() {
        XCTAssertNil(ElectronDetector.debugPort(in: "Electron"))
        XCTAssertNil(ElectronDetector.debugPort(in: "Electron --remote-debugging-port=0"))
        XCTAssertNil(ElectronDetector.debugPort(in: "Electron --remote-debugging-port=9222oops"))
        XCTAssertNil(ElectronDetector.debugPort(in: "Electron --remote-debugging-port=99999"))
        XCTAssertEqual(ElectronDetector.debugPort(in: "Electron --remote-debugging-port=9345"), 9345)
    }
}

@MainActor
final class TimeoutTests: XCTestCase {
    func testDeadlineReturnsEvenWhenWorkIgnoresCancellation() async throws {
        var continuation: CheckedContinuation<Int, Never>?
        var timedOut = false
        let start = ContinuousClock.now
        do {
            _ = try await AsyncTimeout.run(seconds: 0.03, message: "fixture timeout", onTimeout: { timedOut = true }) {
                await withCheckedContinuation { continuation = $0 }
            }
            XCTFail("Should time out")
        } catch { XCTAssertEqual(error.localizedDescription, "fixture timeout") }
        XCTAssertTrue(timedOut)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        // A late response must not resume the caller a second time.
        continuation?.resume(returning: 1)
        await Task.yield()
    }

    func testCancellationReturnsWithoutLateSuccess() async throws {
        var continuation: CheckedContinuation<Int, Never>?
        let task = Task {
            try await AsyncTimeout.run(seconds: 10, message: "timeout") {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        continuation?.resume(returning: 1)
        await Task.yield()
    }

    func testSuccessCancelsDeadline() async throws {
        var timedOut = false
        let value = try await AsyncTimeout.run(seconds: 0.02, message: "timeout", onTimeout: { timedOut = true }) { 42 }
        XCTAssertEqual(value, 42)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(timedOut)
    }
}
