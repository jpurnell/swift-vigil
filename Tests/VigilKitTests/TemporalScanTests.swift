import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import VigilKit
import QualityGateTypes

// MARK: - Test Helpers

/// Parses a source string and runs the temporal visitor, returning diagnostics.
private func diagnose(
    _ source: String,
    filePath: String = "Sources/Thing.swift",
    config: TemporalDeterminismConfig = .default
) -> [Diagnostic] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: filePath, tree: tree)
    let visitor = TemporalVisitor(
        filePath: filePath,
        converter: converter,
        sourceLines: source.lines,
        config: config
    )
    visitor.walk(tree)
    return visitor.diagnostics
}

/// Parses a source string and returns the recorded overrides (exemptions).
private func overridesFor(
    _ source: String,
    filePath: String = "Tests/ThingTests.swift",
    config: TemporalDeterminismConfig = .default
) -> [DiagnosticOverride] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: filePath, tree: tree)
    let visitor = TemporalVisitor(
        filePath: filePath,
        converter: converter,
        sourceLines: source.lines,
        config: config
    )
    visitor.walk(tree)
    return visitor.overrides
}

private let simRule = "temporal-simulated-wall-clock"
private let assertRule = "temporal-wall-clock-assertion"

// The checker-identity test stayed in quality-gate-swift with the
// QualityChecker wrapper — vigil owns the engine, not the gate adapter.

// MARK: - Rule 1: simulated wall-clock timestamps

@Suite("TemporalDeterminismAuditor: temporal-simulated-wall-clock")
struct SimulatedWallClockTests {
    @Test("Flags the exact SimulationDevice regression shape")
    func flagsSimulationDeviceTimestamp() {
        let code = """
        actor SimulationDevice {
            func generateNextSample(at elapsedSeconds: Double) -> BioSample {
                return BioSample(rrInterval: rr, timestamp: ContinuousClock.now)
            }
        }
        """
        #expect(diagnose(code).contains { $0.ruleId == simRule })
    }

    @Test("Flags Date() stamped as timestamp in a Mock type")
    func flagsMockDate() {
        let code = """
        struct MockClock {
            func emit() -> Event { Event(at: Date()) }
        }
        """
        #expect(diagnose(code).contains { $0.ruleId == simRule })
    }

    @Test("Flags property assignment of wall-clock time in a Synthetic type")
    func flagsSyntheticAssignment() {
        let code = """
        final class SyntheticSource {
            var timestamp = ContinuousClock.now
            func tick() { self.timestamp = ContinuousClock.now }
        }
        """
        #expect(diagnose(code).contains { $0.ruleId == simRule })
    }

    @Test("Flags a type that conforms to a simulation-named protocol")
    func flagsSimulationConformance() {
        let code = """
        struct FastDevice: SimulatedDevice {
            func next() -> Sample { Sample(time: ContinuousClock.now) }
        }
        """
        #expect(diagnose(code).contains { $0.ruleId == simRule })
    }

    // MARK: Must NOT flag

    @Test("Does not flag a real (non-simulated) device")
    func ignoresRealDevice() {
        let code = """
        actor PolarDevice {
            func read() -> BioSample { BioSample(rrInterval: rr, timestamp: ContinuousClock.now) }
        }
        """
        #expect(diagnose(code).isEmpty)
    }

    @Test("Does not flag logical-origin timestamps in a simulation type")
    func ignoresLogicalOrigin() {
        let code = """
        actor SimulationDevice {
            func sample(origin: ContinuousClock.Instant, elapsed: Double) -> BioSample {
                let timestamp = origin.advanced(by: .milliseconds(Int(elapsed * 1000)))
                return BioSample(rrInterval: rr, timestamp: timestamp)
            }
        }
        """
        #expect(diagnose(code).isEmpty)
    }

    @Test("Respects // temporal:exempt")
    func respectsExemptComment() {
        let code = """
        actor SimulationDevice {
            func s() -> BioSample {
                BioSample(rrInterval: rr, timestamp: ContinuousClock.now) // temporal:exempt
            }
        }
        """
        #expect(diagnose(code).isEmpty)
        #expect(overridesFor(code, filePath: "Sources/S.swift").contains { $0.ruleId == simRule })
    }

    @Test("Respects config.exemptTypes")
    func respectsExemptTypes() {
        let code = """
        actor SimulationDevice {
            func s() -> BioSample { BioSample(rrInterval: rr, timestamp: ContinuousClock.now) }
        }
        """
        let cfg = TemporalDeterminismConfig(exemptTypes: ["SimulationDevice"])
        #expect(diagnose(code, config: cfg).isEmpty)
    }
}

// MARK: - Rule 2: wall-clock timing assertions

@Suite("TemporalDeterminismAuditor: temporal-wall-clock-assertion")
struct WallClockAssertionTests {
    private let testPath = "Tests/PerfTests.swift"

    @Test("Flags #expect on an elapsed-time variable")
    func flagsElapsedVar() {
        let code = """
        @Test func perf() {
            let start = ContinuousClock.now
            doWork()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1))
        }
        """
        #expect(diagnose(code, filePath: testPath).contains { $0.ruleId == assertRule })
    }

    @Test("Flags inline Date().timeIntervalSince threshold")
    func flagsInlineTimeInterval() {
        let code = """
        func testSpeed() {
            let start = Date()
            run()
            #expect(Date().timeIntervalSince(start) < 0.5)
        }
        """
        #expect(diagnose(code, filePath: testPath).contains { $0.ruleId == assertRule })
    }

    @Test("Flags XCTAssertLessThan on elapsed duration")
    func flagsXCTAssertLessThan() {
        let code = """
        func testBudget() {
            let start = ContinuousClock.now
            work()
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(2))
        }
        """
        #expect(diagnose(code, filePath: testPath).contains { $0.ruleId == assertRule })
    }

    // MARK: Must NOT flag

    @Test("Does not flag assertions on logical timestamp ordering")
    func ignoresLogicalTimestampAssertion() {
        let code = """
        @Test func monotonic() {
            for i in 1..<samples.count {
                #expect(samples[i].timestamp > samples[i - 1].timestamp)
            }
        }
        """
        #expect(diagnose(code, filePath: testPath).isEmpty)
    }

    @Test("Does not flag a plain value assertion")
    func ignoresPlainAssertion() {
        let code = """
        @Test func math() {
            #expect(result == 42)
            #expect(count < 100)
        }
        """
        #expect(diagnose(code, filePath: testPath).isEmpty)
    }

    @Test("Respects // TIMING: on the assertion line")
    func respectsTimingComment() {
        let code = """
        func testPerf() {
            let start = ContinuousClock.now
            work()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1)) // TIMING: intentional load benchmark
        }
        """
        #expect(diagnose(code, filePath: testPath).isEmpty)
        #expect(overridesFor(code, filePath: testPath).contains { $0.ruleId == assertRule })
    }
}

// MARK: - Rule 1: which argument labels count as a timestamp

@Suite("TemporalDeterminismAuditor: timestamp label matching")
struct TimestampLabelTests {

    /// Wraps a call in a simulation type so only the label varies.
    private func inSimType(_ call: String) -> String {
        """
        struct SimulationProbe {
            func make() { _ = Thing(\(call)) }
        }
        """
    }

    @Test("Flags asOf:, the common spelling for a business-time stamp",
          arguments: ["asOf: Date()", "valuationDate: Date()", "observedAt: Date()",
                      "recordedAt: Date()", "effective: Date()"])
    func flagsBusinessTimeLabels(_ call: String) {
        #expect(diagnose(inSimType(call)).contains { $0.ruleId == simRule })
    }

    @Test("Does not flag labels that merely contain 'time' or end in 'at'",
          arguments: ["format: Date()", "heartbeat: Date()", "timeout: Date()",
                      "timeGrid: Date()", "flat: Date()", "repeatCount: Date()"])
    func ignoresIncidentalLabels(_ call: String) {
        #expect(diagnose(inSimType(call)).isEmpty)
    }

    @Test("Still flags the established labels",
          arguments: ["at: Date()", "time: Date()", "date: Date()", "timestamp: Date()",
                      "executedAt: Date()", "startTime: Date()", "createdDate: Date()",
                      "when: Date()", "instant: Date()", "moment: Date()"])
    func flagsEstablishedLabels(_ call: String) {
        #expect(diagnose(inSimType(call)).contains { $0.ruleId == simRule })
    }

    @Test("config.timestampLabels adds a project's own spelling")
    func honorsConfiguredLabels() {
        let code = inSimType("bookedOn: Date()")
        #expect(diagnose(code).isEmpty)
        let cfg = TemporalDeterminismConfig(timestampLabels: ["bookedOn"])
        #expect(diagnose(code, config: cfg).contains { $0.ruleId == simRule })
    }
}

// MARK: - Rule 1: which types count as simulated

@Suite("TemporalDeterminismAuditor: simulation type matching")
struct SimulationTypeTests {

    @Test("config.simulationTypes declares a project's own simulated sources")
    func honorsConfiguredTypes() {
        let code = """
        struct PriceFeedDouble {
            func emit() { _ = Sample(timestamp: Date()) }
        }
        """
        #expect(diagnose(code).isEmpty)
        let cfg = TemporalDeterminismConfig(simulationTypes: ["FeedDouble"])
        #expect(diagnose(code, config: cfg).contains { $0.ruleId == simRule })
    }

    @Test("A configured type name still loses to exemptTypes")
    func exemptTypesWinsOverConfigured() {
        let code = """
        struct PriceFeedDouble {
            func emit() { _ = Sample(timestamp: Date()) }
        }
        """
        let cfg = TemporalDeterminismConfig(
            exemptTypes: ["PriceFeedDouble"],
            simulationTypes: ["FeedDouble"]
        )
        #expect(diagnose(code, config: cfg).isEmpty)
    }
}

// MARK: - Rule 1: the message must describe the harm that is actually present

@Suite("TemporalDeterminismAuditor: diagnostic message accuracy")
struct MessageAccuracyTests {

    @Test("A stamp inside a loop is reported as sample-spacing jitter")
    func loopStampMentionsSpacing() {
        let code = """
        struct SimulationFeed {
            func run() {
                for _ in 0..<10 {
                    emit(Sample(timestamp: Date()))
                }
            }
        }
        """
        let message = diagnose(code).first { $0.ruleId == simRule }?.message ?? ""
        #expect(message.contains("spacing"))
    }

    @Test("A single stamp is reported as non-reproducibility, not as spacing")
    func singleStampMentionsReproducibility() {
        let code = """
        struct SimulationRun {
            func finish() -> Metadata { Metadata(seed: seed, timestamp: Date()) }
        }
        """
        let message = diagnose(code).first { $0.ruleId == simRule }?.message ?? ""
        #expect(message.contains("reproducib"))
        #expect(!message.contains("spacing"))
    }
}
