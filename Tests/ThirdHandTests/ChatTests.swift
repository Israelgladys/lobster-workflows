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
