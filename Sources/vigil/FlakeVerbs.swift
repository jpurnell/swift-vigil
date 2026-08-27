import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
import VigilKit
import ProcessKernel

/// Shared spawning for the flake verbs: runs `swift test` in a project and
/// returns its combined output. Orchestration lives here in the CLI —
/// VigilKit stays pure detection.
enum TestSpawner {
    private static let logger = Logger(subsystem: "com.swift-vigil", category: "TestSpawner")

    /// The result of one `swift test` invocation.
    struct RunOutput {
        /// Combined stdout+stderr.
        let output: String
        /// Whether the process exited zero.
        let succeeded: Bool
    }

    /// How long a single `swift test` run may take before it is killed.
    ///
    /// Generous, because a real suite on a cold build is slow and a deadline that
    /// fires on healthy work is worse than none. Finite, because `vigil stress`
    /// runs a suite repeatedly under deliberate contention — the exact conditions
    /// under which a test deadlocks — and an unbounded wait there means the tool
    /// built to find hangs hangs instead of reporting one.
    static let testTimeout: TimeInterval = 1_800

    /// Runs `swift test` (optionally filtered) in `root`.
    ///
    /// Spawned through ``ProcessRunner``, which drains both pipes concurrently and
    /// enforces the deadline by signalling the child's process *group* — SwiftPM
    /// leaves build servers and test helpers behind, and terminating only the
    /// direct child leaves them holding the pipe open.
    static func swiftTest(root: String, filter: String? = nil) throws -> RunOutput {
        var arguments = ["swift", "test"]
        if let filter {
            arguments += ["--filter", filter]
        }
        let result = try ProcessRunner.run(
            "/usr/bin/env", // SAFETY: hardcoded /usr/bin/env swift test
            arguments: arguments,
            currentDirectory: root,
            mergeStderr: true,
            timeout: testTimeout
        )
        if result.exitCode == 124 {
            logger.warning("swift test in \(root, privacy: .public) exceeded \(Int(testTimeout), privacy: .public)s and was terminated")
        }
        return RunOutput(output: result.stdout, succeeded: result.exitCode == 0)
    }

    /// Best-effort short commit hash for run records.
    static func currentCommit(root: String) -> String {
        do {
            let result = try ProcessRunner.run(
                "/usr/bin/git", // SAFETY: hardcoded git invocation
                arguments: ["rev-parse", "--short", "HEAD"],
                currentDirectory: root,
                environment: ProcessInfo.processInfo.environment
                    .filter { !$0.key.hasPrefix("GIT_") },
                timeout: 30
            )
            guard result.exitCode == 0 else { return "" }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Logged rather than printed: this helper is called by the JSON verbs,
            // and anything written to stdout from here lands in the middle of the
            // document they emit. The empty return is the documented fallback, but a
            // silent one turns every flip record's commit into "" with no trace.
            logger.warning("git rev-parse failed in \(root, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}

/// Cross-run flip detection: run the tests, compare this roster against the
/// stored one for the same package fingerprint, report any outcome flips.
struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Run tests and flag outcomes that flipped since the last run of identical code — scheduler-dependent behavior, not a code change."
    )

    @Argument(help: "Package root (default: current directory)")
    var path: String = "."

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        let store = TestOutcomeStore(
            directory: URL(fileURLWithPath: root).appendingPathComponent(".build/vigil"))

        print("vigil watch: running swift test…")
        let run = try TestSpawner.swiftTest(root: root)
        let roster = TestRosterParser.parse(run.output)
        guard !roster.isEmpty else {
            print("vigil: no test outcomes found in output — nothing to compare.")
            throw ExitCode(1)
        }

        let current = TestRunRecord(
            packageFingerprint: PackageFingerprint.compute(root: root),
            commit: TestSpawner.currentCommit(root: root),
            loadProxy: ProcessInfo.processInfo.activeProcessorCount,
            outcomes: roster)
        let previous = store.loadLatest(key: root)
        let flips = FlipDetector.flips(previous: previous, current: current)
        store.storeLatest(current, key: root)

        for flip in flips {
            let scope = flip.suite.isEmpty ? flip.test : "\(flip.suite).\(flip.test)"
            print("flip: '\(scope)' \(flip.previouslyPassed ? "passed" : "failed") → \(flip.nowPassed ? "passes" : "fails") with identical code (\(flip.previousCommit)…\(flip.currentCommit)) — scheduler-dependent behavior; find the window.")
        }
        print(flips.isEmpty
            ? "vigil: \(roster.count) outcomes recorded; no flips against the previous identical-code run."
            : "vigil: \(flips.count) flip(s) detected across \(roster.count) outcomes.")
        if !flips.isEmpty {
            throw ExitCode(1)
        }
    }
}

/// Intra-batch stress: run the `// TIMING:`-tagged tests N times under CPU
/// contention; any test that is not unanimous is a definitive race.
struct Stress: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stress",
        abstract: "Run // TIMING:-tagged tests N times under CPU contention — a non-unanimous outcome is a definitive race."
    )

    @Argument(help: "Package root (default: current directory)")
    var path: String = "."

    @Option(name: .long, help: "Number of identical runs")
    var runs: Int = 5

    @Flag(name: .long, help: "Report races as errors (exit 1 regardless)")
    var strict: Bool = false

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path

        // Find the self-identified timing-sensitive tests.
        var tagged: [String] = []
        let testsDir = URL(fileURLWithPath: root).appendingPathComponent("Tests")
        if let enumerator = FileManager.default.enumerator(atPath: testsDir.path) { // SAFETY: read-only walk
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".swift") else { continue }
                let file = testsDir.appendingPathComponent(relative).path
                guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { continue } // silent: unreadable test files simply are not scanned
                tagged.append(contentsOf: TimingTestScanner.timingTests(in: source))
            }
        }
        guard !tagged.isEmpty else {
            print("vigil: no // TIMING:-tagged tests found under Tests/ — nothing to stress.")
            return
        }
        print("vigil stress: \(tagged.count) timing-tagged test(s), \(runs) run(s) under contention…")

        // CPU contention: burn every core while the batch runs.
        let stopFlag = ContentionHarness.start()
        defer { ContentionHarness.stop(stopFlag) }

        let filter = tagged.joined(separator: "|")
        var rosters: [[TestOutcome]] = []
        for index in 1...runs {
            let run = try TestSpawner.swiftTest(root: root, filter: filter)
            let roster = TestRosterParser.parse(run.output)
            rosters.append(roster)
            print("  run \(index)/\(runs): \(roster.count) outcome(s), \(roster.filter { !$0.passed }.count) failure(s)")
        }

        let flips = StressAnalysis.flips(rosters: rosters)
        for diagnostic in StressAnalysis.diagnostics(for: flips, runs: runs, strict: strict) {
            print("\(strict ? "error" : "warning"): \(diagnostic.message)")
            if let fix = diagnostic.suggestedFix {
                print("    fix: \(fix)")
            }
        }
        print(flips.isEmpty
            ? "vigil: unanimous across \(runs) runs — no races surfaced."
            : "vigil: \(flips.count) definitive race(s).")
        if !flips.isEmpty {
            throw ExitCode(1)
        }
    }
}

/// Burns background threads so the stress batch runs under scheduler
/// pressure — the condition that surfaces timing races.
enum ContentionHarness {
    /// Starts one spinning thread per core; returns the stop signal.
    static func start() -> NSLock {
        let stop = NSLock()
        stop.lock()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            Thread.detachNewThread {
                var spin = 0.0
                while !stop.try() {
                    spin += 1.0.squareRoot()
                }
                stop.unlock()
            }
        }
        return stop
    }

    /// Releases the spinners.
    static func stop(_ signal: NSLock) {
        signal.unlock()
    }
}
