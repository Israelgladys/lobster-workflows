import Foundation

/// One planner step with a fixed action, so grounding never has to guess what kind of input is meant.
struct PlanStep: Equatable {
    nonisolated static let actions = ["click", "type", "press", "scroll", "wait"]

    let action: String
    var target: String? = nil
    var role: String? = nil
    var text: String? = nil
    var key: String? = nil
    var modifiers: [String] = []
    var direction: String? = nil

    /// Accepts "return", "command+f", or "cmd+shift+z".
    nonisolated static func parseKey(_ raw: String) -> (key: String, modifiers: [String])? {
        let aliases = ["cmd": "command", "ctrl": "control", "alt": "option", "opt": "option"]
        var parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.popLast(), InputController.keyCodes[key] != nil else { return nil }
        let modifiers = parts.map { aliases[$0] ?? $0 }
        guard modifiers.allSatisfy({ ["command", "shift", "option", "control"].contains($0) }),
              Set(modifiers).count == modifiers.count else { return nil }
        return (key, modifiers)
    }

    nonisolated static func parse(_ raw: [String: Any]) -> Result<PlanStep, ControllerError> {
        func string(_ name: String) -> String? {
            (raw[name] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let action = string("action"), actions.contains(action) else {
            return .failure(.invalid("Each step needs an action: \(actions.joined(separator: ", "))."))
        }
        var step = PlanStep(action: action, target: string("target"), role: string("role"))
        if let target = step.target, target.utf8.count > 300 {
            return .failure(.invalid("Targets must be a short on-screen label."))
        }
        switch action {
        case "click":
            guard step.target != nil else { return .failure(.invalid("A click step needs the target's on-screen label.")) }
        case "type":
            guard step.target != nil else { return .failure(.invalid("A type step needs the field's on-screen label.")) }
            // Text is taken verbatim, including leading or trailing spaces.
            guard let text = raw["text"] as? String, !text.isEmpty else { return .failure(.invalid("A type step needs text.")) }
            guard !text.contains("\0"), text.utf16.count <= 12000 else {
                return .failure(.invalid("Text must be under 12,000 characters with no null bytes."))
            }
            step.text = text
        case "press":
            guard let raw = string("key"), let parsed = parseKey(raw) else {
                return .failure(.invalid("A press step needs a supported key, such as return, escape, tab, or command+f."))
            }
            step.key = parsed.key
            step.modifiers = parsed.modifiers
        case "scroll":
            guard let direction = string("direction"), ["up", "down"].contains(direction) else {
                return .failure(.invalid("A scroll step needs direction up or down."))
            }
            step.direction = direction
        default: break
        }
        return .success(step)
    }

    var summary: String {
        switch action {
        case "press": return "press \((modifiers + [key ?? ""]).joined(separator: "+"))"
        case "scroll": return "scroll \(direction ?? "")" + (target.map { " in \"\($0)\"" } ?? "")
        case "wait": return "wait"
        default: return "\(action) \"\(target ?? "")\"" + (role.map { " (\($0))" } ?? "")
        }
    }
}

enum StepMatcher {
    nonisolated static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Elements whose on-screen label is exactly the target. The role narrows matches but a wrong role
    /// never hides the only label match.
    nonisolated static func exact(target: String, role: String?, in pool: [AccessibilityElement]) -> [AccessibilityElement] {
        let wanted = normalize(target)
        let labelled = pool.filter { element in
            normalize(element.displayLabel) == wanted || element.label.map { normalize($0) == wanted } == true
        }
        guard let role, labelled.count > 1 else { return labelled }
        let roled = labelled.filter { normalize($0.displayRole) == normalize(role) }
        return roled.isEmpty ? labelled : roled
    }
}
