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
        XCTAssertEqual(snapshot.elements.map(\.driverID), ["ax_1", "ax_2", "ax_3", "ax_4", "ax_5"])
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
        pause.driverID = "ax_4"
        XCTAssertEqual(ObservationState.matching(before[3], in: [before[2], pause])?.label, "Pause")
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
