import XCTest
@testable import ThirdHand

final class ArcDriverTests: XCTestCase {
    /// An observe result shaped like arc-cua's: a table row holding a title and a Play button.
    private let observed: [String: Any] = [
        "snapshot": "s3", "pid": 42, "window_id": 18342, "application": "Music", "window": "Library",
        "elements": [
            ["id": "ax_1", "role": "TextField", "name": "Search", "value": "", "actions": ["CLICK", "TYPE_TEXT", "SET_VALUE"], "focused": true],
            ["id": "ax_2", "role": "Row", "actions": ["CLICK"]],
            ["id": "ax_3", "role": "StaticText", "name": "Skyfall", "parent": "ax_2"],
            ["id": "ax_4", "role": "Button", "name": "Play", "actions": ["CLICK"], "parent": "ax_2"],
            ["id": "ax_5", "role": "Slider", "name": "Volume", "value": 0.5, "actions": ["SET_VALUE"], "enabled": false]
        ] as [[String: Any]]
    ]

    func testSnapshotMapsElements() {
        let snapshot = ArcDriver.snapshot(observed)
        XCTAssertEqual(snapshot.id, "s3")
        XCTAssertEqual(snapshot.windowID, 18342)
        XCTAssertEqual(snapshot.elements.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(snapshot.elements.map(\.driverID), ["18342/ax_1", "18342/ax_2", "18342/ax_3", "18342/ax_4", "18342/ax_5"])
        XCTAssertEqual(snapshot.elements[3].driverElementID, "ax_4")
        let search = snapshot.elements[0]
        XCTAssertEqual(search.role, "AXTextField")
        XCTAssertEqual(search.label, "Search")
        XCTAssertTrue(search.focused)
        XCTAssertNil(search.axElement)
        let volume = snapshot.elements[4]
        XCTAssertEqual(volume.value, "0.5")
        XCTAssertFalse(volume.enabled)
    }

    func testRowTextBecomesContext() {
        let elements = ArcDriver.snapshot(observed).elements
        XCTAssertEqual(elements[3].context, "Skyfall")
        XCTAssertEqual(elements[2].context, "Play")
        XCTAssertNil(elements[0].context)
    }

    func testTargetsFollowOfferedActions() {
        let targets = JevClient.targets(ArcDriver.snapshot(observed).elements)
        XCTAssertEqual(Set(targets["TYPE_TEXT"]?.keys ?? [:].keys), ["1"])
        XCTAssertEqual(Set(targets["CLICK"]?.keys ?? [:].keys), ["1", "2", "4"])
    }

    func testTypingIntoAnArcFieldValidates() throws {
        let elements = ArcDriver.snapshot(observed).elements
        try AgentDecision(operation: "TYPE_TEXT", targetIndex: "1", textValue: "Adele").validate(elements: elements, hasScreenshot: false)
        XCTAssertThrowsError(try AgentDecision(operation: "TYPE_TEXT", targetIndex: "4", textValue: "x").validate(elements: elements, hasScreenshot: false))
    }

    func testMatchingUsesArcIDs() {
        // The same button reads Pause after playing starts; arc's id still identifies it.
        let before = ArcDriver.snapshot(observed).elements
        var pause = AccessibilityElement(id: 4, role: "AXButton", label: "Pause", value: nil, enabled: true,
                                         actions: ["CLICK"], axElement: nil)
        pause.driverID = "18342/ax_4"
        XCTAssertEqual(ObservationState.matching(before[3], in: [before[2], pause])?.label, "Pause")
    }

    private func button(_ driverID: String, _ label: String) -> AccessibilityElement {
        var element = AccessibilityElement(id: 1, role: "AXButton", label: label, value: nil, enabled: true,
                                           actions: ["CLICK"], axElement: nil)
        element.driverID = driverID
        return element
    }

    func testArcIDsDontMatchAcrossWindows() {
        // Each window numbers its elements from ax_1, so the same id in another window is another element.
        let play = button("18342/ax_4", "Play")
        XCTAssertNil(ObservationState.matching(play, in: [button("20000/ax_4", "Delete"), button("20000/ax_5", "Cancel")]))
    }

    func testRebuiltElementMatchesByLabel() {
        // An app that rebuilds its tree gives the same button a new id.
        let play = button("18342/ax_4", "Play")
        XCTAssertEqual(ObservationState.matching(play, in: [button("18342/ax_40", "Play"), button("18342/ax_41", "Next")])?.driverID,
                       "18342/ax_40")
    }

    func testTerminalTextAreaTakesTyping() {
        let result: [String: Any] = ["snapshot": "s1", "window_id": 7, "elements": [
            ["id": "ax_1", "role": "TextArea", "value": "$ ", "actions": ["CLICK"]]] as [[String: Any]]]
        XCTAssertEqual(ArcDriver.snapshot(result, terminal: true).elements[0].actions, ["CLICK", "TYPE_TEXT"])
        XCTAssertEqual(ArcDriver.snapshot(result).elements[0].actions, ["CLICK"])
    }

    func testRetractedActionCanBeRetried() {
        // arc refused the input because the app changed, so nothing was sent; the retry isn't a repeat.
        var progress = RunProgress()
        let elements = ArcDriver.snapshot(observed).elements
        let click = AgentDecision(operation: "CLICK", targetIndex: "4")
        XCTAssertNil(progress.problem(decision: click, elements: elements))
        XCTAssertNotNil(progress.problem(decision: click, elements: elements))
        var retracted = RunProgress()
        XCTAssertNil(retracted.problem(decision: click, elements: elements))
        retracted.retract()
        XCTAssertNil(retracted.problem(decision: click, elements: elements))
    }

    func testChords() {
        XCTAssertEqual(ArcDriver.chord(key: "return", modifiers: []), "ENTER")
        XCTAssertEqual(ArcDriver.chord(key: "f", modifiers: ["command"]), "MOD+F")
        XCTAssertEqual(ArcDriver.chord(key: "z", modifiers: ["shift", "command"]), "MOD+SHIFT+Z")
        XCTAssertEqual(ArcDriver.chord(key: "a", modifiers: ["control"]), "CTRL+A")
        XCTAssertEqual(ArcDriver.chord(key: "down", modifiers: ["option"]), "ALT+ARROW_DOWN")
        XCTAssertEqual(ArcDriver.chord(key: "delete", modifiers: []), "BACKSPACE")
        XCTAssertEqual(ArcDriver.chord(key: "f12", modifiers: []), "F12")
        XCTAssertNil(ArcDriver.chord(key: "f", modifiers: ["hyper"]))
        XCTAssertNil(ArcDriver.chord(key: "pageup", modifiers: []))
    }
}
