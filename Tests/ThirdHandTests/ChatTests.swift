import AppKit
import XCTest
@testable import ThirdHand

@MainActor
final class ChatTests: XCTestCase {
    let apps = ["Spotify", "System Settings", "Notes", "Visual Studio Code", "Visual Studio"]

    func testMentionPicksLongestAppNameAndStripsIt() {
        XCTAssertEqual(MentionParser.parse("@Spotify play Skyfall", appNames: apps).app, "Spotify")
        XCTAssertEqual(MentionParser.parse("@Spotify play Skyfall", appNames: apps).prompt, "play Skyfall")
        let multiword = MentionParser.parse("open @visual studio code  and run tests", appNames: apps)
        XCTAssertEqual(multiword.app, "Visual Studio Code")
        XCTAssertEqual(multiword.prompt, "open and run tests")
        XCTAssertEqual(MentionParser.parse("@System Settings turn on dark mode", appNames: apps).app, "System Settings")
    }

    func testMentionRequiresWordBoundaryAndKnownApp() {
        XCTAssertNil(MentionParser.parse("@Spotifyish play", appNames: apps).app)
        XCTAssertNil(MentionParser.parse("email me@notes.com", appNames: apps).app, "Not a mention inside an address")
        let none = MentionParser.parse("  play the next song ", appNames: apps)
        XCTAssertNil(none.app)
        XCTAssertEqual(none.prompt, "play the next song")
    }

    func testPartialMentionForAutocomplete() {
        XCTAssertEqual(MentionParser.partial(in: "@Spo"), "Spo")
        XCTAssertEqual(MentionParser.partial(in: "hey @"), "")
        XCTAssertEqual(MentionParser.partial(in: "@System Se"), "System Se")
        XCTAssertNil(MentionParser.partial(in: "@Spotify "), "A completed mention stops suggesting")
        XCTAssertNil(MentionParser.partial(in: "me@notes"))
        XCTAssertNil(MentionParser.partial(in: "no mention"))
    }

    func testThreadContextListsFinishedTurnsBeforeTheRequest() {
        let store = ThreadStore(url: nil)
        let id = store.newThread()
        let spotify = ChatApp(name: "Spotify", bundleID: "com.spotify.client")
        store.append(ChatMessage(role: .user, text: "@Spotify search Adele", app: spotify), to: id)
        store.append(ChatMessage(role: .task, text: "Searched for Adele.", app: spotify, state: .done), to: id)
        let followUp = ChatMessage(role: .user, text: "play the first song")
        store.append(followUp, to: id)
        let context = store.context(for: id, before: followUp.id)
        XCTAssertEqual(context, ["User in Spotify: @Spotify search Adele → done: Searched for Adele."])
        XCTAssertEqual(store.thread(id)?.lastApp, spotify, "The mentioned app becomes the thread default")
        XCTAssertEqual(store.thread(id)?.title, "@Spotify search Adele")
    }

    func testThreadsPersistAndInterruptedTasksAreMarkedStopped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/threads.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ThreadStore(url: url)
        let id = store.newThread()
        store.append(ChatMessage(role: .user, text: "@Notes new note"), to: id)
        store.append(ChatMessage(role: .task, text: "", state: .running, status: "Typing…"), to: id)
        let reloaded = ThreadStore(url: url)
        let task = try XCTUnwrap(reloaded.thread(id)?.messages.last)
        XCTAssertEqual(task.state, .stopped)
        XCTAssertNil(task.status)
        XCTAssertEqual(reloaded.selection, id)
    }

    func testAgentPromptIncludesThreadContext() async throws {
        let planner = ContextPlanner()
        _ = try await CodexAgent(planner: planner, tier: .quick)
            .run(goal: "play the first song", appName: "Spotify", context: ["User in Spotify: search Adele → done: Searched."],
                 layer: EmptyLayer())
        let opening = (((planner.firstInput.first?["content"] as? [[String: Any]])?.first)?["text"] as? String) ?? ""
        XCTAssertTrue(opening.hasPrefix("Earlier in this chat"))
        XCTAssertTrue(opening.contains("search Adele → done: Searched."))
        XCTAssertTrue(opening.contains("Task: play the first song"))
    }
}

@MainActor
final class ScreenGateTests: XCTestCase {
    func testPlanIsOfferedBeforeAnyStepRuns() async throws {
        let layer = GateLayer()
        _ = try await CodexAgent(planner: OnePlan(), tier: .quick).run(goal: "g", appName: "Spotify", layer: layer)
        XCTAssertEqual(layer.events, ["prepare:2", "perform:type", "perform:press"])
    }

    func testDecliningTheScreenSendsNoInput() async {
        let layer = GateLayer()
        layer.decline = true
        do {
            _ = try await CodexAgent(planner: OnePlan(), tier: .quick).run(goal: "g", appName: "Spotify", layer: layer)
            XCTFail("Cancelling at the take-over card stops the task")
        } catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
        XCTAssertEqual(layer.events, ["prepare:2"])
    }

    func testOldMessagesWithoutModeStillDecode() throws {
        let json = #"[{"id":"4F0E2C1E-0000-0000-0000-000000000000","title":"t","messages":[{"id":"4F0E2C1E-0000-0000-0000-000000000001","date":0,"role":"task","text":"ok","state":"done"}],"updated":0}]"#
        let threads = try JSONDecoder().decode([ChatThread].self, from: Data(json.utf8))
        XCTAssertNil(threads[0].messages[0].mode)
    }

    func testRemovedAutoModeDecodesAsOnScreen() throws {
        let decoded = try JSONDecoder().decode([ExecutionMode].self, from: Data(#"["auto","background","onScreen"]"#.utf8))
        XCTAssertEqual(decoded, [.onScreen, .background, .onScreen])
    }

    func testBackgroundKeyEvents() {
        let enter = CDPClient.keyEvent("return", modifiers: [])
        XCTAssertEqual(enter?["key"] as? String, "Enter")
        XCTAssertEqual(enter?["windowsVirtualKeyCode"] as? Int, 13)
        XCTAssertEqual(enter?["text"] as? String, "\r")
        let find = CDPClient.keyEvent("f", modifiers: ["command"])
        XCTAssertEqual(find?["code"] as? String, "KeyF")
        XCTAssertEqual(find?["modifiers"] as? Int, 4)
        XCTAssertNil(find?["text"], "Shortcuts don't insert text")
        XCTAssertEqual(CDPClient.keyEvent("a", modifiers: ["shift"])?["text"] as? String, "A")
        XCTAssertNil(CDPClient.keyEvent("f13", modifiers: []))
    }

    func testChromiumAppsSupportBackgroundDebugging() {
        let spotifyInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
        if spotifyInstalled { XCTAssertTrue(ElectronDetector.supportsDebugging(bundleID: "com.spotify.client")) }
        XCTAssertFalse(ElectronDetector.supportsDebugging(bundleID: "com.apple.calculator"))
        XCTAssertEqual(ElectronDetector.debuggingArguments(port: 9333),
                       ["--remote-debugging-port=9333", "--remote-debugging-address=127.0.0.1"], "Loopback only")
        let port = ElectronDetector.freePort()
        XCTAssertNotNil(port)
        XCTAssertGreaterThan(port ?? 0, 1024)
    }
}

@MainActor
private final class OnePlan: Planner {
    func respond(model: String, instructions: String, input: [[String: Any]], tools: [[String: Any]], effort: String) async throws -> CodexResponse {
        let steps: [[String: Any]] = [
            ["action": "type", "target": "Search", "role": "textField", "text": "adele", "key": NSNull(), "direction": NSNull()],
            ["action": "press", "target": NSNull(), "role": NSNull(), "text": NSNull(), "key": "return", "direction": NSNull()]
        ]
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["finishes_task": true, "summary": "Searched.", "steps": steps]), as: UTF8.self)
        return CodexResponse(output: [["type": "function_call", "call_id": "c", "name": "act", "arguments": args]])
    }
}

@MainActor
private final class GateLayer: ActionLayer {
    var events: [String] = []
    var decline = false
    func currentElements() async throws -> [AccessibilityElement] { [] }
    func prepare(for steps: [PlanStep]) async throws {
        events.append("prepare:\(steps.count)")
        if decline { throw CancellationError() }
    }
    func perform(step: PlanStep) async throws -> StepOutcome {
        events.append("perform:\(step.action)")
        return StepOutcome(status: "verified", detail: "", elements: [])
    }
}

@MainActor
private final class ContextPlanner: Planner {
    var firstInput: [[String: Any]] = []
    func respond(model: String, instructions: String, input: [[String: Any]], tools: [[String: Any]], effort: String) async throws -> CodexResponse {
        if firstInput.isEmpty { firstInput = input }
        return CodexResponse(output: [["type": "function_call", "call_id": "c", "name": "done", "arguments": #"{"summary":"ok"}"#]])
    }
}

@MainActor
private final class EmptyLayer: ActionLayer {
    func currentElements() async throws -> [AccessibilityElement] { [] }
    func perform(step: PlanStep) async throws -> StepOutcome { StepOutcome(status: "verified", detail: "", elements: []) }
}

@MainActor
final class GoalStepTests: XCTestCase {
    func testGoalStepsParseAndRequireAnOutcome() throws {
        let goal = try PlanStep.parse(["action": "goal", "text": "The Skyfall album page is open"]).get()
        XCTAssertEqual(goal.text, "The Skyfall album page is open")
        XCTAssertEqual(goal.summary, "goal \"The Skyfall album page is open\"")
        XCTAssertThrowsError(try PlanStep.parse(["action": "goal"]).get())
    }

    func testGoalRequestAsksDoneActionAndTargetInOneCall() throws {
        var play = AccessibilityElement(id: 1, role: "AXButton", label: "Play", value: nil, enabled: true, actions: [], axElement: nil)
        play.context = "Skyfall · Adele"
        let heading = AccessibilityElement(id: 2, role: "AXStaticText", label: "Now playing: Hello", value: nil, enabled: true, actions: [], axElement: nil)
        let prepared = try JevClient.goalRequest(goal: "Skyfall is playing", elements: [play, heading], appName: "Spotify", history: [])
        let body = try JSONSerialization.jsonObject(with: prepared.data) as! [String: Any]
        let questions = body["questions"] as! [String: [String: Any]]
        XCTAssertEqual(Set(questions.keys), ["done", "operation", "click_target"])
        XCTAssertNotNil((questions["operation"]!["criteria"] as! [String: String])["STUCK"])
        XCTAssertEqual(Set(prepared.offered.keys), ["1"], "Only clickable controls are targets")
        XCTAssertTrue(((body["state"] as! [String: Any])["screen"] as! String).contains("Now playing: Hello"), "Jev sees the screen to judge done")
    }

    func testGoalDecisionDecoding() throws {
        let target = AccessibilityElement(id: 1, role: "AXButton", label: "Play", value: nil, enabled: true, actions: [], axElement: nil)
        let click = try JevClient.decodeGoal(Data(#"{"answers":{"done":{"noul":0.1},"operation":{"choice":"CLICK"},"click_target":{"choice":"1"}}}"#.utf8), offered: ["1": target])
        XCTAssertEqual(click.operation, "CLICK")
        XCTAssertEqual(click.target?.id, 1)
        let none = try JevClient.decodeGoal(Data(#"{"answers":{"operation":{"choice":"CLICK"},"click_target":{"choice":"__none__"}}}"#.utf8), offered: ["1": target])
        XCTAssertEqual(none.operation, "STUCK", "A click with no target is stuck")
        let done = try JevClient.decodeGoal(Data(#"{"answers":{"done":{"noul":0.9},"operation":{"choice":"WAIT"}}}"#.utf8), offered: [:])
        XCTAssertGreaterThanOrEqual(done.done, JevClient.goalDoneThreshold)
        XCTAssertThrowsError(try JevClient.decodeGoal(Data("{}".utf8), offered: [:]))
    }

    func testGoalStepsCanBeTurnedOffForExperiments() {
        let enabled = CodexAgent.makeTools(actions: PlanStep.actions)
        let disabled = CodexAgent.makeTools(actions: PlanStep.actions.filter { $0 != "goal" })
        func actions(_ tools: [[String: Any]]) -> [String] {
            let act = tools.first { $0["name"] as? String == "act" }!
            let steps = ((act["parameters"] as! [String: Any])["properties"] as! [String: Any])["steps"] as! [String: Any]
            return (((steps["items"] as! [String: Any])["properties"] as! [String: Any])["action"] as! [String: Any])["enum"] as! [String]
        }
        XCTAssertTrue(actions(enabled).contains("goal"))
        XCTAssertFalse(actions(disabled).contains("goal"))
        XCTAssertTrue(CodexAgent.baseInstructions.count < (CodexAgent.baseInstructions + CodexAgent.goalGuidance).count)
    }

    func testBenchmarkSummary() {
        let rows: [[String: Any]] = [
            ["state": "done", "total_ms": 8000, "codex_calls": 1, "jev_calls": 3, "actions": 4],
            ["state": "failed", "total_ms": 20000, "codex_calls": 4, "jev_calls": 1, "actions": 6]
        ]
        let summary = Benchmark.summarize(rows, variant: "goals on")
        XCTAssertTrue(summary.hasPrefix("Benchmark (goals on): 1/2 done · median 14.0s · codex 2.5 calls"))
        XCTAssertNotNil(try? JSONEncoder().encode(Benchmark.sample))
    }
}
