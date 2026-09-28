import Foundation

struct JevServiceError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { "Jev rejected the request (HTTP \(status)): \(detail)" }
}

/// Jev resolves a planner step's label to one on-screen element and routes tasks to a planner tier.
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

    nonisolated static func groundRequest(action: String, target: String, role: String?, candidates: [AccessibilityElement],
                                          appName: String) throws -> (data: Data, offered: [String: AccessibilityElement]) {
        var selected = shortlist(candidates, target: target, role: role)
        let verb = action == "type" ? "type into" : "click"
        let described = role.map { "the \($0) labelled \"\(target)\"" } ?? "the control labelled \"\(target)\""
        while true {
            var criteria: [String: String] = [:]
            for element in selected {
                var desc = String(element.displayLabel.prefix(160))
                if let value = element.value, !value.isEmpty, value != element.label { desc += " = \(value.prefix(160))" }
                desc += " [\(element.displayRole)]"
                if element.source == "ocr" { desc += " (ocr text)" }
                criteria[String(element.id)] = desc
            }
            criteria[noneKey] = "None of these is \(described)"
            let body: [String: Any] = [
                "model": "jev-latest",
                "state": ["app": String(appName.prefix(100)), "action": action, "target": target, "role": role ?? ""],
                "questions": ["target": [
                    "type": "choice", "criteria": criteria,
                    "instructions": "The planner wants to \(verb) \(described). Which element is it? Labels may differ slightly in wording, case, or truncation. OCR text is only valid when it names that control. Choose none if no element plausibly is it."
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
    func ground(action: String, target: String, role: String?, candidates: [AccessibilityElement],
                appName: String) async throws -> AccessibilityElement? {
        let prepared = try Self.groundRequest(action: action, target: target, role: role, candidates: candidates, appName: appName)
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = prepared.data
        Log.info("Jev ground bytes=\(prepared.data.count) choices=\(prepared.offered.count + 1)")
        let start = Date()
        let (data, response) = try await AsyncTimeout.run(seconds: 15, message: "Target selection timed out.") { [session] in
            try await session.data(for: request)
        }
        try Task.checkCancellation()
        Log.info("Timing jev_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = Self.errorDetail(data, redacting: apiKey)
            Log.info("Jev error HTTP \(code) detail=\(detail.replacingOccurrences(of: "\n", with: " "))")
            throw JevServiceError(status: code, detail: detail)
        }
        return try Self.decodeGround(data, offered: prepared.offered)
    }

    // MARK: - Planner routing

    nonisolated static func routingBody(goal: String, appName: String) -> [String: Any] {
        ["model": "jev-latest", "state": ["task": goal, "app": appName],
         "questions": [
            "planner_effort": ["type": "choice", "criteria": [
                "none": "Short, well-specified UI task whose steps are obvious: search, open, play, click or toggle something, or enter text the user supplied",
                "low": "Needs judgment or composition: several goals, writing new text, comparing or choosing among options, or unfamiliar multi-screen workflows"
            ], "instructions": "How much planning effort does this computer-use task need? Prefer none unless the task clearly needs more reasoning."] as [String: Any]
         ] as [String: Any]]
    }

    nonisolated static func decodeTier(_ data: Data) -> PlannerTier? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any],
              let effort = (answers["planner_effort"] as? [String: Any])?["choice"] as? String,
              ["none", "low"].contains(effort) else { return nil }
        return PlannerTier(model: CodexClient.strongModel, effort: effort)
    }

    /// Picks the planner effort for a task (gpt-6-luna was no faster and less reliable at finishing plans);
    /// falls back to the strong tier on any failure.
    func choosePlannerTier(goal: String, appName: String) async -> PlannerTier {
        do {
            var request = URLRequest(url: endpoint, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: Self.routingBody(goal: String(goal.prefix(2000)), appName: appName))
            let start = Date()
            let (data, response) = try await AsyncTimeout.run(seconds: 5, message: "Routing timed out.") { [session] in
                try await session.data(for: request)
            }
            Log.info("Timing jev_route_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
            guard (response as? HTTPURLResponse)?.statusCode == 200, let tier = Self.decodeTier(data) else {
                Log.info("Planner routing unusable; using strong tier")
                return .strong
            }
            return tier
        } catch {
            Log.info("Planner routing failed; using strong tier")
            return .strong
        }
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
