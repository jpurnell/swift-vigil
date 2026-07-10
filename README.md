# swift-vigil

Flakiness & concurrency auditing for Swift. Born from production failures —
each rule exists because something real slipped past `swift test` twice
before anyone understood why.

**Status: extraction in progress.** VigilKit currently vends flip detection
(`FlipDetector` + `TestOutcomeStore` — same-fingerprint pass/fail changes
across runs, the scheduler-dependent class the "two clean runs" flake policy
cannot catch) and the `// TIMING:` stress-test scanner. Temporal determinism
and the cancellation-checkpoint rule land next, then the `scan`/`watch`/
`stress` CLI verbs, war stories, and a Homebrew tap.

`vigil` is also a first-class [quality-gate](https://github.com/jpurnell/quality-gate-swift)
plugin — `vigil contract` speaks the Tier-2 plugin handshake, and
quality-gate consumes VigilKit directly (move-not-fork: one implementation,
two products).

## License

MIT — see [LICENSE](LICENSE).
