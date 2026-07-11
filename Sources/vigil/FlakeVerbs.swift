import ArgumentParser
import Foundation
import VigilKit

/// Shared spawning for the flake verbs: runs `swift test` in a project and
/// returns its combined output. Orchestration lives here in the CLI —
/// VigilKit stays pure detection.
enum TestSpawner {
    /// The result of one `swift test` invocation.
    struct RunOutput {
        /// Combined stdout+stderr.
        let output: String
        /// Whether the process exited zero.
        let succeeded: Bool
    }

    /// Runs `swift test` (optionally filtered) in `root`.
    static func swiftTest(root: String, filter: String? = nil) throws -> RunOutput {
        let process = Process() // SAFETY: hardcoded /usr/bin/env swift test
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = ["swift", "test"]
        if let filter {
            arguments += ["--filter", filter]
        }
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting — the 64 KB pipe rule.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunOutput(
            output: String(decoding: data, as: UTF8.self),
            succeeded: process.terminationStatus == 0)
    }

    /// Best-effort short commit hash for run records.
    static func currentCommit(root: String) -> String {
        let process = Process() // SAFETY: hardcoded git invocation
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--short", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("GIT_") }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
