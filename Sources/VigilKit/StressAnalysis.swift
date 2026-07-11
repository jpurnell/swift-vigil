import Foundation
import QualityGateTypes

/// A test that did not return the same outcome across every run of a stress
/// batch — a definitive race, since all runs share the same commit and
/// source.
public struct StressFlip: Sendable, Equatable {
    /// Enclosing suite/class name.
    public let suite: String
    /// Test display name.
    public let test: String
    /// How many of the runs passed.
    public let passes: Int
    /// How many of the runs failed.
    public let failures: Int

    /// Creates a stress flip.
    public init(suite: String, test: String, passes: Int, failures: Int) {
        self.suite = suite
        self.test = test
        self.passes = passes
        self.failures = failures
    }
}

/// Pure detection over stress-batch rosters (Phase 4 extraction).
///
/// The orchestration — spawning `swift test` N times under CPU contention —
/// stays with the caller (quality-gate's TestRunner, or `vigil stress`);
/// this is the analysis both share.
public enum StressAnalysis {

    /// Finds tests that were not unanimous across a batch of identical
    /// stress runs.
    ///
    /// A stress flip needs both a pass and a fail for the same test across
    /// the rosters — a uniformly failing (or passing) test is not a flip.
    /// Requires ≥2 rosters.
    ///
    /// - Parameter rosters: One roster per stress repetition.
    /// - Returns: The flipping tests with their pass/fail tallies, in
    ///   first-seen order.
    public static func flips(rosters: [[TestOutcome]]) -> [StressFlip] {
        guard rosters.count >= 2 else { return [] }

        var order: [String] = []
        var passes: [String: Int] = [:]
        var failures: [String: Int] = [:]
        var meta: [String: (suite: String, test: String)] = [:]

        for roster in rosters {
            for outcome in roster {
                let key = outcome.key
                if meta[key] == nil {
                    meta[key] = (outcome.suite, outcome.test)
                    order.append(key)
                }
                if outcome.passed { passes[key, default: 0] += 1 } else { failures[key, default: 0] += 1 }
            }
        }

        return order.compactMap { key in
            let p = passes[key] ?? 0
            let f = failures[key] ?? 0
            guard p > 0 && f > 0, let info = meta[key] else { return nil }
            return StressFlip(suite: info.suite, test: info.test, passes: p, failures: f)
        }
    }

    /// Builds diagnostics for intra-batch stress flips.
    ///
    /// Framed as a *definitive* race (same commit, same source, N identical
    /// runs), which is a stronger signal than a cross-commit flip. Severity
    /// is `.warning` by default, `.error` under `strict`.
    ///
    /// - Parameters:
    ///   - flips: The flips from ``flips(rosters:)``.
    ///   - runs: The number of stress repetitions (surfaced in the message).
    ///   - strict: When true, emit `.error` instead of `.warning`.
    /// - Returns: One diagnostic per flip.
    public static func diagnostics(for flips: [StressFlip], runs: Int, strict: Bool) -> [Diagnostic] {
        flips.map { flip in
            let scope = flip.suite.isEmpty ? flip.test : "\(flip.suite).\(flip.test)"
            return Diagnostic(
                severity: strict ? .error : .warning,
                message: "definitive race: '\(scope)' was not unanimous across \(runs) identical stress runs (\(flip.passes) passed / \(flip.failures) failed) — same commit, same source",
                ruleId: "test.stress-flip",
                suggestedFix: "The test's outcome depends on scheduling, not inputs. Fix the timing window (teardown liveness, reconnect budget, or phase sync) it exercises."
            )
        }
    }
}
