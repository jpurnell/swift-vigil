# swift-vigil

Flakiness & concurrency auditing for Swift. Every rule here exists because a
real production failure slipped past `swift test`, code review, and a green
gate — twice — before anyone understood why.

```
brew install jpurnell/tap/swift-vigil

vigil scan .          # static rules: temporal determinism, cancellation checkpoints
vigil watch .         # cross-run outcome flips on identical code
vigil stress .        # // TIMING:-tagged tests under full-core CPU contention
```

Zero config. Read-only. Exit 1 on findings.

## The war stories

Each rule ships with the failure that created it — the bug, why existing
tools missed it, and a reproduce-it-yourself fixture:

1. [The simulation that told time](Stories/01-the-simulation-that-told-time.md) —
   simulated data whose timestamps tracked scheduler jitter (`temporal-simulated-wall-clock`)
2. [The test that timed the scheduler](Stories/02-the-test-that-timed-the-scheduler.md) —
   wall-clock thresholds in the correctness suite (`temporal-wall-clock-assertion`)
3. [The loop with three exits](Stories/03-the-loop-with-three-exits.md) —
   `for try await` ends *quietly* on cancellation; the code after the loop
   couldn't tell (`concurrency.cancellation-checkpoint-after-loop`)
4. [The memoryless gate](Stories/04-the-memoryless-gate.md) —
   outcome flips on identical code are the scheduler testifying (`watch`, `stress`)

## What it is

- **`VigilKit`** — the analysis engines as a library: `TemporalScan`,
  `CancellationScan`, `FlipDetector` + `TestOutcomeStore`, `StressAnalysis`,
  `TestRosterParser`, `TimingTestScanner`, `PackageFingerprint`. Pure
  detection; no process spawning.
- **`vigil`** — the CLI. Orchestration (running `swift test`, CPU contention)
  lives here.
- **A [quality-gate](https://github.com/jpurnell/quality-gate-swift) plugin** —
  `vigil contract` / `vigil check` speak the Tier-2 plugin contract, and
  quality-gate consumes VigilKit natively: one implementation, three delivery
  vehicles (move, not fork).

## Escape hatches — recorded, never silent

`// temporal:exempt` and `// concurrency:exempt` suppress a finding *and are
reported as acknowledged exemptions*. `// TIMING:` declares an intentional
wall-clock perf test — which enrolls it in `vigil stress`. Nothing disappears
quietly; that's the philosophy this tool grew up in.

## License

MIT — see [LICENSE](LICENSE).
