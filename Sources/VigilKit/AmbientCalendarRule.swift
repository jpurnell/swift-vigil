import Foundation
import SwiftSyntax

/// `temporal-ambient-calendar` — production code whose date arithmetic moves with the machine.
///
/// The sibling rules here are about the *clock*. This one is about the *calendar*, which fails
/// the same way and is harder to see: a wall-clock read looks like a wall-clock read, while
/// `Calendar.current` looks like the obvious way to get a calendar.
///
/// ## What it flags, and why the second one matters more
///
/// - `Calendar.current` — takes the calendar system, locale and time zone of whatever machine is
///   running. A component read through it is a different number in a different deployment.
/// - `Calendar(identifier: .gregorian)` — pins the calendar *system* and inherits
///   `TimeZone.current`. This is the dangerous one: pinning the identifier reads as diligence, so
///   the site survives review, and every component it computes still moves with the runner.
///
/// ## Measured, not theorised
///
/// Four defects found in one week, each in code written by someone who knew about time zones:
///
/// - An application's decay weight — and therefore its ranking — differed by time zone, because
///   "days since" was counted through `Calendar.current`.
/// - "Years of experience" could land a month either side, from an unpinned parse feeding an
///   unpinned diff.
/// - A January date rendered as the previous year, parsed in one zone and read back in another.
/// - A simulation's period boundaries landed one step early west of Greenwich.
///
/// Three of the four were found through a *test* that mirrored the production call, by a rule
/// that only scanned `Tests/` and could not see the original. This rule exists to look where the
/// defect is.
///
/// ## The carve-outs, all of them earned
///
/// A calendar whose zone is pinned is not ambient, and the corpus pins it three ways:
///
/// 1. **A later statement in the same block** — `var c = Calendar(identifier:)` then
///    `c.timeZone = …`. There is no initialiser taking both, so this is the idiom.
/// 2. **Inside a branch** — `if let zone = TimeZone(secondsFromGMT: 0) { c.timeZone = zone }`,
///    because those initialisers are failable and careful projects do not force-unwrap.
/// 3. **A sibling argument of the same call** —
///    `DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: …)`. This is the
///    *safest* form, since the value never exists unpinned, and a first version of these
///    carve-outs missed it and reported eleven findings against exemplary code.
/// 4. **An earlier statement, when the calendar is assigned into something that already exists**
///    — `formatter.timeZone = …` then `formatter.calendar = Calendar(identifier:)`. Carve-out 1
///    only looks forward, which is right for a fresh `var`: a pin cannot precede the value it
///    pins. A receiver has no such constraint, and the `DateFormatter` idiom sets the zone first.
///    Scanning forward only reported three findings against this repository's own `Sources/`.
///
/// `Calendar.current` gets none of them. Pinning a zone fixes half an ambient calendar; the
/// system is still the runner's, and a Japanese or Buddhist locale returns a different year for
/// the same instant.
enum AmbientCalendarRule {

    /// How the calendar was obtained.
    enum Reading {
        /// `Calendar.current`.
        case current
        /// `Calendar(identifier:)` with no time zone pinned.
        case identifierInitialiser

        var message: String {
            switch self {
            case .current:
                return "Calendar.current takes the calendar system, locale and time zone of whatever machine runs this, so any component it computes moves with the deployment."
            case .identifierInitialiser:
                return "Calendar(identifier:) fixes the calendar system and still inherits TimeZone.current, so its date arithmetic depends on where this runs."
            }
        }
    }

    /// Whether a reference to `Calendar` reads the ambient one.
    ///
    /// Both spellings are found from the `Calendar` reference itself, by asking what encloses it.
    static func reading(at node: DeclReferenceExprSyntax) -> Reading? {
        guard node.baseName.text == "Calendar" else { return nil }
        let reference = Syntax(node).id

        if let member = node.parent?.as(MemberAccessExprSyntax.self),
           member.base?.id == reference,
           member.declName.baseName.text == "current" {
            return .current
        }

        if let call = node.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == reference,
           call.arguments.contains(where: { $0.label?.text == "identifier" }),
           !isPinned(call) {
            return .identifierInitialiser
        }

        return nil
    }

    /// Whether this `Calendar(identifier:)` has its time zone pinned nearby.
    private static func isPinned(_ call: FunctionCallExprSyntax) -> Bool {
        if pinnedBySiblingArgument(call) { return true }

        guard let binding = boundName(of: call),
              let item = enclosingStatement(of: call),
              let siblings = item.parent?.as(CodeBlockItemListSyntax.self) else {
            return false
        }
        var reached = false
        let scan = TimeZonePinScanner(name: binding.name, viewMode: .sourceAccurate)
        for sibling in siblings {
            if sibling.id == item.id { reached = true; continue }
            // A fresh `var c = Calendar(…)` can only be pinned after it exists, so an earlier
            // `c.timeZone` is a different `c`. A receiver that was already there — `formatter`
            // in `formatter.calendar = Calendar(…)` — may have been pinned on either side, and
            // the DateFormatter idiom pins the zone first. Scanning forward only reported three
            // findings against code that sets `timeZone`, `locale` and `calendar` in that order.
            guard reached || binding.receiverPreexists else { continue }
            scan.walk(sibling)
            if scan.found { return true }
        }
        return false
    }

    /// `DateComponents(calendar: Calendar(identifier:), timeZone: …)` — pinned in one expression.
    private static func pinnedBySiblingArgument(_ call: FunctionCallExprSyntax) -> Bool {
        guard let argument = call.parent?.as(LabeledExprSyntax.self),
              let list = argument.parent?.as(LabeledExprListSyntax.self),
              let enclosing = list.parent?.as(FunctionCallExprSyntax.self) else {
            return false
        }
        return enclosing.arguments.contains { $0.label?.text == "timeZone" }
    }

    /// The name a pin would have to target, and whether that name predates this statement.
    private struct Binding {
        /// The identifier `<name>.timeZone = …` would have to name.
        let name: String
        /// True when the calendar is assigned *into* something that already existed.
        let receiverPreexists: Bool
    }

    /// The name this calendar is bound to, or assigned into.
    private static func boundName(of call: FunctionCallExprSyntax) -> Binding? {
        if let initializer = call.parent?.as(InitializerClauseSyntax.self),
           let binding = initializer.parent?.as(PatternBindingSyntax.self),
           let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
            return Binding(name: pattern.identifier.text, receiverPreexists: false)
        }
        guard let sequence = call.parent?.as(ExprListSyntax.self)?
                .parent?.as(SequenceExprSyntax.self) else { return nil }
        let elements = Array(sequence.elements)
        guard elements.count >= 3,
              elements[1].is(AssignmentExprSyntax.self),
              elements.last?.id == ExprSyntax(call).id,
              let member = elements[0].as(MemberAccessExprSyntax.self),
              let base = member.base?.as(DeclReferenceExprSyntax.self) else { return nil }
        return Binding(name: base.baseName.text, receiverPreexists: true)
    }

    /// The statement a node belongs to. Terminates at the root.
    private static func enclosingStatement(of node: some SyntaxProtocol) -> CodeBlockItemSyntax? {
        var current: Syntax? = Syntax(node)
        while let candidate = current {
            if let item = candidate.as(CodeBlockItemSyntax.self) { return item }
            current = candidate.parent
        }
        return nil
    }

    /// Looks for `<name>.timeZone = …` anywhere in the statements it walks.
    ///
    /// The whole subtree, not just the top level, because the pin is often inside an `if let` —
    /// `TimeZone(secondsFromGMT:)` is failable and the projects that pin zones are the same ones
    /// that refuse to force-unwrap.
    private final class TimeZonePinScanner: SyntaxVisitor {
        let name: String
        private(set) var found = false

        init(name: String, viewMode: SyntaxTreeViewMode) {
            self.name = name
            super.init(viewMode: viewMode)
        }

        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            let elements = Array(node.elements)
            if elements.count >= 2, elements[1].is(AssignmentExprSyntax.self), targets(elements[0]) {
                found = true
            }
            return .visitChildren
        }

        override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            if node.operator.is(AssignmentExprSyntax.self), targets(node.leftOperand) { found = true }
            return .visitChildren
        }

        private func targets(_ expr: ExprSyntax) -> Bool {
            guard let member = expr.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "timeZone",
                  let base = member.base?.as(DeclReferenceExprSyntax.self) else { return false }
            return base.baseName.text == name
        }
    }
}
