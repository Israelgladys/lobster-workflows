import Foundation

struct JevServiceError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { "Jev rejected the request (HTTP \(status)): \(detail)" }
}

/// Jev resolves a planner step's label to one on-screen element.
/// It never chooses the kind of action: the planner fixes that before Jev is asked.
@MainActor
final class JevClient {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    nonisolated static let maxChoices = 255
    nonisolated static let noneKey = "__none__"
    // Application budget, deliberately below the service's context limits.
    nonisolated static let maxRequestBytes = 24_000

    init(apiKey: String, session: URLSession = .shared,
         endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
    }

    nonisolated static func targets(_ elements: [AccessibilityElement]) -> [String: [String: AccessibilityElement]] {
        var click: [String: AccessibilityElement] = [:]
        var type: [String: AccessibilityElement] = [:]
        var textRegions: [String: AccessibilityElement] = [:]
        let clickRoles: Set<String> = [
            "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTab",
            "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXRow", "AXCell",
            "AXDisclosureTriangle", "AXSwitch"
        ]
        for element in elements where element.enabled {
            let id = String(element.id)
            if element.source == "ocr" {
                if element.frame != nil { textRegions[id] = element }
                continue
            }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(element.role) {
                type[id] = element
                click[id] = element
            } else if clickRoles.contains(element.role) ||
                      element.actions.contains(where: { ["AXPress", "AXOpen", "AXConfirm", "AXPick"].contains($0) }) {
                click[id] = element
            }
        }
        var result: [String: [String: AccessibilityElement]] = [:]
        if !click.isEmpty { result["CLICK"] = click }
        if !type.isEmpty { result["TYPE_TEXT"] = type }
        if !textRegions.isEmpty { result["CLICK_TEXT"] = textRegions }
        return result
    }

    // MARK: - Grounding

    /// Candidates ordered by overlap with the target label, then role and focus, preserving snapshot order on ties.
    /// One slot is left for the explicit none-of-the-above choice.
    nonisolated static func shortlist(_ candidates: [AccessibilityElement], target: String, role: String?) -> [AccessibilityElement] {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let wanted = words(target)
        func relevance(_ element: AccessibilityElement) -> Int {
            wanted.intersection(words(element.displayLabel)).count * 10
                + (role.map { StepMatcher.normalize($0) == StepMatcher.normalize(element.displayRole) } == true ? 5 : 0)
                + (element.focused ? 3 : 0)
        }
        return candidates.enumerated()
            .sorted { relevance($0.element) == relevance($1.element) ? $0.offset < $1.offset : relevance($0.element) > relevance($1.element) }
            .prefix(maxChoices - 1)
            .map(\.element)
    }

    nonisolated static func groundRequest(action: String, target: String, role: String?, near: String? = nil,
                                          candidates: [AccessibilityElement], allExact: Bool = false,
                                          appName: String) throws -> (data: Data, offered: [String: AccessibilityElement]) {
        // Fewer, more relevant options choose better than hundreds when the label didn't match exactly.
        var selected = Array(shortlist(candidates, target: (near.map { target + " " + $0 }) ?? target, role: role)
            .prefix(allExact ? maxChoices - 1 : 60))
        let verb = action == "type" ? "type into" : "click"
        let described = (role.map { "the \($0) labelled \"\(target)\"" } ?? "the control labelled \"\(target)\"")
            + (near.map { " near \"\($0)\"" } ?? "")
        while true {
            var criteria: [String: String] = [:]
            for element in selected {
                var desc = String(element.displayLabel.prefix(160))
                if let value = element.value, !value.isEmpty, value != element.label { desc += " = \(value.prefix(160))" }
                desc += " [\(element.displayRole)]"
                if element.source == "ocr" { desc += " (ocr text)" }
                if let context = element.context { desc += " — in \"\(context.prefix(100))\"" }
                criteria[String(element.id)] = desc
            }
            criteria[noneKey] = "None of these is \(described)"
            let body: [String: Any] = [
                "model": "jev-latest",
                "state": ["app": String(appName.prefix(100)), "action": action, "target": target, "role": role ?? "", "near": near ?? ""],
                "questions": ["target": [
                    "type": "choice", "criteria": criteria,
                    "instructions": allExact
                        ? "The planner wants to \(verb) \(described). Every element below has exactly that label; they differ only by where they are. Choose the one whose context best fits. Choose none only if the context clearly rules out all of them."
                        : "The planner wants to \(verb) \(described). It named the control by the text it expected, so the real label may be longer or phrased differently (for example \"Play <title> by <artist>\"), or be a row or item containing that text. Pick the element that best matches. OCR text is only valid when it names that control. Choose none only if nothing plausibly matches."
                ] as [String: Any]]
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            if data.count <= maxRequestBytes {
                return (data, Dictionary(uniqueKeysWithValues: selected.map { (String($0.id), $0) }))
            }
            guard selected.count > 1 else {
                throw ControllerError.invalid("The step target is too large for the action selector.")
            }
            selected = Array(selected.prefix(selected.count / 2))
        }
    }

    nonisolated static func decodeGround(_ data: Data, offered: [String: AccessibilityElement]) throws -> AccessibilityElement? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = ((json["answers"] as? [String: Any])?["target"] as? [String: Any])?["choice"] as? String else {
            throw ControllerError.invalid("Invalid Jev response")
        }
        if choice == noneKey { return nil }
        guard let element = offered[choice] else { throw ControllerError.invalid("Jev chose a target that was not offered.") }
        return element
    }

    /// The element a step's label refers to among action-compatible candidates, or nil when none matches.
    func ground(action: String, target: String, role: String?, near: String? = nil, candidates: [AccessibilityElement],
                allExact: Bool = false, appName: String) async throws -> AccessibilityElement? {
        let prepared = try Self.groundRequest(action: action, target: target, role: role, near: near,
                                              candidates: candidates, allExact: allExact, appName: appName)
        Log.info("Jev ground bytes=\(prepared.data.count) choices=\(prepared.offered.count + 1)")
        let data = try await post(prepared.data, timeout: 15, message: "Target selection timed out.")
        return try Self.decodeGround(data, offered: prepared.offered)
    }

    // MARK: - Next action (ultrafast loop)

    struct NextAction {
        let done: Double
        /// CLICK, TYPE_TEXT, SCROLL_DOWN, SCROLL_UP, PRESS_RETURN, PRESS_ESCAPE, WAIT, DONE, or BLOCKED.
        let operation: String
        let target: AccessibilityElement?
    }

    nonisolated static let doneThreshold = 0.7
    nonisolated static let loopScreenCharacters = 9_000

    /// One request answers whether the task is done, the next operation, and a speculative target for each
    /// operation that needs one, so deciding what and where costs a single round trip.
    nonisolated static func nextActionRequest(task: String, elements: [AccessibilityElement], appName: String,
                                              history: [String]) throws -> (data: Data, offered: [String: [String: AccessibilityElement]]) {
        let compatible = JevClient.targets(elements)
        func pool(_ keys: [String]) -> [AccessibilityElement] {
            let ids = Set(keys.flatMap { (compatible[$0] ?? [:]).keys })
            return elements.filter { ids.contains(String($0.id)) }
        }
        var clicks = shortlist(pool(["CLICK", "CLICK_TEXT"]), target: task, role: nil)
        var fields = shortlist(pool(["TYPE_TEXT"]), target: task, role: nil)
        var screen = CodexAgent.describe(elements)
        if screen.count > loopScreenCharacters { screen = String(screen.prefix(loopScreenCharacters)) + "\n- …" }
        func describe(_ element: AccessibilityElement) -> String {
            var desc = String(element.displayLabel.prefix(120))
            if let value = element.value, !value.isEmpty, value != element.label { desc += " = \(value.prefix(80))" }
            desc += " [\(element.displayRole)]"
            if let context = element.context { desc += " — in \"\(context.prefix(80))\"" }
            return desc
        }
        while true {
            var operations: [String: String] = [
                "SCROLL_DOWN": "Reveal more content below",
                "SCROLL_UP": "Reveal content above",
                "PRESS_RETURN": "Submit the focused field or open the selected item",
                "PRESS_ESCAPE": "Dismiss a popup, menu, or dialog that is in the way",
                "WAIT": "Content is still loading",
                "DONE": "The task is visibly complete on screen",
                "BLOCKED": "Nothing on screen can advance the task"
            ]
            var questions: [String: Any] = [
                "done": ["type": "noul", "instructions": "Is this task visibly complete on the screen right now: \"\(task)\"? Judge only by the screen."] as [String: Any]
            ]
            if !clicks.isEmpty {
                operations["CLICK"] = "Click a control that advances the task"
                var criteria = Dictionary(uniqueKeysWithValues: clicks.map { (String($0.id), describe($0)) })
                criteria[noneKey] = "None of these"
                questions["click_target"] = ["type": "choice", "criteria": criteria,
                                             "instructions": "If clicking, which control advances \"\(task)\"?"] as [String: Any]
            }
            if !fields.isEmpty {
                operations["TYPE_TEXT"] = "Enter text in an editable field (the text is written separately)"
                var criteria = Dictionary(uniqueKeysWithValues: fields.map { (String($0.id), describe($0)) })
                criteria[noneKey] = "None of these"
                questions["type_text_target"] = ["type": "choice", "criteria": criteria,
                                                 "instructions": "If typing, which field should receive text for \"\(task)\"?"] as [String: Any]
            }
            questions["operation"] = ["type": "choice", "criteria": operations,
                                      "instructions": "Which single operation advances \"\(task)\" from this screen? Don't repeat an action that had no effect or retype text a field already shows."] as [String: Any]
            let body: [String: Any] = [
                "model": "jev-latest",
                "state": ["task": task, "app": String(appName.prefix(100)), "screen": screen,
                          "actions_so_far": history.isEmpty ? ["none"] : Array(history.suffix(8))],
                "questions": questions
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            if data.count <= maxRequestBytes {
                return (data, ["CLICK": Dictionary(uniqueKeysWithValues: clicks.map { (String($0.id), $0) }),
                               "TYPE_TEXT": Dictionary(uniqueKeysWithValues: fields.map { (String($0.id), $0) })])
            }
            if clicks.count > 20 { clicks = Array(clicks.prefix(clicks.count / 2)) }
            else if fields.count > 10 { fields = Array(fields.prefix(fields.count / 2)) }
            else if screen.count > 1000 { screen = String(screen.prefix(screen.count / 2)) }
            else { throw ControllerError.invalid("The screen is too large for the action selector.") }
        }
    }

    nonisolated static func decodeNextAction(_ data: Data, offered: [String: [String: AccessibilityElement]]) throws -> NextAction {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any],
              let operation = (answers["operation"] as? [String: Any])?["choice"] as? String else {
            throw ControllerError.invalid("Invalid Jev response")
        }
        let done = ((answers["done"] as? [String: Any])?["noul"] as? Double) ?? 0
        let head = ["CLICK": "click_target", "TYPE_TEXT": "type_text_target"][operation]
        guard let head else { return NextAction(done: done, operation: operation, target: nil) }
        let choice = (answers[head] as? [String: Any])?["choice"] as? String
        guard let choice, let target = offered[operation]?[choice] else { return NextAction(done: done, operation: "BLOCKED", target: nil) }
        return NextAction(done: done, operation: operation, target: target)
    }

    func nextAction(task: String, elements: [AccessibilityElement], appName: String, history: [String]) async throws -> NextAction {
        let prepared = try Self.nextActionRequest(task: task, elements: elements, appName: appName, history: history)
        let data = try await post(prepared.data, timeout: 15, message: "Action selection timed out.")
        return try Self.decodeNextAction(data, offered: prepared.offered)
    }

    private func post(_ body: Data, timeout: TimeInterval, message: String) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let start = Date()
        let (data, response) = try await AsyncTimeout.run(seconds: timeout, message: message) { [session] in
            try await session.data(for: request)
        }
        try Task.checkCancellation()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        RunMetrics.current.jev(ms: ms)
        Log.info("Timing jev_ms=\(ms) bytes=\(body.count)")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = Self.errorDetail(data, redacting: apiKey)
            Log.info("Jev error HTTP \(code) detail=\(detail.replacingOccurrences(of: "\n", with: " "))")
            throw JevServiceError(status: code, detail: detail)
        }
        return data
    }

    nonisolated static func errorDetail(_ data: Data, redacting key: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "The service returned no readable validation detail."
        }
        let error = json["error"] as? [String: Any]
        let validation = (json["detail"] as? [[String: Any]])?.compactMap { $0["msg"] as? String }.joined(separator: "; ")
        let message = (error?["message"] as? String) ?? (json["message"] as? String)
            ?? (json["detail"] as? String) ?? (json["error"] as? String) ?? validation
        guard let message else { return "The request failed server validation; check request size and supported fields." }
        let safe = key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[redacted]")
        // Preserve the bounded validation message, never the raw response or input fields.
        return String(safe.prefix(400))
    }
}
