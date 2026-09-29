import Foundation

/// Counters for the task that's running, for timing logs and benchmarks. Tasks run one at a time.
@MainActor
final class RunMetrics {
    static var current = RunMetrics()

    let started = Date()
    private(set) var codexCalls = 0
    private(set) var codexMs = 0
    private(set) var jevCalls = 0
    private(set) var jevMs = 0
    private(set) var actions = 0
    private(set) var fastActions = 0
    /// 1 when the ultrafast loop finished the task without the planner.
    private(set) var fastPathDone = 0

    func codex(ms: Int) { codexCalls += 1; codexMs += ms }
    func jev(ms: Int) { jevCalls += 1; jevMs += ms }
    func action(fast: Bool) { actions += 1; if fast { fastActions += 1 } }
    func fastPath() { fastPathDone = 1 }

    var totalMs: Int { Int(Date().timeIntervalSince(started) * 1000) }

    var summary: [String: Int] {
        ["total_ms": totalMs, "codex_calls": codexCalls, "codex_ms": codexMs, "jev_calls": jevCalls, "jev_ms": jevMs,
         "actions": actions, "fast_actions": fastActions, "fast_path": fastPathDone]
    }

    var logLine: String {
        summary.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}
