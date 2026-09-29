import Foundation

/// One planner step with a fixed action, so grounding never has to guess what kind of input is meant.
struct PlanStep: Equatable {
    nonisolated static let actions = ["click", "type", "press", "scroll", "wait"]

    let action: String
    var target: String? = nil
    var role: String? = nil
    /// Text near the target (e.g. its row) that tells identical controls apart.
    var near: String? = nil
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
        var step = PlanStep(action: action, target: string("target"), role: string("role"), near: string("near"))
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
        default: return "\(action) \"\(target ?? "")\"" + (role.map { " (\($0))" } ?? "") + (near.map { " near \"\($0)\"" } ?? "")
        }
    }
}

enum StepMatcher {
    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Controls whose label or row text contains every word of the target (and of `near`, when given).
    /// Field values are ignored, so a search box holding the query never matches its own results.
    nonisolated static func containing(target: String, near: String?, in pool: [AccessibilityElement]) -> [AccessibilityElement] {
        let wanted = words(target) + words(near ?? "")
        guard !words(target).isEmpty else { return [] }
        return pool.filter { element in
            let text = Set(words((element.label ?? "") + " " + (element.context ?? "")))
            return wanted.allSatisfy(text.contains)
        }
    }

    nonisolated static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Elements whose on-screen label is exactly the target. The role and nearby text narrow matches,
    /// but never hide the only label match.
    nonisolated static func exact(target: String, role: String?, near: String? = nil, in pool: [AccessibilityElement]) -> [AccessibilityElement] {
        let wanted = normalize(target)
        var matches = pool.filter { element in
            normalize(element.displayLabel) == wanted || element.label.map { normalize($0) == wanted } == true
        }
        if let role, matches.count > 1 {
            let roled = matches.filter { normalize($0.displayRole) == normalize(role) }
            if !roled.isEmpty { matches = roled }
        }
        if let near, matches.count > 1 {
            let nearby = matches.filter { $0.context.map { normalize($0).contains(normalize(near)) } == true }
            if !nearby.isEmpty { matches = nearby }
        }
        return matches
    }
}
