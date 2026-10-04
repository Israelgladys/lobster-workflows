import Foundation
import ApplicationServices

struct ActionVerification {
    let verified: Bool
    let detail: String
}

enum ObservationState {
    /// Snapshot-local IDs and traversal order are not identities.
    /// Playback progress, sliders, and running clocks change on their own; they're not evidence an action worked.
    static func isAmbient(_ element: AccessibilityElement) -> Bool {
        if ["AXProgressIndicator", "AXSlider"].contains(element.role) { return true }
        return element.role == "AXStaticText"
            && element.displayLabel.range(of: #"^-?\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    static func signature(_ elements: [AccessibilityElement]) -> String {
        elements.filter { !isAmbient($0) }.map { element in
            let box = element.frame.map { "\(Int(($0.midX / 8).rounded())),\(Int(($0.midY / 8).rounded()))" } ?? ""
            return "\(element.source)|\(element.role)|\(element.displayLabel)|\(element.value ?? "")|\(element.enabled)|\(element.focused)|\(box)"
        }.sorted().joined(separator: "\n")
    }

    static func matching(_ target: AccessibilityElement, in elements: [AccessibilityElement]) -> AccessibilityElement? {
        if let ax = target.axElement, let exact = elements.first(where: { $0.axElement.map { CFEqual(ax, $0) } ?? false }) { return exact }
        // arc's id identifies the element while it exists; a rebuilt element is matched like any other below.
        if let id = target.driverID, let same = elements.first(where: { $0.driverID == id }) { return same }
        let matches = elements.filter { $0.source == target.source && $0.role == target.role && $0.displayLabel == target.displayLabel }
        if matches.count == 1 { return matches[0] }
        if let frame = target.frame {
            return matches.first { candidate in
                guard let other = candidate.frame else { return false }
                return abs(frame.midX - other.midX) < 8 && abs(frame.midY - other.midY) < 8
            }
        }
        return nil
    }

    static func verify(_ decision: AgentDecision, before: [AccessibilityElement], after: [AccessibilityElement]) -> ActionVerification {
        let target = before.first { String($0.id) == decision.targetIndex }
        if decision.operation == "TYPE_TEXT" {
            guard let target, let actual = matching(target, in: after), actual.value == decision.textValue else {
                return ActionVerification(verified: false, detail: "Text entry could not be verified in the selected field. Do not assume it succeeded.")
            }
            return ActionVerification(verified: true, detail: "Selected field contains the complete requested text. Submission is not yet verified.")
        }
        if let target, let actual = matching(target, in: after), !target.focused && actual.focused {
            return ActionVerification(verified: true, detail: "The selected control gained focus; the overall goal still needs checking.")
        }
        let changed = signature(before) != signature(after)
        return ActionVerification(verified: changed, detail: changed
            ? "Observed UI state changed after input. Check the current screen for the intended result; change alone is not completion."
            : "No observable effect after waiting for the UI to settle. Do not repeat the same action without a different strategy.")
    }
}

struct RunProgress {
    private var pairs: [String] = []
    private var actions: [String] = []
    private var failedTargets: Set<String> = []
    private var pendingTarget: String?
    private(set) var failures = 0
    private(set) var usedRecovery = false

    mutating func record(_ verification: ActionVerification) {
        failures = verification.verified ? 0 : failures + 1
        if !verification.verified, let pendingTarget { failedTargets.insert(pendingTarget) }
        pendingTarget = nil
    }

    mutating func problem(decision: AgentDecision, elements: [AccessibilityElement]) -> String? {
        let target = elements.first { String($0.id) == decision.targetIndex }
        let identity = target.map { "\($0.role):\($0.displayLabel):\($0.frame.map { "\(Int($0.midX / 8)),\(Int($0.midY / 8))" } ?? "")" } ?? "\(decision.x ?? -1),\(decision.y ?? -1)"
        let action = "\(decision.operation)|\(identity)|\(decision.textValue ?? "")|\(decision.key ?? "")|\((decision.modifiers ?? []).sorted())"
        // Ignore changing clocks/progress text and OCR additions when identifying a
        // repeated control state. Snapshot IDs never identify an action or a screen.
        let native = elements.filter { $0.source != "ocr" }
        let controls = native.filter { !["AXStaticText", "AXProgressIndicator"].contains($0.role) }
        let includesContent = ["SCROLL_UP", "SCROLL_DOWN", "WAIT"].contains(decision.operation)
        let screen = includesContent || controls.isEmpty ? (native.isEmpty ? elements : native) : controls
        let pair = action + "\n" + ObservationState.signature(screen)
        let targetState = target.map { action + "\n" + ObservationState.signature([$0]) }
        if pairs.contains(pair) {
            return "Blocked a repeated action on a previously visited control state before sending input. Choose a different action."
        }
        if let targetState, failedTargets.contains(targetState) {
            return "Blocked an action that already failed on this unchanged control. Choose a different action."
        }
        if failures >= 2 { return "The last two actions had no verified effect." }
        if !["SCROLL_UP", "SCROLL_DOWN", "WAIT"].contains(decision.operation), actions.filter({ $0 == action }).count >= 3 {
            return "The same action keeps recurring without reaching the goal."
        }
        // Record only admitted actions. Keep the run's memory across OCR recovery.
        pairs.append(pair)
        actions.append(action)
        pendingTarget = targetState
        return nil
    }

    /// Forgets the action `problem` just admitted, when it turned out not to be sent (the app changed first).
    mutating func retract() {
        if !pairs.isEmpty { pairs.removeLast() }
        if !actions.isEmpty { actions.removeLast() }
        pendingTarget = nil
    }

    /// The planner was told about the failures and will choose a different step.
    mutating func acknowledgeFailures() { failures = 0 }

    mutating func beginRecovery() -> Bool {
        guard !usedRecovery else { return false }
        usedRecovery = true
        failures = 0
        return true
    }
}
