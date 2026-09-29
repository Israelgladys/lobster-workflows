import AppKit

/// Runs a list of tasks one after another in a new thread and records timing and call counts,
/// so planner and Jev changes can be compared. Tasks come from benchmark.json in Application Support.
@MainActor
final class Benchmark {
    struct Spec: Codable {
        struct Item: Codable {
            let app: String
            let prompt: String
            var mode: ExecutionMode? = .background
        }
        var tasks: [Item]
        var repeats: Int? = 1
    }

    static var specURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Third Hand/benchmark.json")
    }
    static let resultsURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/thirdhand-bench.jsonl")

    static let sample = Spec(tasks: [
        .init(app: "Spotify", prompt: "search for Daft Punk"),
        .init(app: "Spotify", prompt: "play Skyfall by Adele"),
        .init(app: "Spotify", prompt: "open the album Random Access Memories and play the first track"),
        .init(app: "Spotify", prompt: "go to my Liked Songs and play the most recent one")
    ])

    private let chat: ChatController
    private(set) var isRunning = false

    init(chat: ChatController) { self.chat = chat }

    /// Loads the task list, writing a sample to edit if there isn't one yet.
    func loadSpec() throws -> Spec {
        guard let url = Self.specURL else { throw ControllerError.invalid("No Application Support folder.") }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Self.sample).write(to: url)
        }
        return try JSONDecoder().decode(Spec.self, from: Data(contentsOf: url))
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let variant = CodexAgent.goalStepsEnabled ? "goals on" : "goals off"
        let spec: Spec
        do { spec = try loadSpec() } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't read benchmark.json"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        chat.newThread()
        guard let threadID = chat.store.selection else { return }
        let runID = UUID().uuidString.prefix(8)
        var rows: [[String: Any]] = []
        for round in 1...max(1, spec.repeats ?? 1) {
            for item in spec.tasks {
                chat.drafts[threadID] = "@\(item.app) \(item.prompt)"
                let before = Set(chat.store.thread(threadID)?.messages.map(\.id) ?? [])
                chat.send(in: threadID, mode: item.mode ?? .background)
                guard let messageID = chat.store.thread(threadID)?.messages.last(where: { !before.contains($0.id) && $0.role == .task })?.id else { continue }
                let deadline = Date().addingTimeInterval(400)
                var message = chat.store.thread(threadID)?.messages.first { $0.id == messageID }
                while let state = message?.state, [.queued, .running, .waiting].contains(state), Date() < deadline {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    message = chat.store.thread(threadID)?.messages.first { $0.id == messageID }
                }
                var row: [String: Any] = ["run": String(runID), "variant": variant, "round": round, "app": item.app,
                                          "prompt": item.prompt, "mode": (item.mode ?? .background).rawValue,
                                          "state": message?.state?.rawValue ?? "unknown", "summary": message?.text ?? "",
                                          "date": ISO8601DateFormatter().string(from: Date())]
                for (key, value) in message?.metrics ?? [:] { row[key] = value }
                rows.append(row)
                Self.append(row)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        chat.store.append(ChatMessage(role: .task, text: Self.summarize(rows, variant: variant), state: .done), to: threadID)
        Log.info("Benchmark finished run=\(runID) tasks=\(rows.count)")
    }

    static func append(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        let line = data + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: resultsURL) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: resultsURL)
        }
    }

    static func summarize(_ rows: [[String: Any]], variant: String) -> String {
        let done = rows.filter { $0["state"] as? String == "done" }
        func values(_ key: String) -> [Double] { rows.compactMap { ($0[key] as? Int).map(Double.init) } }
        func median(_ xs: [Double]) -> Double {
            let sorted = xs.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        return String(format: "Benchmark (%@): %d/%d done · median %.1fs · codex %.1f calls · jev %.1f calls · %.1f actions. Results in ~/Desktop/thirdhand-bench.jsonl",
                      variant, done.count, rows.count, median(values("total_ms")) / 1000,
                      mean(values("codex_calls")), mean(values("jev_calls")), mean(values("actions")))
    }
}
