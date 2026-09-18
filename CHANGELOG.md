# Changelog

All notable changes to swift-vigil are documented here.

## [Unreleased]

### Added
- **`temporal-ambient-calendar`** — production code whose date arithmetic moves with the machine.
  The existing rules here are about the *clock*; this is the *calendar*, which fails the same way
  and hides better: a wall-clock read looks like one, while `Calendar.current` looks like the
  obvious way to get a calendar.

  Flags `Calendar.current`, and `Calendar(identifier:)` with no time zone pinned. The second
  matters more — pinning the identifier reads as diligence, so the site survives review, while
  the value still carries `TimeZone.current`.

  Four defects in one week motivated it, each written by someone who knew about time zones: an
  application's ranking differed by deployment zone; "years of experience" could land a month
  either side; a January date rendered as the previous year; a simulation's period boundaries
  landed one step early west of Greenwich. **Three of the four were found through a *test* that
  mirrored the production call**, by a rule scanning only `Tests/` that structurally could not
  reach the original. This one looks where the defect is.

  Three carve-outs, all earned rather than imagined — a zone pinned by a later statement, pinned
  inside an `if let` (those initialisers are failable), or pinned as a sibling argument of the
  same call. That last is the *safest* form, and an earlier version of these carve-outs elsewhere
  missed it and reported eleven findings against exemplary code. `Calendar.current` gets none of
  them: pinning a zone fixes half an ambient calendar, and the system is still the runner's.

  Scoped to files outside `Tests/`, so it does not double-report what `test-quality`'s
  `ambient-calendar-in-test` already owns. Toggle: `flagAmbientCalendar`. Suppression:
  `// temporal:exempt`, recorded as an override like every other rule here.

### Changed
- Subprocess spawning routes through
  [`swift-process-kernel`](https://github.com/jpurnell/swift-process-kernel) rather
  than raw `Process`. This fixes a real defect, not only a lint: vigil had no
  timeout anywhere, so `TestSpawner.swiftTest` spawned `swift test` and waited
  forever. `vigil stress` runs suites repeatedly under deliberate contention —
  precisely the conditions that deadlock a test — which meant the tool built to
  find hangs would hang instead of reporting one. Runs are now bounded at 30
  minutes, generous enough not to fire on a cold build, and the deadline signals
  the child's process *group* because SwiftPM routinely leaves build servers and
  test helpers holding the pipe open after the child exits.

  The runner is a separate package for a reason worth recording: it used to live in
  `QualityGateCore`, and `quality-gate-swift` depends on this repository, so
  importing it here would have closed a dependency cycle. The `bounded-io` rule's
  own suggested fix named a symbol vigil could not import — writing the correct fix
  did not clear the rule.
- `.quality-gate.yml` now exists and declares `logging.projectType: cli`. Without
  it the repository was audited as an "application" by default, and all 17 of its
  `print()` calls were reported as errors. Every one is user-facing output —
  human-readable diagnostics, and JSON documents meant to be piped — so routing
  them through `os.Logger` would have sent the tool's own output to the unified
  log and left the pipe empty. `LoggingAuditor` gates the rule on `isCLI` for
  exactly this case.

### Fixed
- `temporal-simulated-wall-clock` matched timestamp argument labels with
  `contains("time")` and `hasSuffix("at")`, which fired on `format:`,
  `heartbeat:`, `timeout:` and `timeGrid:` while missing `asOf:` — the common
  spelling for a business-time stamp. Labels now match exactly or on a trailing
  camelCase component, so `executedAt` qualifies and `format` does not.
- The rule's message asserted a mechanism that was often absent. A stamp inside a
  loop still reports sample spacing tracking scheduler jitter; a single stamp now
  reports non-reproducibility instead. Claiming a sampling-interval failure at a
  site with no interval invites a reader to dismiss a true finding.
- Two `catch` blocks in `CancellationScan` and `TemporalScan` swallowed the error
  when a file could not be read, recording only the path in `skipped`. A
  permissions failure and a non-UTF-8 file produced identical output, and the
  difference is the whole diagnosis. Both now log the reason.
- `TestSpawner.currentCommit` returned `""` when git failed, with nothing to
  explain it — every flip record's commit became `""` silently.
- Test helpers still split lines on a `"\n"` literal after `c082dc9` moved
  `Sources/` to the CRLF-safe `.lines`, leaving a stray `\r` on every line of a
  file written on Windows.

### Added
- `simulationTypes` and `timestampLabels` in `TemporalDeterminismConfig`, both
  additive to the built-in lists and decoded from `.quality-gate.yml`, for
  fabricated sources not named `mock`/`fake`/`simulation` and for domain
  vocabulary the built-in labels do not carry.

## [0.7.0] — 2026-08-27

### Added
- `scripts/release.sh` — universal binary (arm64 + x86_64), built on our own
  hardware; GitHub Releases is distribution only.

### Fixed
- Line splitting that survives CRLF. `components(separatedBy: "\n")` finds the
  `\n` inside a `\r\n` and leaves the `\r` behind, so comparisons, suffix checks
  and column arithmetic were all one character out on any file written on Windows.

## [0.6.0]
### Added
- `watch` and `stress` verbs — vigil detects real flakes standalone.

## [0.5.0]
### Added
- `scan` and `check` verbs — vigil is a complete quality-gate Tier-2 plugin.

## [0.4.0]
### Added
- `CancellationScan` — the cancellation-checkpoint-after-loop rule, standalone.

## [0.3.0]
### Added
- `StressAnalysis` — pure stress-batch detection, moved from `TestRunner`.

## [0.2.1]
### Fixed
- Public `init` for `TestOutcomeFlip`; `@testable` visibility does not survive
  extraction into a separate package.

## [0.2.0]
### Added
- `TemporalScan` — the temporal-determinism engine, moved from
  `quality-gate-swift`.

## [0.1.0]
### Added
- VigilKit foundation: flip detection, roster store, timing-test scanner, and
  plugin contract v1.

[Unreleased]: https://github.com/jpurnell/swift-vigil/compare/0.7.0...HEAD
[0.7.0]: https://github.com/jpurnell/swift-vigil/compare/0.6.0...0.7.0
[0.6.0]: https://github.com/jpurnell/swift-vigil/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/jpurnell/swift-vigil/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/jpurnell/swift-vigil/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/jpurnell/swift-vigil/compare/0.2.1...0.3.0
[0.2.1]: https://github.com/jpurnell/swift-vigil/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/jpurnell/swift-vigil/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/jpurnell/swift-vigil/releases/tag/0.1.0
