import ArgumentParser
import Foundation

/// `vigil` — the flakiness & concurrency auditor.
///
/// Extracted from quality-gate-swift's war-story checkers (Phase 4,
/// move-not-fork: one implementation, two products — the quality gate
/// consumes VigilKit as a dependency). Also a first-class quality-gate
/// plugin: the `contract` verb speaks the Tier-2 plugin handshake.
@main
struct Vigil: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vigil",
        abstract: "Flakiness & concurrency auditing for Swift — flip detection, timing-tagged stress runs, temporal determinism.",
        version: "0.1.0",
        subcommands: [Contract.self]
    )
}

/// The quality-gate Tier-2 plugin handshake (Phase 4b, contract v1).
///
/// `vigil contract` prints the capability descriptor; a quality-gate run
/// discovering vigil in its `plugins:` config calls this first and skips
/// the plugin (with a note) on an unknown/newer contract version — the same
/// tolerance policy as corpus schema versioning.
struct Contract: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contract",
        abstract: "Print the quality-gate plugin contract descriptor (JSON)."
    )

    func run() throws {
        let descriptor: [String: Any] = [
            "contractVersion": 1,
            "checkerId": "vigil",
            "name": "swift-vigil",
            "parallelSafe": true,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: descriptor, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
}
