import Foundation

struct JevResult {
    let decision: AgentDecision
    let done: Double
    let absent: Double
    let pickedNone: Bool
    let latencyMs: Int
}

struct JevServiceError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { "Jev rejected the request (HTTP \(status)): \(detail)" }
}

@MainActor
final class JevClient {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    nonisolated static let maxChoices = 255
    nonisolated static let doneThreshold = 0.70
    nonisolated static let absentThreshold = 0.50
    nonisolated private static let noneKey = "__none__"

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

    /// Leave one slot for the explicit none-of-the-above choice. Prefer focused
    /// controls and labels relevant to the goal, preserving snapshot order on ties.
    nonisolated static func offeredTargets(_ elements: [AccessibilityElement], goal: String) -> [String: [String: AccessibilityElement]] {
        let words = Set(goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
        let positions = Dictionary(elements.enumerated().map { (String($0.element.id), $0.offset) }, uniquingKeysWith: min)
        func relevance(_ element: AccessibilityElement) -> Int {
            let labelWords = Set(element.displayLabel.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return words.intersection(labelWords).count * 10 + (element.focused ? 5 : 0)
        }
        return targets(elements).mapValues { candidates in
            let ordered = candidates.values.sorted {
                let lhs = relevance($0), rhs = relevance($1)
                return lhs == rhs ? positions[String($0.id), default: 0] < positions[String($1.id), default: 0] : lhs > rhs
            }
            return Dictionary(uniqueKeysWithValues: ordered.prefix(maxChoices - 1).map { (String($0.id), $0) })
        }
    }

    nonisolated static func requestBody(goal: String, elements: [AccessibilityElement], appName: String, history: [ActionHistory]) -> [String: Any] {
        let targets = offeredTargets(elements, goal: goal)

        var operations: [String: String] = [
            "SCROLL_UP": "Reveal content above",
            "SCROLL_DOWN": "Reveal content below",
            "PRESS_RETURN": "Submit the focused field or confirm the selected item",
            "PRESS_TAB": "Move focus to the next control",
            "PRESS_ESCAPE": "Dismiss the current popup or menu",
            "WAIT": "Wait for content to load",
            "DONE": "All requirements are visibly satisfied on screen",
            "BLOCKED": "No available operation can make progress"
        ]
        for op in targets.keys {
            if op == "CLICK_TEXT" {
                operations[op] = "Click an OCR text region only when its label clearly identifies the requested control. OCR does not prove interactivity; never click headings or ordinary content."
                continue
            }
            operations[op] = op == "TYPE_TEXT"
                ? "Set text in an editable field"
                : "Click an observed enabled control"
        }

        let state: [String: Any] = [
            "task": goal,
            "app": appName,
            "step": history.count + 1,
            "action_attempts": history.isEmpty
                ? ["nothing yet"] as [Any]
                : history.suffix(8).map { "\($0.action): \($0.result)" } as [Any],
            "observationMayBeTruncated": elements.count >= 500,
            "targetChoicesShortlisted": Self.targets(elements).contains { targets[$0.key]?.count != $0.value.count },
            "elements": elements.map { el in
                var desc: [String: Any] = ["id": String(el.id), "label": el.displayLabel, "role": el.displayRole, "enabled": el.enabled, "focused": el.focused, "source": el.source]
                if let v = el.value, !v.isEmpty, v != el.label { desc["value"] = v }
                return desc
            }
        ]

        var questions: [String: Any] = [
            "done": [
                "type": "noul",
                "instructions": "Has this task been completed: \"\(goal)\"? Judge only by what is visible on screen and actions already taken."
            ] as [String: Any],
            "absent": [
                "type": "noul",
                "instructions": "Is the control needed for the next step of \"\(goal)\" missing from the elements on screen?"
            ] as [String: Any],
            "operation": [
                "type": "choice",
                "criteria": operations,
                "instructions": "Which operation advances \"\(goal)\" one step? Do not repeat completed steps. DONE requires visible evidence."
            ] as [String: Any]
        ]

        for (op, candidates) in targets {
            var criteria: [String: String] = [:]
            for (id, el) in candidates {
                var desc = el.displayLabel
                if let v = el.value, !v.isEmpty, v != el.label { desc += " = \(v)" }
                desc += " [\(el.displayRole)]"
                criteria[id] = desc
            }
            criteria[noneKey] = "None of these — the needed control is not on screen"
            questions[op.lowercased() + "_target"] = [
                "type": "choice",
                "criteria": criteria,
                "instructions": "Which element should be the target for \(op) to advance \"\(goal)\"?"
            ] as [String: Any]
        }

        return ["model": "jev-latest", "questions": questions, "state": state]
    }

    // Application budget, deliberately below the service's context limits.
    nonisolated static let maxRequestBytes = 24_000

    nonisolated static func preparedRequest(goal: String, elements: [AccessibilityElement], appName: String,
                                           history: [ActionHistory]) throws -> (data: Data, offered: [String: [String: AccessibilityElement]]) {
        guard goal.utf8.count <= 4000 else {
            throw ControllerError.invalid("Please shorten the request to fit the action selector.")
        }
        let words = Set(goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 2 }.map(String.init))
        func score(_ el: AccessibilityElement) -> Int {
            let label = Set(el.displayLabel.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return (el.focused ? 1000 : 0) + (el.isOutcomeEvidence ? 900 : 0) + words.intersection(label).count * 20
                + (["AXTextField", "AXTextArea", "AXComboBox"].contains(el.role) ? 10 : 0)
        }
        var selected = elements.enumerated().sorted {
            let a = score($0.element), b = score($1.element)
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(160).map { $0.element }
        let attempts = history.suffix(4).map {
            ActionHistory(action: String($0.action.prefix(256)), result: String($0.result.prefix(256)))
        }
        while true {
            let compact = selected.map { el in
                AccessibilityElement(id: el.id, role: el.role, label: String(el.displayLabel.prefix(160)),
                    value: el.value.map { String($0.prefix(160)) }, enabled: el.enabled, actions: el.actions,
                    axElement: el.axElement, frame: el.frame, focused: el.focused, source: el.source)
            }
            var body = requestBody(goal: goal, elements: compact, appName: String(appName.prefix(100)), history: attempts)
            var state = body["state"] as! [String: Any]
            state["observationMayBeTruncated"] = true
            state["observedElementCount"] = elements.count
            state["step"] = history.count + 1
            body["state"] = state
            let data = try JSONSerialization.data(withJSONObject: body)
            if data.count <= maxRequestBytes {
                // Decode only targets present in this exact request, using original metadata.
                let ids = offeredTargets(compact, goal: goal).mapValues { Set($0.keys) }
                let offered = targets(selected).mapValues { candidates in candidates }
                    .reduce(into: [String: [String: AccessibilityElement]]()) { result, pair in
                        result[pair.key] = pair.value.filter { ids[pair.key]?.contains($0.key) == true }
                    }
                return (data, offered)
            }
            guard !selected.isEmpty else {
                throw ControllerError.invalid("The request is too large for the action selector. Please shorten it.")
            }
            selected = Array(selected.prefix(selected.count / 2))
        }
    }

    func decide(goal: String, elements: [AccessibilityElement], appName: String, history: [ActionHistory]) async throws -> JevResult {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let prepared = try Self.preparedRequest(goal: goal, elements: elements, appName: appName, history: history)
        request.httpBody = prepared.data
        let offered = prepared.offered
        let maxChoiceCount = max(8 + offered.count, (offered.values.map(\.count).max() ?? 0) + 1)
        Log.info("Jev request bytes=\(request.httpBody?.count ?? 0) max_choices=\(maxChoiceCount)")
        let start = Date()
        let (data, response) = try await AsyncTimeout.run(seconds: 15, message: "Action selection timed out.") { [session] in
            try await session.data(for: request)
        }
        try Task.checkCancellation()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Log.info("Timing jev_ms=\(ms)")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = Self.errorDetail(data, redacting: apiKey)
            Log.info("Jev error HTTP \(code) detail=\(detail.replacingOccurrences(of: "\n", with: " "))")
            throw JevServiceError(status: code, detail: detail)
        }
        return try Self.decode(data, elements: elements, latencyMs: ms, offered: offered)
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

    // MARK: - Decode

    nonisolated static func decode(_ data: Data, elements: [AccessibilityElement], latencyMs: Int = 0, offered: [String: [String: AccessibilityElement]]? = nil) throws -> JevResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any] else {
            throw ControllerError.invalid("Invalid Jev response")
        }

        let done = (answers["done"] as? [String: Any])?["noul"] as? Double ?? 0
        let absent = (answers["absent"] as? [String: Any])?["noul"] as? Double ?? 0

        guard let opAnswer = answers["operation"] as? [String: Any],
              let opChoice = opAnswer["choice"] as? String else {
            throw ControllerError.invalid("Missing operation in Jev response")
        }

        let targets = offered ?? targets(elements)
        let allowed = Set(targets.keys).union(["SCROLL_UP", "SCROLL_DOWN", "PRESS_RETURN", "PRESS_ESCAPE", "PRESS_TAB", "WAIT", "DONE", "BLOCKED"])
        guard allowed.contains(opChoice) else { throw ControllerError.invalid("Unsupported Jev operation") }

        if let candidates = targets[opChoice] {
            let key = opChoice.lowercased() + "_target"
            guard let tgtAnswer = answers[key] as? [String: Any],
                  let tgtChoice = tgtAnswer["choice"] as? String else {
                throw ControllerError.invalid("Missing target for \(opChoice)")
            }
            if tgtChoice == noneKey {
                return JevResult(
                    decision: AgentDecision(operation: "BLOCKED", reason: "Target not visible on screen"),
                    done: done, absent: absent, pickedNone: true, latencyMs: latencyMs
                )
            }
            guard candidates[tgtChoice] != nil else {
                throw ControllerError.invalid("Invalid target \(tgtChoice)")
            }
            return JevResult(
                decision: AgentDecision(operation: opChoice, targetIndex: tgtChoice),
                done: done, absent: absent, pickedNone: false, latencyMs: latencyMs
            )
        }

        if ["PRESS_RETURN", "PRESS_ESCAPE", "PRESS_TAB"].contains(opChoice) {
            return JevResult(
                decision: AgentDecision(operation: "KEY_PRESS", key: ["PRESS_RETURN": "return", "PRESS_ESCAPE": "escape", "PRESS_TAB": "tab"][opChoice]),
                done: done, absent: absent, pickedNone: false, latencyMs: latencyMs
            )
        }

        return JevResult(
            decision: AgentDecision(operation: opChoice),
            done: done, absent: absent, pickedNone: false, latencyMs: latencyMs
        )
    }
}
