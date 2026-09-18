import Foundation
import Testing
import QualityGateTypes
@testable import VigilKit

/// `temporal-ambient-calendar` — the calendar half of wall-clock nondeterminism.
///
/// Every "must flag" fixture below is a real production defect found in one week, and every
/// "must not flag" fixture is real code that pins its zone correctly. The carve-outs are not
/// hypotheses: an earlier version of them, in a sibling checker, reported eleven findings against
/// a suite that was doing the safest possible thing.
@Suite("temporal-ambient-calendar")
struct AmbientCalendarRuleTests {

    private func findings(_ source: String, path: String = "/proj/Sources/Lib/File.swift") -> [Diagnostic] {
        TemporalScan.scanSource(source, fileName: path)
            .diagnostics.filter { $0.ruleId == "temporal-ambient-calendar" }
    }

    // MARK: - Must flag

    @Test("Calendar.current in production")
    func flagsCurrent() {
        // TimeDecayCalculator: an application's decay weight, and so its ranking, differed by
        // the time zone the tool ran in.
        let source = """
        import Foundation

        enum TimeDecay {
            static func weight(from applicationDate: Date) -> Int {
                Calendar.current.dateComponents([.day], from: applicationDate, to: Date()).day ?? 0
            }
        }
        """
        #expect(findings(source).count == 1)
    }

    @Test("Calendar(identifier:) with no zone — the one that looks fixed")
    func flagsIdentifierInitialiser() {
        let source = """
        import Foundation

        enum Fiscal {
            static func year(of date: Date) -> Int {
                let calendar = Calendar(identifier: .gregorian)
                return calendar.component(.year, from: date)
            }
        }
        """
        #expect(findings(source).count == 1)
    }

    @Test("A component read straight off the ambient calendar")
    func flagsInlineComponentRead() {
        // InternationalDateFormatting: a January date could render as the previous year.
        let source = """
        import Foundation

        enum Render {
            static func year(of date: Date) -> Int { Calendar.current.component(.year, from: date) }
        }
        """
        #expect(findings(source).count == 1)
    }

    @Test("Each reading is reported once")
    func flagsEachReading() {
        let source = """
        import Foundation

        enum Two {
            static func go(_ d: Date) -> (Int, Int) {
                let a = Calendar.current
                let b = Calendar(identifier: .iso8601)
                return (a.component(.year, from: d), b.component(.year, from: d))
            }
        }
        """
        #expect(findings(source).count == 2)
    }

    // MARK: - Must not flag

    @Test("A zone pinned by the next statement")
    func ignoresPinnedNextStatement() {
        let source = """
        import Foundation

        enum DayCount {
            static func go(_ d: Date) -> Int {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
                return calendar.component(.year, from: d)
            }
        }
        """
        #expect(findings(source).isEmpty)
    }

    @Test("A zone pinned inside a branch")
    func ignoresPinnedInBranch() {
        // TimeZone's initialisers are failable and careful projects do not force-unwrap.
        let source = """
        import Foundation

        enum DayCount {
            static func go(_ d: Date) -> Int {
                var utc = Calendar(identifier: .gregorian)
                if let zone = TimeZone(secondsFromGMT: 0) { utc.timeZone = zone }
                return utc.component(.year, from: d)
            }
        }
        """
        #expect(findings(source).isEmpty)
    }

    @Test("A zone pinned as a sibling argument — the safest form")
    func ignoresPinnedBySibling() {
        // SwiftZIP's DOSTime encoding. The calendar never exists with an unset zone, and an
        // earlier version of this carve-out reported eleven findings against it.
        let source = """
        import Foundation

        enum DOSTime {
            static func known() -> Date? {
                DateComponents(
                    calendar: Calendar(identifier: .gregorian),
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2026, month: 6, day: 2
                ).date
            }
        }
        """
        #expect(findings(source).isEmpty)
    }

    @Test("Calendar.current gets no carve-out, even with a zone assigned")
    func currentIsNeverPinned() {
        // Pinning a zone fixes half an ambient calendar. The system is still the runner's, and
        // a Japanese or Buddhist locale returns a different year for the same instant.
        let source = """
        import Foundation

        enum Half {
            static func go(_ d: Date) -> Int {
                var calendar = Calendar.current
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
                return calendar.component(.year, from: d)
            }
        }
        """
        #expect(findings(source).count == 1)
    }

    @Test("A named fixed calendar is not a Calendar reference")
    func ignoresNamedFixture() {
        let source = """
        import Foundation

        enum Fiscal {
            static func go(_ d: Date) -> Int { gregorianUTC.component(.year, from: d) }
        }
        """
        #expect(findings(source).isEmpty)
    }

    // MARK: - Scope and suppression

    @Test("Tests are not this rule's business")
    func ignoresTestFiles() {
        // test-quality's ambient-calendar-in-test owns that tree. Reporting the same line from
        // two rules would make one of them wrong.
        let source = """
        import Foundation

        enum T { static func go(_ d: Date) -> Int { Calendar.current.component(.year, from: d) } }
        """
        #expect(findings(source, path: "/proj/Tests/LibTests/File.swift").isEmpty)
    }

    @Test("temporal:exempt suppresses and is recorded")
    func exemptionIsRecorded() {
        let source = """
        import Foundation

        enum Local {
            static func go(_ d: Date) -> Int {
                // temporal:exempt — this reports what the user's own calendar says, on purpose
                Calendar.current.component(.year, from: d)
            }
        }
        """
        let scan = TemporalScan.scanSource(source, fileName: "/proj/Sources/Lib/File.swift")
        #expect(scan.diagnostics.filter { $0.ruleId == "temporal-ambient-calendar" }.isEmpty)
        #expect(scan.overrides.contains { $0.ruleId == "temporal-ambient-calendar" })
    }

    @Test("A DateFormatter whose zone was pinned two lines earlier")
    func ignoresPinBeforeAssignment() {
        // Three findings in quality-gate-swift's own Sources/ against exactly this shape. The
        // formatter already exists when the calendar lands on it, so the pin is allowed to come
        // first — and in the idiom it always does, because `dateFormat`/`timeZone`/`locale` read
        // naturally in that order.
        let source = """
        import Foundation

        enum Today {
            static func iso() -> String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                return formatter.string(from: Date())
            }
        }
        """
        #expect(findings(source).isEmpty)
    }

    @Test("Widening the scan is not a blanket pass for member assignment")
    func flagsUnpinnedReceiver() {
        // The pin may now come from either side of the assignment — but it still has to exist.
        // Without this, "assigned into a receiver" would itself become the carve-out.
        let source = """
        import Foundation

        enum Today {
            static func iso() -> String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                return formatter.string(from: Date())
            }
        }
        """
        #expect(findings(source).count == 1)
    }

    @Test("The toggle turns it off")
    func respectsToggle() {
        var config = TemporalDeterminismConfig.default
        config.flagAmbientCalendar = false
        let source = """
        import Foundation

        enum T { static func go(_ d: Date) -> Int { Calendar.current.component(.year, from: d) } }
        """
        let scan = TemporalScan.scanSource(source, fileName: "/proj/Sources/Lib/F.swift", config: config)
        #expect(scan.diagnostics.filter { $0.ruleId == "temporal-ambient-calendar" }.isEmpty)
    }
}
