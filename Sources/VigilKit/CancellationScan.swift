import Foundation
import QualityGateTypes
import SwiftSyntax
import SwiftParser

/// The cancellation-checkpoint-after-loop rule, standalone (Phase 4
/// extraction; the war story: a `for await` loop ends *quietly* on
/// cancellation — no throw — so code after the loop runs in a state that
/// depends on *why* the loop exited).
///
/// Rule (`concurrency.cancellation-checkpoint-after-loop`): in a function
/// that demonstrably treats cancellation as semantic (it references
/// `Task.checkCancellation` / `Task.isCancelled` somewhere), a `for await`
/// loop whose following statements run without an intervening cancellation
/// check is flagged. `defer` blocks are exempt (they run on every path).
///
/// Escape hatch: `// concurrency:exempt` on the loop line or the line
/// above — recorded as an override, never silent.
public enum CancellationScan {

    /// One scan's findings.
    public struct Findings: Sendable {
        /// Rule diagnostics found.
        public let diagnostics: [Diagnostic]
        /// Exemption markers encountered (acknowledged suppressions).
        public let overrides: [DiagnosticOverride]
    }

    /// Scans one source string.
    ///
    /// - Parameters:
    ///   - source: Swift source to analyze.
    ///   - fileName: Path used in emitted diagnostics.
    ///   - strict: Emit `.error` instead of `.warning`.
    /// - Returns: The findings.
    public static func scanSource(
        _ source: String,
        fileName: String,
        strict: Bool = false
    ) -> Findings {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = CancellationCheckpointVisitor(
            fileName: fileName,
            converter: converter,
            sourceLines: source.components(separatedBy: "\n"),
            strict: strict
        )
        visitor.walk(tree)
        return Findings(diagnostics: visitor.diagnostics, overrides: visitor.overrides)
    }
}

/// The single-rule visitor behind ``CancellationScan``.
///
/// State tracking mirrors the original in-gate implementation exactly: the
/// cancellation-usage flag is pushed per function/initializer/deinitializer
/// body (closures inherit their enclosing declaration's flag).
final class CancellationCheckpointVisitor: SyntaxVisitor {
    private let fileName: String
    private let converter: SourceLocationConverter
    private let sourceLines: [String]
    private let strict: Bool

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    /// Stack of "does the enclosing function-like body use a cancellation
    /// checkpoint" flags, one per nested function/init/deinit.
    private var functionCancellationStack: [Bool] = []

    private var currentFunctionUsesCancellation: Bool {
        functionCancellationStack.last ?? false
    }

    init(
        fileName: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        strict: Bool
    ) {
        self.fileName = fileName
        self.converter = converter
        self.sourceLines = sourceLines
        self.strict = strict
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Function-like scopes

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functionCancellationStack.append(bodyUsesCancellation(node.body))
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        functionCancellationStack.removeLast()
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        functionCancellationStack.append(bodyUsesCancellation(node.body))
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) {
        functionCancellationStack.removeLast()
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        functionCancellationStack.append(bodyUsesCancellation(node.body))
        return .visitChildren
    }
    override func visitPost(_ node: DeinitializerDeclSyntax) {
        functionCancellationStack.removeLast()
    }

    // MARK: The rule

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        // Only `for await` / `for try await` loops can exit silently on cancellation.
        guard node.awaitKeyword != nil else { return .visitChildren }
        // Scope to functions that demonstrably treat cancellation as semantic.
        guard currentFunctionUsesCancellation else { return .visitChildren }

        let loopLine = startLine(of: Syntax(node))

        // Escape hatch: `// concurrency:exempt` on (or just above) the loop line.
        if lineHasCancellationExempt(loopLine) {
            overrides.append(DiagnosticOverride(
                ruleId: "concurrency.cancellation-checkpoint-after-loop",
                justification: "// concurrency:exempt",
                filePath: fileName,
                lineNumber: loopLine
            ))
            return .visitChildren
        }

        if loopReachesDependentCodeWithoutCheck(node) {
            diagnostics.append(Diagnostic(
                severity: strict ? .error : .warning,
                message: "cancelled iteration ends quietly (nil), not by throwing — a loop exit is a stage boundary; check cancellation before exit-reason-dependent code",
                filePath: fileName,
                lineNumber: loopLine,
                columnNumber: 1,
                ruleId: "concurrency.cancellation-checkpoint-after-loop",
                suggestedFix: "Insert `try Task.checkCancellation()` immediately after the loop, before any code whose correctness depends on why the loop exited."
            ))
        }
        return .visitChildren
    }

    // MARK: Helpers (verbatim semantics from the original)

    /// True if the given function-like body references a cancellation
    /// checkpoint (`Task.checkCancellation()` call or `Task.isCancelled`
    /// read) anywhere.
    private func bodyUsesCancellation(_ body: CodeBlockSyntax?) -> Bool {
        guard let body else { return false }
        return syntaxReferencesCancellation(Syntax(body))
    }

    /// True if `node`'s subtree contains a `Task.checkCancellation` or
    /// `Task.isCancelled` member access. Precise (AST) — ignores the same
    /// words in strings/comments.
    private func syntaxReferencesCancellation(_ node: Syntax) -> Bool {
        final class Detector: SyntaxVisitor {
            var found = false
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                let member = node.declName.baseName.text
                if member == "isCancelled" || member == "checkCancellation",
                   let base = node.base?.as(DeclReferenceExprSyntax.self),
                   base.baseName.text == "Task" {
                    found = true
                }
                return .visitChildren
            }
        }
        let detector = Detector(viewMode: .sourceAccurate)
        detector.walk(node)
        return detector.found
    }

    /// Walks the statements that follow `loop` in its enclosing block.
    /// Returns true if the first non-`defer` statement is reached without an
    /// intervening cancellation check — i.e. exit-reason-dependent code runs
    /// on the silent cancellation path.
    private func loopReachesDependentCodeWithoutCheck(_ loop: ForStmtSyntax) -> Bool {
        guard let item = loop.parent?.as(CodeBlockItemSyntax.self),
              let list = item.parent?.as(CodeBlockItemListSyntax.self) else { return false }
        var afterLoop = false
        for sibling in list {
            if !afterLoop {
                if sibling.id == item.id { afterLoop = true }
                continue
            }
            // `defer` runs on every exit path — pure cleanup, allowed before a check.
            if case .stmt(let stmt) = sibling.item, stmt.is(DeferStmtSyntax.self) { continue }
            // A cancellation check (guard/if on isCancelled, or checkCancellation) makes the tail safe.
            if syntaxReferencesCancellation(Syntax(sibling)) { return false }
            // First exit-reason-dependent statement reached with no check.
            return true
        }
        return false
    }

    /// True if the loop line (or the line directly above) carries
    /// `// concurrency:exempt`.
    private func lineHasCancellationExempt(_ line: Int) -> Bool {
        for index in [line - 1, line - 2] where index >= 0 && index < sourceLines.count {
            if sourceLines[index].contains("// concurrency:exempt") { return true }
        }
        return false
    }

    /// 1-based start line of a node.
    private func startLine(of node: Syntax) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
}
