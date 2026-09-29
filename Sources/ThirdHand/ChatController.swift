import AppKit

/// Turns chat messages into tasks. Tasks run one at a time: foreground tasks need the screen.
@MainActor
final class ChatController: ObservableObject, TaskRunnerDelegate {
    let store: ThreadStore
    let catalog: AppCatalog
    /// Per-thread composer drafts, so Control–Space can prefill "@App ".
    @Published var drafts: [UUID: String] = [:]
    /// Bumped to move keyboard focus to the composer.
    @Published var focusRequest = 0

    /// Supplies credentials at send time; nil means setup isn't finished.
    var credentials: () -> (apiKey: String, codex: CodexCredentials)? = { nil }
    /// Called when a task ends, to bring the chat back in front.
    var onTaskFinished: () -> Void = {}
    var onSetupNeeded: () -> Void = {}

    private struct Job {
        let threadID: UUID
        let requestID: UUID
        let messageID: UUID
        let app: ChatApp
        let prompt: String
    }

    private var queue: [Job] = []
    private var current: (job: Job, runner: TaskRunner?, task: Task<Void, Never>?, started: Date)?

    init(store: ThreadStore, catalog: AppCatalog) {
        self.store = store
        self.catalog = catalog
    }

    convenience init() { self.init(store: ThreadStore(), catalog: AppCatalog()) }

    // MARK: - Threads

    func newThread(app: ChatApp? = nil) {
        let id = store.newThread(app: app)
        drafts[id] = app.map { "@\($0.name) " } ?? ""
        focusRequest += 1
    }

    // MARK: - Sending

    func send(in threadID: UUID) {
        let draft = (drafts[threadID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        let parsed = MentionParser.parse(draft, appNames: catalog.all.map(\.name))
        let mentioned = parsed.app.flatMap { name in catalog.all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.chatApp }
        let app = mentioned ?? store.thread(threadID)?.lastApp
        drafts[threadID] = ""

        let request = ChatMessage(role: .user, text: draft, app: mentioned)
        store.append(request, to: threadID)
        guard let app else {
            store.append(ChatMessage(role: .task, text: "Mention an app with @ so I know where to do this.", state: .failed), to: threadID)
            return
        }
        guard !parsed.prompt.isEmpty else {
            store.append(ChatMessage(role: .task, text: "Tell me what to do in \(app.name).", app: app, state: .failed), to: threadID)
            return
        }
        let message = ChatMessage(role: .task, text: "", app: app, state: .queued, status: "Waiting for the current task…")
        store.append(message, to: threadID)
        queue.append(Job(threadID: threadID, requestID: request.id, messageID: message.id, app: app, prompt: parsed.prompt))
        startNext()
    }

    func stop(messageID: UUID, in threadID: UUID) {
        if let index = queue.firstIndex(where: { $0.messageID == messageID }) {
            queue.remove(at: index)
            finish(threadID: threadID, messageID: messageID, state: .stopped, text: "Stopped before it started.", seconds: nil)
            return
        }
        guard let current, current.job.messageID == messageID else { return }
        if let runner = current.runner { runner.cancel() }
        else {
            current.task?.cancel()
            end(state: .stopped, text: "Stopped.")
        }
    }

    var isBusy: Bool { current != nil }

    // MARK: - Running

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        guard let credentials = credentials() else {
            finish(threadID: job.threadID, messageID: job.messageID, state: .failed,
                   text: "Finish setup first: Accessibility, the Jev API key, and ChatGPT sign-in.", seconds: nil)
            onSetupNeeded()
            startNext()
            return
        }
        let context = store.context(for: job.threadID, before: job.requestID)
        current = (job, nil, nil, Date())
        let running = catalog.isRunning(job.app.bundleID)
        setStatus(running ? "Switching to \(job.app.name)…" : "Opening \(job.app.name)…")
        current?.task = Task { [weak self] in
            do {
                let app = try await AppCatalog.prepare(job.app)
                guard let self, self.current?.job.messageID == job.messageID else { return }
                guard let target = AppTarget.make(from: app) else {
                    throw ControllerError.invalid("\(job.app.name) can't be controlled.")
                }
                let runner = TaskRunner(target: target, goal: job.prompt, apiKey: credentials.apiKey,
                                        credentials: credentials.codex, context: context)
                runner.delegate = self
                self.current?.runner = runner
                runner.start()
            } catch is CancellationError {
            } catch {
                guard let self, self.current?.job.messageID == job.messageID else { return }
                self.end(state: .failed, text: error.localizedDescription)
            }
        }
    }

    private func setStatus(_ status: String) {
        guard let job = current?.job else { return }
        store.updateMessage(job.messageID, in: job.threadID) { message in
            message.state = .running
            message.status = status
        }
    }

    private func end(state: TaskState, text: String) {
        guard let current else { return }
        self.current = nil
        finish(threadID: current.job.threadID, messageID: current.job.messageID, state: state, text: text,
               seconds: Date().timeIntervalSince(current.started))
        onTaskFinished()
        startNext()
    }

    private func finish(threadID: UUID, messageID: UUID, state: TaskState, text: String, seconds: Double?) {
        store.updateMessage(messageID, in: threadID) { message in
            message.state = state
            message.status = nil
            message.text = text
            message.seconds = seconds
        }
    }

    // MARK: - TaskRunnerDelegate

    func taskRunner(_ r: TaskRunner, status: String) {
        guard current?.runner === r else { return }
        setStatus(status)
    }

    func taskRunnerDone(_ r: TaskRunner, summary: String) {
        guard current?.runner === r else { return }
        end(state: .done, text: summary)
    }

    func taskRunnerFailed(_ r: TaskRunner, error: String) {
        guard current?.runner === r else { return }
        end(state: .failed, text: error)
    }

    func taskRunnerCancelled(_ r: TaskRunner) {
        guard current?.runner === r else { return }
        end(state: .stopped, text: "Stopped.")
    }
}
