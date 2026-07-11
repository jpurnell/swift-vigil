import ArgumentParser
import Foundation
import VigilKit
import QualityGateTypes

/// `vigil` — the flakiness & concurrency auditor.
///
/// Extracted from quality-gate-swift's war-story checkers (Phase 4,
/// move-not-fork: one implementation, two products — the quality gate
/// consumes VigilKit as a dependency). Also a first-class quality-gate
/// plugin: `contract` and `check` speak the Tier-2 plugin contract.
@main
struct Vigil: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vigil",
        abstract: "Flakiness & concurrency auditing for Swift — temporal determinism, cancellation checkpoints, flip detection, stress analysis.",
        version: "0.6.0",
        subcommands: [Scan.self, Watch.self, Stress.self, Contract.self, Check.self]
    )
}

/// The static rules over a package tree, for humans.
struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Run the static rules (temporal determinism, cancellation checkpoints) over a package."
    )

    @Argument(help: "Package root (default: current directory)")
    var path: String = "."

    @Flag(name: .long, help: "Report findings as errors instead of warnings")
    var strict: Bool = false

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        let temporal = TemporalScan.scanDirectories(root: root)
        let cancellation = CancellationScan.scanDirectories(root: root, strict: strict)

        let diagnostics = temporal.findings.diagnostics + cancellation.findings.diagnostics
        let overrides = temporal.findings.overrides + cancellation.findings.overrides

        for diagnostic in diagnostics {
            let location = [diagnostic.filePath, diagnostic.lineNumber.map(String.init)]
                .compactMap { $0 }.joined(separator: ":")
            let severity = strict ? "error" : "warning"
            print("\(location): \(severity): [\(diagnostic.ruleId ?? "vigil")] \(diagnostic.message)")
            if let fix = diagnostic.suggestedFix {
                print("    fix: \(fix)")
            }
        }
        if !overrides.isEmpty {
            print("\(overrides.count) exemption(s) acknowledged (recorded, not silent).")
        }
        for skipped in temporal.skippedFiles + cancellation.skippedFiles {
            print("skipped (unreadable): \(skipped)")
        }
        print(diagnostics.isEmpty
            ? "vigil: clean — no temporal or cancellation findings."
            : "vigil: \(diagnostics.count) finding(s).")
        if !diagnostics.isEmpty {
            throw ExitCode(1)
        }
    }
}

/// The quality-gate Tier-2 plugin handshake (Phase 4b, contract v1).
struct Contract: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contract",
        abstract: "Print the quality-gate plugin contract descriptor (JSON)."
    )

    func run() throws {
        let descriptor = PluginDescriptor(
            contractVersion: PluginContract.currentVersion,
            checkerId: "vigil",
            name: "swift-vigil",
            parallelSafe: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(decoding: try encoder.encode(descriptor), as: UTF8.self))
    }
}

/// The quality-gate Tier-2 `check` verb: a PluginCheckRequest on stdin, a
/// CheckResult on stdout — the shared vocabulary end to end.
struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Run as a quality-gate plugin: read a PluginCheckRequest (JSON) from stdin, print a CheckResult (JSON)."
    )

    func run() throws {
        let startTime = ContinuousClock.now
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let request = try JSONDecoder().decode(PluginCheckRequest.self, from: input)

        // Same tolerance policy as the host: a newer contract is a visible
        // skip, never a guess.
        guard request.contractVersion <= PluginContract.currentVersion else {
            let result = CheckResult(
                checkerId: "vigil",
                status: .skipped,
                diagnostics: [Diagnostic(
                    severity: .note,
                    message: "vigil speaks contract v\(PluginContract.currentVersion); host requested v\(request.contractVersion) — skipped, not guessed",
                    ruleId: "vigil.contract-version")],
                duration: ContinuousClock.now - startTime)
            try emit(result)
            return
        }

        // v1 config: `strict` only; everything else is reserved.
        var strict = false
        if case .object(let object) = request.config,
           case .bool(let value)? = object["strict"] {
            strict = value
        }

        let temporal = TemporalScan.scanDirectories(root: request.projectRoot)
        let cancellation = CancellationScan.scanDirectories(
            root: request.projectRoot, strict: strict)
        let diagnostics = temporal.findings.diagnostics + cancellation.findings.diagnostics
        let overrides = temporal.findings.overrides + cancellation.findings.overrides

        let status: CheckResult.Status
        if diagnostics.contains(where: { $0.severity == .error }) {
            status = .failed
        } else if diagnostics.isEmpty {
            status = .passed
        } else {
            status = .warning
        }
        let result = CheckResult(
            checkerId: "vigil",
            status: status,
            diagnostics: diagnostics,
            overrides: overrides,
            duration: ContinuousClock.now - startTime)
        try emit(result)
    }

    private func emit(_ result: CheckResult) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
