import AppKit
import ApplicationServices

@MainActor
protocol TaskRunnerDelegate: AnyObject {
    func taskRunner(_ r: TaskRunner, status: String)
    func taskRunnerDone(_ r: TaskRunner)
    func taskRunnerFailed(_ r: TaskRunner, error: String)
    func taskRunnerCancelled(_ r: TaskRunner)
}

@MainActor
final class TaskRunner: ActionLayer {
    let target: AppTarget
    let goal: String
    let apiKey: String
    let credentials: CodexCredentials
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
    private var actions = 0
    private lazy var jev = JevClient(apiKey: apiKey)

    init(target: AppTarget, goal: String, apiKey: String, credentials: CodexCredentials) {
        self.target = target
        self.goal = goal
        self.apiKey = apiKey
        self.credentials = credentials
    }

    func start() {
        guard task == nil else { return }
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
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            Log.info("Task focus lost phase=\(phase)")
            throw ControllerError.invalid("Stopped because the active app changed. Return to \(target.name) and try again.")
        }
    }

    private func run() async {
        defer { active = false; cdpClient?.disconnect(); cdpClient = nil }
        do {
            try await AsyncTimeout.run(seconds: 300, message: "Stopped after five minutes. The task has not been verified complete.", onTimeout: {
                self.active = false
                self.cdpClient?.disconnect()
            }) { try await self.runAgent() }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            let diagnostic = error as NSError
            Log.info("Task failed phase=\(phase) error_type=\(String(reflecting: type(of: error))) error_code=\(diagnostic.code)")
            delegate?.taskRunnerFailed(self, error: error.localizedDescription)
        }
    }

    private func runAgent() async throws {
        guard AXIsProcessTrusted() else { throw ControllerError.invalid("Enable Accessibility for Third Hand in System Settings.") }
        // Route while the app activates; a manual model or effort setting skips routing.
        let override = (CodexClient.modelOverride, CodexClient.effortOverride)
        let routing = Task { [jev, goal, name = target.name] in
            override.0 != nil && override.1 != nil ? PlannerTier(model: override.0!, effort: override.1!)
                : await jev.choosePlannerTier(goal: goal, appName: name)
        }
        defer { routing.cancel() }
        target.application.activate()
        try await Task.sleep(nanoseconds: 400_000_000)
        try checkFocus()
        if ElectronDetector.isElectron(target), let window = WindowSnapshot.frontWindow(pid: target.pid),
           let port = await ElectronDetector.findDebugPort(pid: target.pid) {
            try checkFocus()
            let cdp = CDPClient(port: port)
            do { try await cdp.connect(windowFrame: window.frame); cdpClient = cdp }
            catch { cdp.disconnect(); Log.info("Existing browser connection unavailable; using accessibility") }
        }
        try checkFocus()
        AXUIElementSetAttributeValue(target.appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target.appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        phase = "planning"
        let routed = await routing.value
        let tier = PlannerTier(model: override.0 ?? routed.model, effort: override.1 ?? routed.effort)
        Log.info("Planner tier model=\(tier.model) effort=\(tier.effort)")
        let agent = CodexAgent(planner: CodexClient(credentials: credentials), tier: tier,
                               escalation: override.0 == nil ? .strong : nil)
        let outcome = try await agent.run(goal: goal, appName: target.name, layer: self) { [weak self] status in
            guard let self else { return }
            self.delegate?.taskRunner(self, status: status)
        }
        try checkFocus()
        switch outcome {
        case .done(let summary):
            Log.info("Task completed actions=\(actions) summary_chars=\(summary.count)")
            delegate?.taskRunnerDone(self)
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

    /// One planner step: Jev grounds the instruction to a control; the planner's text is typed verbatim.
    func perform(instruction: String, text: String?) async throws -> StepOutcome {
        guard actions < maxSteps else {
            throw ControllerError.invalid("Stopped after \(maxSteps) actions. The final screen does not confirm completion.")
        }
        // Jev's done/absent questions are scoped to the step, not the whole task.
        let stepGoal = text.map { "\(instruction) (text to enter: \"\($0.prefix(200))\")" } ?? instruction
        var latest: [AccessibilityElement] = []
        // Separate observation budget bounds stale-window retries and recovery within a step.
        for _ in 0..<4 {
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
            do {
                phase = "selecting_action"
                let result = try await jev.decide(goal: stepGoal, elements: observation.elements, appName: target.name, history: history)
                Log.info("Decision operation=\(result.decision.operation) done=\(result.done) absent=\(result.absent)")
                // A text step is only already satisfied when some field visibly holds that text.
                let textPresent = text.map { text in observation.elements.contains { $0.value == text } } ?? true
                decision = result.done >= JevClient.doneThreshold && textPresent ? AgentDecision(operation: "DONE") : result.decision
            } catch is CancellationError { throw CancellationError() }
            catch let error as JevServiceError { throw error }
            catch {
                try checkFocus()
                return StepOutcome(status: "blocked", detail: "The action selector failed: \(error.localizedDescription)", elements: latest)
            }
            try checkFocus()
            guard isCurrent(observation) else {
                history.append(ActionHistory(action: "OBSERVE", result: "Window moved or changed; discarded stale decision."))
                continue
            }
            if decision.operation == "DONE" {
                return StepOutcome(status: "step_complete", detail: "The action selector judged this step already satisfied on screen; no input was sent.", elements: latest)
            }
            if decision.operation == "BLOCKED" {
                let reason = decision.reason ?? "The control for this step is not visible."
                if enableOCR(reason) { continue }
                let permission = useOCR || CGPreflightScreenCaptureAccess() ? "" : " Enable Screen Recording for Third Hand to read unlabeled screen text."
                return StepOutcome(status: "blocked", detail: reason + permission + " Try a different step, such as scrolling or opening a menu.", elements: latest)
            }
            // A step with text must type it: a click on an editable field becomes entry into that field,
            // and anything else is rejected rather than silently dropping the text.
            if let text, decision.operation != "TYPE_TEXT" {
                guard ["CLICK", "DOUBLE_CLICK"].contains(decision.operation), let targetID = decision.targetIndex,
                      JevClient.targets(observation.elements)["TYPE_TEXT"]?[targetID] != nil else {
                    return StepOutcome(status: "rejected", detail: "This step has text to enter, but no editable field was found for it (the selector chose \(decision.operation)). Name the field to type into.", elements: latest)
                }
                decision = AgentDecision(operation: "TYPE_TEXT", targetIndex: targetID, textValue: text)
            }
            if decision.operation == "TYPE_TEXT" {
                guard let text else {
                    return StepOutcome(status: "needs_text", detail: "This step targets an editable field. Call step again with the exact text to enter.", elements: latest)
                }
                guard !(target.isTerminal && terminalInputPending) else {
                    return StepOutcome(status: "rejected", detail: "Terminal input was already entered and not submitted. Press Return to run it, or clear the line first.", elements: latest)
                }
                decision.textValue = text
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
            phase = "executing_\(decision.operation)"
            var executionError: String?
            do { try await execute(decision, elements: observation.elements, windowFrame: observation.frame) }
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

    /// Adds on-device OCR once per task. Returns false when already used or not permitted.
    private func enableOCR(_ reason: String) -> Bool {
        phase = "recovery"
        guard !useOCR, CGPreflightScreenCaptureAccess(), progress.beginRecovery() else {
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
        guard let window = WindowSnapshot.frontWindow(pid: target.pid) else { return false }
        return window.id == observation.windowID && window.frame == observation.frame
    }

    private func observe() async throws -> Observation {
        try checkFocus()
        guard let window = WindowSnapshot.frontWindow(pid: target.pid) else { throw ControllerError.invalid("No visible target window") }
        var elements: [AccessibilityElement] = []
        if let cdp = cdpClient {
            do { elements = try await cdp.extractElements() }
            catch is CancellationError { throw CancellationError() }
            catch { cdp.disconnect(); cdpClient = nil; Log.info("Browser observation unavailable; using accessibility") }
        }
        if elements.isEmpty { elements = AXTreeWalker.walk(target: target) }
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

    private func execute(_ decision: AgentDecision, elements: [AccessibilityElement], windowFrame: CGRect?) async throws {
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
