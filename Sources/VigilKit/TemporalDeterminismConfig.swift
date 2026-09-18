import Foundation

/// What the temporal determinism checks look at, and what they are told to ignore.
///
/// The two rules this configures catch the same underlying mistake — a wall clock reached for
/// where a deterministic value belongs — in the two places it does real damage:
///
/// - **Simulated wall clock** (`temporal-simulated-wall-clock`): a synthetic or mock type
///   stamping records with the current time. Its fixtures then differ every run, so a test
///   resting on them is only as stable as the second it happened to execute in.
/// - **Wall-clock assertion** (`temporal-wall-clock-assertion`): a test asserting on measured
///   elapsed time. That passes on a quiet machine and fails under load, and reads as a flaky
///   test rather than as the timing assumption it actually is.
///
/// The exemption lists exist because both rules have honest exceptions — a type whose whole job
/// is to read the clock, a benchmark that genuinely measures duration. They match as
/// substrings, so a short entry silences more than it looks like it should.
public struct TemporalDeterminismConfig: Sendable, Equatable {
    /// Type names (or substrings) exempt from the simulated-source rule.
    public var exemptTypes: [String]

    /// Function names exempt from the wall-clock-assertion rule.
    public var exemptFunctions: [String]

    /// File path substrings exempt from all temporal checks.
    public var exemptFiles: [String]

    /// Additional type-name substrings that mark a type as a simulated source.
    ///
    /// The built-in markers (`simulation`, `mock`, `fake`, `stub`, …) are name
    /// conventions, and a project whose fabricated sources are named by some
    /// other convention is invisible to this rule. Entries here are added to
    /// those markers, matched the same way. `exemptTypes` still wins.
    public var simulationTypes: [String]

    /// Additional argument labels that count as stamping a timestamp.
    ///
    /// The built-in labels cover the common spellings (`timestamp`, `at`,
    /// `asOf`, `observedAt`, …). A domain with its own vocabulary — `bookedOn`,
    /// `postedOn` — declares it here rather than going unchecked.
    public var timestampLabels: [String]

    /// Whether to flag wall-clock reads stamped as timestamps inside
    /// simulation/synthetic/mock types (`temporal-simulated-wall-clock`).
    public var flagSimulatedWallClock: Bool

    /// Whether to flag assertions on measured wall-clock elapsed time in tests
    /// (`temporal-wall-clock-assertion`).
    public var flagWallClockAssertion: Bool

    /// Whether to flag an ambient calendar read in production code.
    ///
    /// `Calendar.current` takes the calendar system, locale and time zone of whatever machine is
    /// running, so any component it computes moves with the deployment. `Calendar(identifier:)`
    /// is included because it *looks* fixed: it pins the calendar system and still inherits
    /// `TimeZone.current`, which is the half that reads as diligence.
    public var flagAmbientCalendar: Bool

    /// Creates a temporal determinism configuration with the given options.
    public init(
        exemptTypes: [String] = [],
        exemptFunctions: [String] = [],
        exemptFiles: [String] = [],
        simulationTypes: [String] = [],
        timestampLabels: [String] = [],
        flagSimulatedWallClock: Bool = true,
        flagWallClockAssertion: Bool = true,
        flagAmbientCalendar: Bool = true
    ) {
        self.exemptTypes = exemptTypes
        self.exemptFunctions = exemptFunctions
        self.exemptFiles = exemptFiles
        self.simulationTypes = simulationTypes
        self.timestampLabels = timestampLabels
        self.flagSimulatedWallClock = flagSimulatedWallClock
        self.flagWallClockAssertion = flagWallClockAssertion
        self.flagAmbientCalendar = flagAmbientCalendar
    }

    /// Default temporal determinism configuration.
    public static let `default` = TemporalDeterminismConfig()
}

extension TemporalDeterminismConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case exemptTypes, exemptFunctions, exemptFiles, simulationTypes, timestampLabels
        case flagSimulatedWallClock, flagWallClockAssertion, flagAmbientCalendar
    }

    /// Creates a temporal determinism configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TemporalDeterminismConfig.default
        exemptTypes = try container.decodeIfPresent([String].self, forKey: .exemptTypes) ?? defaults.exemptTypes
        exemptFunctions = try container.decodeIfPresent([String].self, forKey: .exemptFunctions) ?? defaults.exemptFunctions
        exemptFiles = try container.decodeIfPresent([String].self, forKey: .exemptFiles) ?? defaults.exemptFiles
        simulationTypes = try container.decodeIfPresent([String].self, forKey: .simulationTypes) ?? defaults.simulationTypes
        timestampLabels = try container.decodeIfPresent([String].self, forKey: .timestampLabels) ?? defaults.timestampLabels
        flagSimulatedWallClock = try container.decodeIfPresent(Bool.self, forKey: .flagSimulatedWallClock) ?? defaults.flagSimulatedWallClock
        flagWallClockAssertion = try container.decodeIfPresent(Bool.self, forKey: .flagWallClockAssertion) ?? defaults.flagWallClockAssertion
        flagAmbientCalendar = try container.decodeIfPresent(Bool.self, forKey: .flagAmbientCalendar) ?? defaults.flagAmbientCalendar
    }
}

/// Configuration for the test-outcome flip detector (within TestRunner).
///
/// The detector persists a per-package roster after each `test` run and flags any test
/// whose pass/fail outcome flips while the package fingerprint is unchanged — i.e.
