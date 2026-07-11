import Foundation
#if canImport(os)
import os
#endif

/// Parses the full pass/fail roster from `swift test` output — the roster
/// the flip detector fingerprints across runs and stress analysis compares
/// within a batch.
///
/// Supports both Swift Testing (`Test "name" passed/failed after …`) and
/// XCTest (`Test Case '-[Suite method]' passed/failed …`). Suite/`started`/
/// summary lines and issue-detail lines are ignored.
public enum TestRosterParser {
    private static let logger = Logger(subsystem: "com.swift-vigil", category: "TestRosterParser")

    /// One outcome per test; empty when none are found.
    ///
    /// - Parameter output: The raw output from `swift test`.
    public static func parse(_ output: String) -> [TestOutcome] {
        var outcomes: [TestOutcome] = []

        // Swift Testing: `Test "name" passed after …` / `… failed after …`.
        // Anchored on `Test "` so `Suite "…"` and `recorded an issue` lines never match.
        let swiftTestingPattern = #"Test \"([^\"]+)\" (passed|failed) after"#
        applyRoster(pattern: swiftTestingPattern, to: output, nameGroup: 1, outcomeGroup: 2, suiteGroup: nil, into: &outcomes)

        // XCTest: `Test Case '-[Suite.Class method]' passed (…)` / `… failed (…)`.
        let xcTestPattern = #"Test Case '-\[([^\]]+?) ([^\]]+)\]' (passed|failed)"#
        applyRoster(pattern: xcTestPattern, to: output, nameGroup: 2, outcomeGroup: 3, suiteGroup: 1, into: &outcomes)

        return outcomes
    }

    /// Runs one roster regex over `output`, appending an outcome per match.
    private static func applyRoster(
        pattern: String,
        to output: String,
        nameGroup: Int,
        outcomeGroup: Int,
        suiteGroup: Int?,
        into outcomes: inout [TestOutcome]
    ) {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
            let range = NSRange(output.startIndex..., in: output)
            for match in regex.matches(in: output, options: [], range: range) {
                guard let nameRange = Range(match.range(at: nameGroup), in: output),
                      let outcomeRange = Range(match.range(at: outcomeGroup), in: output) else { continue }
                let name = String(output[nameRange])
                let passed = output[outcomeRange] == "passed"
                var suite = ""
                if let suiteGroup, let suiteRange = Range(match.range(at: suiteGroup), in: output) {
                    suite = String(output[suiteRange])
                }
                outcomes.append(TestOutcome(suite: suite, test: name, passed: passed))
            }
        } catch {
            logger.warning("Failed to compile roster regex: \(error.localizedDescription, privacy: .public)")
        }
    }
}
