import Foundation

public struct TemporalDeterminismConfig: Sendable, Equatable {
    /// Type names (or substrings) exempt from the simulated-source rule.
    public var exemptTypes: [String]

    /// Function names exempt from the wall-clock-assertion rule.
    public var exemptFunctions: [String]

    /// File path substrings exempt from all temporal checks.
    public var exemptFiles: [String]

    /// Whether to flag wall-clock reads stamped as timestamps inside
    /// simulation/synthetic/mock types (`temporal-simulated-wall-clock`).
    public var flagSimulatedWallClock: Bool

    /// Whether to flag assertions on measured wall-clock elapsed time in tests
    /// (`temporal-wall-clock-assertion`).
    public var flagWallClockAssertion: Bool

    /// Creates a temporal determinism configuration with the given options.
    public init(
        exemptTypes: [String] = [],
        exemptFunctions: [String] = [],
        exemptFiles: [String] = [],
        flagSimulatedWallClock: Bool = true,
        flagWallClockAssertion: Bool = true
    ) {
        self.exemptTypes = exemptTypes
        self.exemptFunctions = exemptFunctions
        self.exemptFiles = exemptFiles
        self.flagSimulatedWallClock = flagSimulatedWallClock
        self.flagWallClockAssertion = flagWallClockAssertion
    }

    /// Default temporal determinism configuration.
    public static let `default` = TemporalDeterminismConfig()
}

extension TemporalDeterminismConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case exemptTypes, exemptFunctions, exemptFiles, flagSimulatedWallClock, flagWallClockAssertion
    }

    /// Creates a temporal determinism configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TemporalDeterminismConfig.default
        exemptTypes = try container.decodeIfPresent([String].self, forKey: .exemptTypes) ?? defaults.exemptTypes
        exemptFunctions = try container.decodeIfPresent([String].self, forKey: .exemptFunctions) ?? defaults.exemptFunctions
        exemptFiles = try container.decodeIfPresent([String].self, forKey: .exemptFiles) ?? defaults.exemptFiles
        flagSimulatedWallClock = try container.decodeIfPresent(Bool.self, forKey: .flagSimulatedWallClock) ?? defaults.flagSimulatedWallClock
        flagWallClockAssertion = try container.decodeIfPresent(Bool.self, forKey: .flagWallClockAssertion) ?? defaults.flagWallClockAssertion
    }
}

/// Configuration for the test-outcome flip detector (within TestRunner).
///
/// The detector persists a per-package roster after each `test` run and flags any test
/// whose pass/fail outcome flips while the package fingerprint is unchanged — i.e.
