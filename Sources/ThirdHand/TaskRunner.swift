import AppKit
import ApplicationServices

@MainActor
protocol TaskRunnerDelegate: AnyObject {
    func taskRunner(_ r: TaskRunner, status: String)
    func taskRunnerDone(_ r: TaskRunner, summary: String)
    func taskRunnerFailed(_ r: TaskRunner, error: String)
    func taskRunnerCancelled(_ r: TaskRunner)
}

@MainActor
final class TaskRunner: ActionLayer {
    let target: AppTarget
    let goal: String
    let apiKey: String
    let credentials: CodexCredentials
    /// Earlier turns in the chat thread, for follow-ups.
    let context: [String]
    /// Drive the app without bringing it forward: through its debugging connection when it has one,
    /// otherwise with input addressed to its window.
    let background: Bool
    /// Returns once the task may take over the screen for these steps; throws to stop.
    var requestScreen: ([PlanStep]) async throws -> Void = { _ in }
    weak var delegate: TaskRunnerDelegate?
    private var task: Task<Void, Never>?
    private var history: [ActionHistory] = []
    private let maxSteps = 30
    private var cdpClient: CDPClient?
    private var active = false
    private var useOCR = false
    private var progress = RunProgress()
    private var phase = "starting"
    private var terminalInputPending = false
    /// Planning reads the app in the background; the app must stay in front once input starts.
    private var inForeground = false
    /// Time spent waiting to use the screen doesn't count toward the task limit.
    private var waitingForScreen = false
    private var timedOut = false
    nonisolated static let activeTimeLimit: TimeInterval = 300
    private var actions = 0
    /// The user's front app and the time of the last input addressed to the target's window.
    private var userApp: NSRunningApplication?
    private var lastWindowInput = Date.distantPast
    private lazy var jev = JevClient(apiKey: apiKey)

    init(target: AppTarget, goal: String, apiKey: String, credentials: CodexCredentials, context: [String] = [],
         background: Bool = false) {
        self.target = target
        self.goal = goal
        self.apiKey = apiKey
        self.credentials = credentials
        self.context = context
        self.background = background
    }

    func start() {
        guard task == nil else { return }
        RunMetrics.current = RunMetrics()
        active = true
        task = Task { await run() }
    }
    func cancel() {
        active = false
        task?.cancel()
        Log.info("Task cancelled phase=\(phase)")
        cdpClient?.disconnect()
        delegate?.taskRunnerCancelled(self)
    }

    private func checkFocus() throws {
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
        guard !target.application.isTerminated,
              !inForeground || NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            Log.info("Task focus lost phase=\(phase)")
            throw ControllerError.invalid("Stopped because the active app changed. Return to \(target.name) and try again.")
        }
    }

    private func run() async {
        defer {
            active = false; cdpClient?.disconnect(); cdpClient = nil
            Log.info("Metrics " + RunMetrics.current.logLine)
        }
        let watchdog = Task { [weak self] in
            var elapsed: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.active else { return }
                if !self.waitingForScreen { elapsed += 1 }
                if elapsed >= Self.activeTimeLimit {
                    Log.info("Task active time limit reached phase=\(self.phase)")
                    self.timedOut = true
                    self.active = false
                    self.cdpClient?.disconnect()
                    self.task?.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        do {
            try await runAgent()
        } catch is CancellationError {
            if timedOut { delegate?.taskRunnerFailed(self, error: "Stopped after five minutes of work. The task has not been verified complete.") }
        } catch {
            if timedOut {
                delegate?.taskRunnerFailed(self, error: "Stopped after five minutes of work. The task has not been verified complete.")
                return
            }
            guard !Task.isCancelled else { return }
            let diagnostic = error as NSError
            Log.info("Task failed phase=\(phase) error_type=\(String(reflecting: type(of: error))) error_code=\(diagnostic.code)")
            delegate?.taskRunnerFailed(self, error: error.localizedDescription)
        }
    }

    private func runAgent() async throws {
        guard AXIsProcessTrusted() else { throw ControllerError.invalid("Enable Accessibility for Third Hand in System Settings.") }
        try checkFocus()
        let debugPort = background ? await ElectronDetector.findDebugPort(pid: target.pid) : nil
        if background, debugPort == nil {
            try BackgroundInput.ensureAvailable()
            // A window that just opened may still be moving into place.
            for _ in 0..<20 where WindowSnapshot.frontWindow(pid: target.pid) == nil {
                try checkFocus()
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            Log.info("Background control via=window_input")
            watchForActivation()
        } else if background, let port = debugPort {
            // Right after a relaunch the page is still loading and the window may still be settling.
            var lastError: Error?
            for attempt in 1...20 {
                try checkFocus()
                // The window may be hidden or minimized; the page is still reachable.
                let cdp = CDPClient(port: port)
                do {
                    try await cdp.connect(windowFrame: nil, requireFocus: false)
                    cdpClient = cdp
                    Log.info("Background connection ready attempt=\(attempt)")
                    break
                } catch {
                    cdp.disconnect()
                    lastError = error
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard cdpClient != nil else {
                throw ControllerError.invalid("Couldn't connect to \(target.name) in the background: \(lastError?.localizedDescription ?? "no window")")
            }
        } else if ElectronDetector.isElectron(target), let window = WindowSnapshot.frontWindow(pid: target.pid),
           let port = await ElectronDetector.findDebugPort(pid: target.pid) {
            try checkFocus()
            let cdp = CDPClient(port: port)
            do { try await cdp.connect(windowFrame: window.frame); cdpClient = cdp }
            catch { cdp.disconnect(); Log.info("Existing browser connection unavailable; using accessibility") }
        }
        try checkFocus()
        AXUIElementSetAttributeValue(target.appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target.appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var context = context
        // Ultrafast works from the DOM for Chromium apps with a debugging connection and from the
        // accessibility tree everywhere else, on screen or in the background.
        if Self.ultrafastEnabled {
            phase = "fast"
            let fast = try await runFastLoop(task: goal)
            if fast.status == "verified" {
                Log.info("Task completed fast_path=1 actions=\(actions)")
                RunMetrics.current.fastPath()
                delegate?.taskRunnerDone(self, summary: "Done: \(goal)")
                return
            }
            Log.info("Fast path handed off actions=\(actions)")
            context.append("A quick attempt didn't finish. \(fast.detail)")
        }
        phase = "planning"
        // Plan quickly and escalate effort only after a failed plan; manual settings pin the tier.
        let override = (CodexClient.modelOverride, CodexClient.effortOverride)
        let tier = PlannerTier(model: override.0 ?? PlannerTier.quick.model, effort: override.1 ?? PlannerTier.quick.effort)
        Log.info("Planner tier model=\(tier.model) effort=\(tier.effort)")
        let agent = CodexAgent(planner: CodexClient(credentials: credentials), tier: tier,
                               escalation: override.0 == nil && override.1 == nil ? .strong : nil)
        let outcome = try await agent.run(goal: goal, appName: target.name, context: context, layer: self) { [weak self] status in
            guard let self else { return }
            self.delegate?.taskRunner(self, status: status)
        }
        try checkFocus()
        switch outcome {
        case .done(let summary):
            Log.info("Task completed actions=\(actions) summary_chars=\(summary.count)")
            delegate?.taskRunnerDone(self, summary: summary)
        case .failed(let reason):
            Log.info("Task stopped by planner actions=\(actions)")
            delegate?.taskRunnerFailed(self, error: reason)
        }
    }

    // MARK: - Action layer

    func currentElements() async throws -> [AccessibilityElement] {
        var observation = try await observe()
        if !useOCR && JevClient.targets(observation.elements).isEmpty, enableOCR("No usable controls were exposed by the app.") {
            observation = try await observe()
        }
        return observation.elements
    }

    /// Candidates compatible with a step's action, in snapshot order.
    private func pool(for action: String, in elements: [AccessibilityElement]) -> [AccessibilityElement] {
        let targets = JevClient.targets(elements)
        let ids = action == "type"
            ? Set((targets["TYPE_TEXT"] ?? [:]).keys)
            : Set((targets["CLICK"] ?? [:]).keys).union((targets["CLICK_TEXT"] ?? [:]).keys)
        return elements.filter { ids.contains(String($0.id)) }
    }

    /// `defaults write com.thirdhand.app Ultrafast -bool YES`: Jev drives background tasks directly (experiment).
    nonisolated static var ultrafastEnabled: Bool { UserDefaults.standard.bool(forKey: "Ultrafast") }
    nonisolated static let maxFastActions = 15
    /// `defaults write com.thirdhand.app DebugGrounding -bool YES` logs target and candidate labels locally.
    nonisolated static var debugGrounding: Bool { UserDefaults.standard.bool(forKey: "DebugGrounding") }
    /// Short settles for the ultrafast loop: it re-reads the page every cycle and Jev can choose to wait.
    private var fastSettle = false
    private var fieldText: [String: String] = [:]

    /// Ultrafast: Jev reads the page and picks the next operation and target in one request per cycle,
    /// and a prompt-only planner call writes text when Jev chooses to type. Returns verified when Jev
    /// judges the task done; anything else hands the task to the planner.
    /// The field text is most likely needed for: the focused field, else a search box, else the only field.
    nonisolated static func likelyField(in elements: [AccessibilityElement]) -> AccessibilityElement? {
        let fields = elements.filter { ["AXTextField", "AXTextArea", "AXComboBox"].contains($0.role) && $0.enabled }
        if let focused = fields.first(where: \.focused) { return focused }
        let searchy = ["search", "play", "find", "query", "look"]
        if let search = fields.first(where: { field in searchy.contains { field.displayLabel.lowercased().contains($0) } }) { return search }
        return fields.count == 1 ? fields[0] : nil
    }

    private func runFastLoop(task: String) async throws -> StepOutcome {
        fastSettle = true
        defer { fastSettle = false }
        var taken: [String] = []
        var latest: [AccessibilityElement] = []
        var retriedBlocked = false
        var lastAction: (identity: String, succeeded: Bool)?
        var lastOperation: String?
        var filledFields: Set<String> = []
        let writer = CodexClient(credentials: credentials)
        // Text for the most likely field is written while Jev makes its first decision.
        var prefetch: (key: String, task: Task<String, Error>)?
        defer { prefetch?.task.cancel() }
        for iteration in 0..<Self.maxFastActions + 1 {
            try checkFocus()
            delegate?.taskRunner(self, status: "Working… (\(actions))")
            phase = "fast_observing"
            let observation = try await observe()
            latest = observation.elements
            if prefetch == nil, iteration == 0, let field = Self.likelyField(in: observation.elements) {
                let screen = CodexAgent.describe(observation.elements)
                let name = target.name
                prefetch = (JevClient.fieldKey(field), Task { try await writer.writeText(task: task, field: field, appName: name, screen: screen) })
            }
            phase = "fast_deciding"
            let decision = try await jev.nextAction(task: task, elements: observation.elements, appName: target.name,
                                                    history: taken, lastOperation: lastOperation, filledFields: filledFields)
            Log.info("Fast iteration=\(iteration) operation=\(decision.operation) done=\(String(format: "%.2f", decision.done))")
            if Self.debugGrounding, let chosen = decision.target {
                Log.info("Debug fast target=\(chosen.displayRole):\(chosen.displayLabel.prefix(40))\(chosen.context.map { " in " + $0.prefix(30) } ?? "")")
            }
            if decision.done >= JevClient.doneThreshold || (decision.operation == "DONE" && decision.done >= 0.5) {
                return StepOutcome(status: "verified", detail: taken.joined(separator: ", "), elements: latest)
            }
            if decision.operation == "BLOCKED" || decision.operation == "DONE" {
                // The previous action may have just started loading what's needed: settle and look once more.
                guard !retriedBlocked else { break }
                retriedBlocked = true
                if let cdp = cdpClient { _ = try? await cdp.waitForQuiet(firstChangeMs: 600, quietMs: 150, maxMs: 1500) }
                continue
            }
            guard iteration < Self.maxFastActions else { break }
            var step: PlanStep
            switch decision.operation {
            case "CLICK": step = PlanStep(action: "click", target: decision.target?.displayLabel)
            case "TYPE_TEXT":
                guard let field = decision.target else { continue }
                let key = JevClient.fieldKey(field)
                let text: String
                if let cached = fieldText[key] { text = cached }
                else if let prefetch, prefetch.key == key, let written = try? await prefetch.task.value {
                    text = written
                    Log.info("Text prefetch hit")
                } else {
                    delegate?.taskRunner(self, status: "Writing text…")
                    text = try await writer.writeText(task: task, field: field, appName: target.name,
                                                      screen: CodexAgent.describe(observation.elements))
                }
                fieldText[key] = text
                filledFields.insert(key)
                step = PlanStep(action: "type", target: field.displayLabel, text: text)
            case "SCROLL_DOWN": step = PlanStep(action: "scroll", direction: "down")
            case "SCROLL_UP": step = PlanStep(action: "scroll", direction: "up")
            case "PRESS_RETURN": step = PlanStep(action: "press", key: "return")
            case "PRESS_ESCAPE": step = PlanStep(action: "press", key: "escape")
            default: step = PlanStep(action: "wait")
            }
            let identity = decision.operation + "|" + (decision.target.map { "\($0.role)|\($0.displayLabel)|\($0.context ?? "")" } ?? "")
            if let lastAction, lastAction.identity == identity, !lastAction.succeeded, decision.operation != "WAIT" { break }
            let outcome = try await perform(step: step, pinned: decision.target)
            let changed = outcome.status == "verified" || outcome.status == "sent"
            lastAction = (identity, changed)
            lastOperation = decision.operation
            let what = decision.operation == "CLICK" ? "click \"\(decision.target?.displayLabel.prefix(60) ?? "")\"" : step.summary
            taken.append(what + (changed ? " → screen changed" : " → no visible change (\(outcome.status))"))
            latest = outcome.elements
            if ["blocked", "rejected"].contains(outcome.status) { break }
        }
        return StepOutcome(status: "blocked", detail: taken.isEmpty ? "No progress." : "Tried: " + taken.joined(separator: ", "), elements: latest)
    }

    /// One planner step. The action is fixed by the planner; a click or type target is resolved by exact label
    /// when unique, otherwise Jev chooses among controls compatible with that action only. `pinned` is a
    /// control a goal step already chose, used instead of grounding by label.
    func perform(step: PlanStep) async throws -> StepOutcome {
        try await perform(step: step, pinned: nil)
    }

    private func perform(step: PlanStep, pinned: AccessibilityElement?) async throws -> StepOutcome {
        guard actions < maxSteps else {
            throw ControllerError.invalid("Stopped after \(maxSteps) actions. The final screen does not confirm completion.")
        }
        if !background { try await bringToFront() }
        var latest: [AccessibilityElement] = []
        // A planned target may not be on screen yet (results loading, a menu opening): keep looking while
        // the screen is still changing, up to a few seconds, before asking Jev or the planner.
        let appearDeadline = Date().addingTimeInterval(3)
        var previousSignature: String?
        // Separate observation budget bounds waiting, stale-window retries, and recovery within a step.
        for _ in 0..<14 {
            try checkFocus()
            delegate?.taskRunner(self, status: "Finding the control… (\(actions)/\(maxSteps))")
            phase = "observing"
            var observation = try await observe()
            if !useOCR && JevClient.targets(observation.elements).isEmpty, enableOCR("No usable controls were exposed by the app.") {
                observation = try await observe()
            }
            latest = observation.elements
            try checkFocus()
            var decision: AgentDecision
            switch step.action {
            case "press":
                decision = AgentDecision(operation: "KEY_PRESS", key: step.key, modifiers: step.modifiers.isEmpty ? nil : step.modifiers)
            case "wait":
                decision = AgentDecision(operation: "WAIT")
            case "scroll":
                let anchor = step.target.flatMap { StepMatcher.exact(target: $0, role: step.role, near: step.near, in: observation.elements).first }
                decision = AgentDecision(operation: step.direction == "up" ? "SCROLL_UP" : "SCROLL_DOWN", targetIndex: anchor.map { String($0.id) })
            default:
                let label = step.target ?? ""
                let candidates = pool(for: step.action, in: observation.elements)
                if let pinned {
                    // Jev already chose this control on the previous read of the screen.
                    guard let current = ObservationState.matching(pinned, in: candidates) else {
                        return StepOutcome(status: "blocked", detail: "The chosen control is no longer on screen.", elements: latest)
                    }
                    decision = step.action == "type"
                        ? AgentDecision(operation: "TYPE_TEXT", targetIndex: String(current.id), textValue: step.text)
                        : AgentDecision(operation: current.source == "ocr" ? "CLICK_TEXT" : "CLICK", targetIndex: String(current.id))
                } else {
                    let matches = StepMatcher.exact(target: label, role: step.role, near: step.near, in: candidates)
                    let signature = ObservationState.signature(observation.elements)
                    defer { previousSignature = signature }
                    if matches.isEmpty, Date() < appearDeadline, signature != previousSignature {
                        phase = "awaiting_target"
                        try await Task.sleep(nanoseconds: 350_000_000)
                        continue
                    }
                    if step.near != nil {
                        let unnarrowed = StepMatcher.exact(target: label, role: step.role, in: candidates).count
                        Log.info("Grounding near=provided matches_before=\(unnarrowed) matches_after=\(matches.count)")
                    }
                    var chosen: AccessibilityElement?
                    // Planned targets for screens that didn't exist yet are the text the planner expected to see;
                    // the real control often wraps it ("Play Skyfall by Adele", or a row). Match by containment first.
                    let containing = matches.isEmpty ? StepMatcher.containing(target: label, near: step.near, in: candidates) : []
                    if matches.count == 1 {
                        chosen = matches[0]
                        Log.info("Grounded via=exact action=\(step.action)")
                    } else if containing.count == 1 {
                        chosen = containing[0]
                        Log.info("Grounded via=contains action=\(step.action)")
                    } else if !candidates.isEmpty {
                        phase = "grounding"
                        do {
                            chosen = try await jev.ground(action: step.action, target: label, role: step.role, near: step.near,
                                                          candidates: matches.count > 1 ? matches : containing.count > 1 ? containing : candidates,
                                                          allExact: matches.count > 1, appName: target.name)
                        } catch is CancellationError { throw CancellationError() }
                        catch let error as JevServiceError { throw error }
                        catch {
                            try checkFocus()
                            return StepOutcome(status: "blocked", detail: "The action selector failed: \(error.localizedDescription)", elements: latest)
                        }
                        Log.info("Grounded via=jev action=\(step.action) duplicates=\(matches.count) containing=\(containing.count) found=\(chosen != nil)")
                        if Self.debugGrounding {
                            let shown = (matches.count > 1 ? matches : containing.count > 1 ? containing : candidates).prefix(6)
                                .map { "\($0.displayRole):\($0.displayLabel.prefix(40))\($0.context.map { " in " + $0.prefix(30) } ?? "")" }
                            Log.info("Debug ground target=\(label.prefix(60)) near=\(step.near?.prefix(40) ?? "-") chosen=\(chosen?.displayLabel.prefix(40) ?? "none") top=\(shown)")
                        }
                        // Identical controls: the planner asked for exactly this label, so if Jev can't tell them
                        // apart take the first in reading order (usually the top result).
                        if chosen == nil, matches.count > 1 {
                            chosen = matches[0]
                            Log.info("Grounded via=first_duplicate action=\(step.action)")
                        }
                    }
                    guard let chosen else {
                        let reason = "No \(step.action == "type" ? "editable field" : "clickable control") labelled \"\(label)\" is on screen."
                        if enableOCR(reason) { continue }
                        let permission = useOCR || CGPreflightScreenCaptureAccess() ? "" : " Enable Screen Recording for Third Hand to read unlabeled screen text."
                        return StepOutcome(status: "blocked", detail: reason + permission + " Use a label from the current screen, or scroll or open a menu first.", elements: latest)
                    }
                    if step.action == "type" {
                        guard !(target.isTerminal && terminalInputPending) else {
                            return StepOutcome(status: "rejected", detail: "Terminal input was already entered and not submitted. Press Return to run it, or clear the line first.", elements: latest)
                        }
                        decision = AgentDecision(operation: "TYPE_TEXT", targetIndex: String(chosen.id), textValue: step.text)
                    } else {
                        decision = AgentDecision(operation: chosen.source == "ocr" ? "CLICK_TEXT" : "CLICK", targetIndex: String(chosen.id))
                    }
                }
            }
            try checkFocus()
            guard isCurrent(observation) else {
                history.append(ActionHistory(action: "OBSERVE", result: "Window moved or changed; discarded stale decision."))
                continue
            }
            phase = "validating_action"
            do { try decision.validate(elements: observation.elements, hasScreenshot: false) }
            catch { return StepOutcome(status: "rejected", detail: error.localizedDescription, elements: latest) }
            try checkFocus()
            guard isCurrent(observation) else { continue }
            // Revalidate the chosen control after model latency, even if the window stayed still.
            if let targetID = decision.targetIndex,
               let original = observation.elements.first(where: { String($0.id) == targetID }) {
                phase = "revalidating_target"
                let fresh = try await observe()
                latest = fresh.elements
                guard fresh.windowID == observation.windowID, fresh.frame == observation.frame,
                      let current = ObservationState.matching(original, in: fresh.elements), current.enabled,
                      current.frame == original.frame else {
                    history.append(ActionHistory(action: "OBSERVE", result: "Selected control changed while planning; discarded action."))
                    continue
                }
                decision.targetIndex = String(current.id)
                observation = fresh
            }
            try checkFocus()
            guard isCurrent(observation) else { continue }
            do { try decision.validate(elements: observation.elements, hasScreenshot: false) }
            catch { return StepOutcome(status: "rejected", detail: error.localizedDescription, elements: latest) }
            if decision.operation == "TYPE_TEXT", !target.isTerminal,
               let field = observation.elements.first(where: { String($0.id) == decision.targetIndex }),
               field.value == decision.textValue {
                history.append(ActionHistory(action: "SKIP_TYPE", result: "The selected field already contains the requested text."))
                return StepOutcome(status: "step_complete", detail: "The field already contains this text; no input was sent. Submit it or choose a different action.", elements: latest)
            }
            if let problem = progress.problem(decision: decision, elements: observation.elements) {
                // Let the planner change strategy; repeated-action blocking still applies to its next step.
                progress.acknowledgeFailures()
                return StepOutcome(status: "rejected", detail: problem, elements: latest)
            }
            delegate?.taskRunner(self, status: "\(decision.operation == "TYPE_TEXT" ? "Entering text" : "Working")… (\(actions + 1)/\(maxSteps))")
            actions += 1
            RunMetrics.current.action(fast: fastSettle)
            phase = "executing_\(decision.operation)"
            var executionError: String?
            do { try await execute(decision, elements: observation.elements, windowID: observation.windowID, windowFrame: observation.frame) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try checkFocus()
                executionError = error.localizedDescription
                let reason = (error as? TextFieldFocus.Failure)?.rawValue ?? "input_error"
                Log.info("Action execution failed operation=\(decision.operation) reason=\(reason)")
            }
            delegate?.taskRunner(self, status: "Checking the action…")
            phase = "verifying_\(decision.operation)"
            let after = try await settle(after: decision, before: observation)
            try checkFocus()
            var verification = ObservationState.verify(decision, before: observation.elements, after: after.elements)
            if let executionError {
                verification = ActionVerification(verified: false, detail: "Execution failed: \(executionError)")
            }
            if !isCurrent(after) { verification = ActionVerification(verified: false, detail: "Window changed during verification; result is unverified.") }
            if target.isTerminal, decision.operation == "TYPE_TEXT", executionError == nil {
                verification = ActionVerification(verified: false, detail: "Terminal input sent once and not yet submitted. Press Return to run it; do not retype it.")
            }
            progress.record(verification)
            let described = describe(decision, elements: observation.elements)
            history.append(ActionHistory(action: described, result: verification.detail))
            Log.info("Action step=\(actions) operation=\(decision.operation) verified=\(verification.verified) ocr=\(useOCR)")
            let sent = target.isTerminal && decision.operation == "TYPE_TEXT" && executionError == nil
            return StepOutcome(status: verification.verified ? "verified" : sent ? "sent" : "unverified",
                               detail: "\(described): \(verification.detail)", elements: after.elements)
        }
        return StepOutcome(status: "blocked", detail: "The app kept changing before this step could be performed safely.", elements: latest)
    }

    func prepare(for steps: [PlanStep]) async throws {
        guard !inForeground, !background else { return }
        phase = "awaiting_screen"
        waitingForScreen = true
        defer { waitingForScreen = false }
        try await requestScreen(steps)
        try checkFocus()
        try await bringToFront()
    }

    /// Brings the app forward before its first input, once planning is done.
    private func bringToFront() async throws {
        guard !inForeground else { return }
        phase = "activating"
        delegate?.taskRunner(self, status: "Switching to \(target.name)…")
        target.application.activate()
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            throw ControllerError.invalid("\(target.name) didn't come to the front.")
        }
        // Let the window finish redrawing as the key window before observing it for input.
        try await Task.sleep(nanoseconds: 250_000_000)
        inForeground = true
        Log.info("Target activated for input")
    }

    /// Adds on-device OCR once per task. Returns false when already used or not permitted.
    private func enableOCR(_ reason: String) -> Bool {
        phase = "recovery"
        // OCR regions are clicked by position, which the debugging connection can't address.
        guard !useOCR, !(background && cdpClient != nil), CGPreflightScreenCaptureAccess(), progress.beginRecovery() else {
            Log.info("OCR recovery unavailable already_used=\(useOCR)")
            return false
        }
        Log.info("OCR recovery enabled")
        cdpClient?.disconnect()
        cdpClient = nil
        useOCR = true
        history.append(ActionHistory(action: "RECOVER", result: reason + " Added on-device OCR text from the current window. OCR regions are text, not proven controls."))
        delegate?.taskRunner(self, status: "Reading screen text locally…")
        return true
    }

    private struct Observation {
        let elements: [AccessibilityElement]
        let windowID: CGWindowID
        let frame: CGRect
    }

    private func isCurrent(_ observation: Observation) -> Bool {
        // The debugging connection addresses the page, not a window, which may be hidden or minimized.
        if background && cdpClient != nil { return true }
        guard let window = WindowSnapshot.frontWindow(pid: target.pid) else { return false }
        return window.id == observation.windowID && window.frame == observation.frame
    }

    private func observe() async throws -> Observation {
        try checkFocus()
        let visibleWindow = WindowSnapshot.frontWindow(pid: target.pid)
        guard let window = visibleWindow ?? (background && cdpClient != nil ? (id: 0, frame: .zero) : nil) else {
            throw ControllerError.invalid(background
                ? "\(target.name) has no open window on this desktop. Background control needs a window that isn't minimized or hidden."
                : "No visible target window")
        }
        var elements: [AccessibilityElement] = []
        if let cdp = cdpClient {
            do { elements = try await cdp.extractElements() }
            catch is CancellationError { throw CancellationError() }
            catch {
                cdp.disconnect(); cdpClient = nil
                // Accessibility IDs don't address page elements, so background control can't fall back.
                if background { throw ControllerError.invalid("Lost the background connection to \(target.name).") }
                Log.info("Browser observation unavailable; using accessibility")
            }
        }
        if elements.isEmpty && (!background || cdpClient == nil) { elements = AXTreeWalker.walk(target: target) }
        try checkFocus()
        if useOCR {
            let ocr = try await AsyncTimeout.run(seconds: 8, message: "Local screen reading timed out.") {
                try await VisionObserver.observe(pid: self.target.pid)
            }
            elements = VisionObserver.merging(ocr: ocr, with: elements)
        }
        try checkFocus()
        let result = Observation(elements: elements, windowID: window.id, frame: window.frame)
        guard isCurrent(result) else {
            throw ControllerError.invalid("Window changed during observation. Start again in the intended window.")
        }
        Log.info("Observation window=\(window.id) width=\(Int(window.frame.width)) height=\(Int(window.frame.height)) count=\(elements.count) capped=\(elements.count >= 500) ocr=\(useOCR)")
        return result
    }

    private func settle(after decision: AgentDecision, before: Observation) async throws -> Observation {
        // A page can say when it stops changing, instead of polling the screen for a second or more.
        if let cdp = cdpClient, background || cdp.isConnected {
            do {
                // Typing redraws immediately; Return and clicks may navigate and load results.
                let navigates = decision.operation != "TYPE_TEXT"
                // The ultrafast loop re-reads the page every cycle and can wait, so it settles briefly.
                let changed = fastSettle
                    ? try await cdp.waitForQuiet(firstChangeMs: navigates ? 250 : 200, quietMs: navigates ? 80 : 60, maxMs: navigates ? 700 : 400)
                    : try await cdp.waitForQuiet(firstChangeMs: navigates ? 1000 : 600,
                                                 quietMs: navigates ? 350 : 150, maxMs: navigates ? 3000 : 1500)
                let latest = try await observe()
                Log.info("Settle via=dom changed=\(changed)")
                return latest
            } catch is CancellationError { throw CancellationError() }
            catch { if background { throw error } }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .seconds(2.5))
        var previous = ObservationState.signature(before.elements)
        var stableSince = start
        var latest = before
        repeat {
            try await Task.sleep(nanoseconds: 150_000_000)
            latest = try await observe()
            let signature = ObservationState.signature(latest.elements)
            if signature != previous { previous = signature; stableSince = clock.now }
            // Don't accept the first intermediate redraw. Require a quiet interval,
            // and allow slower submissions/navigation at least one second.
            if clock.now - start >= .seconds(1), clock.now - stableSince >= .milliseconds(400),
               ObservationState.verify(decision, before: before.elements, after: latest.elements).verified { break }
        } while clock.now < deadline
        return latest
    }

    private func describe(_ decision: AgentDecision, elements: [AccessibilityElement]) -> String {
        let label = elements.first { String($0.id) == decision.targetIndex }?.displayLabel ?? "none"
        return "\(decision.operation) target=\(label) text=\(decision.textValue ?? "") key=\(decision.key ?? "")"
    }

    // MARK: - Execution

    /// Background input through the debugging connection; the app stays wherever it is.
    private func executeInBackground(_ decision: AgentDecision) async throws {
        guard let cdp = cdpClient else { throw ControllerError.invalid("The background connection closed.") }
        let id = decision.targetIndex.flatMap(Int.init)
        switch decision.operation {
        case "CLICK", "CLICK_TEXT":
            guard let id else { throw ControllerError.invalid("No control was selected.") }
            try await cdp.click(id: id)
        case "DOUBLE_CLICK":
            guard let id else { throw ControllerError.invalid("No control was selected.") }
            try await cdp.click(id: id, count: 2)
        case "TYPE_TEXT":
            guard let id, let text = decision.textValue else { throw ControllerError.invalid("No editable field was selected.") }
            try await cdp.replaceText(id: id, text: text)
        case "KEY_PRESS": try await cdp.press(decision.key!, modifiers: decision.modifiers ?? [])
        case "SCROLL_UP", "SCROLL_DOWN": try await cdp.scroll(deltaY: decision.operation == "SCROLL_UP" ? -400 : 400, at: id)
        case "WAIT": try await Task.sleep(nanoseconds: 700_000_000)
        default: throw ControllerError.invalid("That action isn't available in the background.")
        }
    }

    /// Some controls activate their app when used, even from the background (WebKit does on focus).
    /// Hands the front back to the user's app when that follows an input; switching to the app later
    /// is the user's choice and is left alone.
    private func watchForActivation() {
        Task { [weak self] in
            while let self, self.active, !Task.isCancelled {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == self.target.pid,
                   Date().timeIntervalSince(self.lastWindowInput) < 1.5, let user = self.userApp {
                    Log.info("Target took the front after input; restoring the user's app")
                    user.activate()
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Background input for apps without a debugging connection: accessibility actions first, then
    /// events addressed to the target window. The user's pointer, front app and key window stay put.
    private func executeInWindow(_ decision: AgentDecision, elements: [AccessibilityElement],
                                 windowID: CGWindowID, windowFrame: CGRect?) async throws {
        let element = elements.first { String($0.id) == decision.targetIndex }
        let point = element?.screenFrame().map { CGPoint(x: $0.midX, y: $0.midY) }
        func click(count: Int = 1, right: Bool = false) throws {
            guard let point else { throw ControllerError.invalid("The selected control did not expose a clickable position.") }
            guard let windowFrame, windowFrame.contains(point) else { throw ControllerError.invalid("Target is outside the current window") }
            try BackgroundInput.click(pid: target.pid, window: windowID, at: point, count: count, right: right)
        }
        func focusedElement() -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target.appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != target.pid { userApp = front }
        lastWindowInput = Date()
        defer { lastWindowInput = Date() }
        try checkFocus()
        switch decision.operation {
        case "CLICK", "CLICK_TEXT":
            if let element, let ax = element.axElement {
                for action in ["AXPress", "AXOpen", "AXConfirm", "AXPick"] where element.actions.contains(action) {
                    if AXUIElementPerformAction(ax, action as CFString) == .success { return }
                }
            }
            try click()
        case "DOUBLE_CLICK": try click(count: 2)
        case "RIGHT_CLICK": try click(right: true)
        case "TYPE_TEXT":
            guard let text = decision.textValue else { throw ControllerError.invalid("Missing text") }
            guard let element, let ax = element.axElement else { throw ControllerError.invalid("No editable field was selected.") }
            phase = "confirming_field_focus"
            // Focus by clicking: setting AXFocused activates some apps (Safari does).
            try await TextFieldFocus.prepare(check: checkFocus, probe: { TextFieldFocus.confirmed(ax, app: self.target.appElement) },
                                             requestFocus: { try click() }, click: { try click() })
            if target.isTerminal {
                // Readline-style editing for a shell prompt.
                try BackgroundInput.press(pid: target.pid, window: windowID, key: "a", modifiers: ["control"])
                try BackgroundInput.press(pid: target.pid, window: windowID, key: "k", modifiers: ["control"])
            } else if !(element.value ?? "").isEmpty, !BackgroundInput.selectAll(in: focusedElement() ?? ax) {
                throw ControllerError.invalid("The field's existing text couldn't be selected in the background. No text was entered.")
            }
            phase = "typing_text"
            try await BackgroundInput.type(pid: target.pid, window: windowID, text: text) {
                try self.checkFocus()
                guard TextFieldFocus.confirmed(ax, app: self.target.appElement) else { throw TextFieldFocus.Failure.changed }
            }
            if target.isTerminal { terminalInputPending = true }
        case "KEY_PRESS":
            let key = decision.key!, modifiers = decision.modifiers ?? []
            // Menu key equivalents only reach the front app, so ⌘ shortcuts go through the menu when one
            // matches. Others, like ⌘↓ in a text view, are ordinary keys the window handles itself.
            let command = modifiers.contains("command")
            if command, key.lowercased() == "a", modifiers == ["command"], let field = focusedElement(), BackgroundInput.selectAll(in: field) {
                Log.info("Background shortcut via=select_all")
            } else if command, BackgroundInput.menuShortcut(app: target.appElement, key: key, modifiers: modifiers) {
                Log.info("Background shortcut via=menu")
            } else {
                try BackgroundInput.press(pid: target.pid, window: windowID, key: key, modifiers: modifiers)
            }
            terminalInputPending = false
        case "SCROLL_UP", "SCROLL_DOWN":
            guard let frame = windowFrame else { throw ControllerError.invalid("No window to scroll") }
            try BackgroundInput.scroll(pid: target.pid, window: windowID, at: point ?? CGPoint(x: frame.midX, y: frame.midY),
                                       lines: decision.operation == "SCROLL_UP" ? 5 : -5)
        case "WAIT": try await Task.sleep(nanoseconds: 700_000_000)
        default: throw ControllerError.invalid("Unsupported operation")
        }
    }

    private func execute(_ decision: AgentDecision, elements: [AccessibilityElement], windowID: CGWindowID, windowFrame: CGRect?) async throws {
        if background {
            if cdpClient != nil { return try await executeInBackground(decision) }
            return try await executeInWindow(decision, elements: elements, windowID: windowID, windowFrame: windowFrame)
        }
        let element = elements.first { String($0.id) == decision.targetIndex }
        let point: CGPoint?
        if let element, let frame = element.screenFrame() {
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else { point = nil }
        func click(count: Int = 1, right: Bool = false) throws {
            guard let point else {
                Log.info("Click rejected reason=missing_target_bounds")
                throw ControllerError.invalid("The selected control did not expose a clickable position.")
            }
            guard let windowFrame, windowFrame.contains(point) else {
                Log.info("Click rejected reason=target_outside_window")
                throw ControllerError.invalid("Target is outside the current window")
            }
            try InputController.click(point, count: count, right: right)
        }
        try checkFocus()
        switch decision.operation {
        case "CLICK", "CLICK_TEXT":
            if let element, let ax = element.axElement {
                for action in ["AXPress", "AXOpen", "AXConfirm", "AXPick"] where element.actions.contains(action) {
                    if AXUIElementPerformAction(ax, action as CFString) == .success { return }
                }
            }
            try click()
        case "DOUBLE_CLICK": try click(count: 2)
        case "RIGHT_CLICK": try click(right: true)
        case "TYPE_TEXT":
            guard let text = decision.textValue else { throw ControllerError.invalid("Missing text") }
            guard let element else { throw ControllerError.invalid("No editable field was selected.") }
            func fieldHasFocus() async throws -> Bool {
                if let ax = element.axElement {
                    return TextFieldFocus.confirmed(ax, app: self.target.appElement)
                }
                let fresh = try await self.observe()
                return ObservationState.matching(element, in: fresh.elements)?.focused == true
            }
            phase = "confirming_field_focus"
            Log.info("Text entry stage=confirming_focus")
            try await TextFieldFocus.prepare(check: checkFocus, probe: fieldHasFocus, requestFocus: {
                if let ax = element.axElement {
                    AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
            }, click: {
                Log.info("Text entry stage=clicking_field")
                try click()
            })
            try checkFocus()
            if target.isTerminal {
                // Readline-style editing for a shell prompt; Command-A selects scrollback.
                try InputController.press("a", modifiers: ["control"])
                try InputController.press("k", modifiers: ["control"])
            } else { try InputController.press("a", modifiers: ["command"]) }
            try await Task.sleep(nanoseconds: 80_000_000)
            func checkTypingFocus() throws {
                try checkFocus()
                if let ax = element.axElement,
                   !TextFieldFocus.confirmed(ax, app: target.appElement) {
                    throw TextFieldFocus.Failure.changed
                }
            }
            try checkTypingFocus()
            phase = "typing_text"
            Log.info("Text entry stage=typing")
            try await InputController.type(text, check: checkTypingFocus)
            if target.isTerminal { terminalInputPending = true }
            Log.info("Text entry stage=input_sent")
        case "KEY_PRESS":
            try InputController.press(decision.key!, modifiers: decision.modifiers ?? [])
            terminalInputPending = false
        case "SCROLL_UP", "SCROLL_DOWN":
            guard let frame = windowFrame else { throw ControllerError.invalid("No window to scroll") }
            try InputController.scroll(decision.operation == "SCROLL_UP" ? 5 : -5,
                                       at: point ?? CGPoint(x: frame.midX, y: frame.midY))
        case "WAIT": try await Task.sleep(nanoseconds: 700_000_000)
        default: throw ControllerError.invalid("Unsupported operation")
        }
    }
}
