import Foundation
import QualityGateTypes
import SwiftSyntax
import SwiftParser

/// The temporal-determinism engine: wall-clock nondeterminism in places
/// where results must be reproducible.
///
/// Rules:
/// - `temporal-simulated-wall-clock` — a simulation/synthetic/mock type
///   stamps a wall-clock read (`ContinuousClock.now`, `Date()`, …) as a
///   timestamp value. Simulated data must derive time from a logical origin,
///   or its output spacing tracks scheduler jitter instead of the intended
///   interval.
/// - `temporal-wall-clock-assertion` — a test asserts on *measured elapsed
///   wall-clock time* against a numeric threshold, which flakes under load.
///
/// Suppression: `// temporal:exempt` on a line suppresses temporal
/// diagnostics there; `// TIMING:` declares an intentional wall-clock
/// performance test (exempts the assertion rule — and enrolls the test in
/// vigil's stress runs).
public enum TemporalScan {

    /// One scan's findings: diagnostics plus the recorded exemptions.
    public struct Findings: Sendable {
        /// Temporal diagnostics found.
        public let diagnostics: [Diagnostic]
        /// Exemption markers encountered (acknowledged suppressions).
        public let overrides: [DiagnosticOverride]
    }

    /// Scans one source string. The `fileName` decides which rule runs: a
    /// path containing `/Tests/` runs the assertion rule, otherwise the
    /// simulated-source rule.
    ///
    /// - Parameters:
    ///   - source: Swift source to analyze.
    ///   - fileName: Path used in emitted diagnostics (and rule selection).
    ///   - config: Rule toggles and exemptions.
    /// - Returns: The findings.
    public static func scanSource(
        _ source: String,
        fileName: String,
        config: TemporalDeterminismConfig = .default
    ) -> Findings {
        let sourceLines = source.components(separatedBy: "\n")
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = TemporalVisitor(
            filePath: fileName,
            converter: converter,
            sourceLines: sourceLines,
            config: config
        )
        visitor.walk(tree)
        return Findings(diagnostics: visitor.diagnostics, overrides: visitor.overrides)
    }

    /// Scans every `.swift` file under `directories` (relative to `root`),
    /// honoring `config.exemptFiles`. Unreadable files are skipped and
    /// reported in `skippedFiles` — a scan never throws.
    ///
    /// - Parameters:
    ///   - root: Project root.
    ///   - directories: Subdirectories to walk (default `Sources` + `Tests`).
    ///   - config: Rule toggles and exemptions.
    /// - Returns: Combined findings plus any unreadable file paths.
    public static func scanDirectories(
        root: String,
        directories: [String] = ["Sources", "Tests"],
        config: TemporalDeterminismConfig = .default
    ) -> (findings: Findings, skippedFiles: [String]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        var skipped: [String] = []

        for dir in directories {
            let path = (root as NSString).appendingPathComponent(dir)
            guard fileManager.fileExists(atPath: path) else { continue } // SAFETY: read-only walk of the analyzed project
            guard let enumerator = fileManager.enumerator(atPath: path) else { continue }
            while let relativePath = enumerator.nextObject() as? String {
                guard relativePath.hasSuffix(".swift") else { continue }
                let fullPath = (path as NSString).appendingPathComponent(relativePath)
                if config.exemptFiles.contains(where: { fullPath.contains($0) }) { continue }
                do {
                    let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                    let findings = scanSource(source, fileName: fullPath, config: config)
                    diagnostics.append(contentsOf: findings.diagnostics)
                    overrides.append(contentsOf: findings.overrides)
                } catch {
                    skipped.append(fullPath)
                }
            }
        }
        return (Findings(diagnostics: diagnostics, overrides: overrides), skipped)
    }
}
