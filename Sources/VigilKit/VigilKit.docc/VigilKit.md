# ``VigilKit``

Detection engines for the failures that only appear under load.

## Overview

A flaky test is not a category of test. It is a test whose result depends on
something nobody declared — the wall clock, the scheduler, the order two threads
happened to reach a lock. VigilKit holds the detectors for those dependencies,
as pure functions over source and over test output, so the same rules run inside
`quality-gate` as a plugin and standalone from the `vigil` command.

Detection is deliberately separate from orchestration. Nothing here spawns a
process or writes a file; the CLI does that. A scanner that also ran tests would
be much harder to test itself.

## The rules, and what produced them

Each of these exists because something failed in a way that looked like bad luck
and was not.

### Temporal determinism

``TemporalScan`` finds wall-clock reads where a reproducible value belongs.

A simulated data source stamped every sample with `ContinuousClock.now`. Because
generation was driven by `Task.sleep`, the spacing between samples tracked
scheduler jitter rather than the interval the test assumed — and the bug was in
production code, not the test that failed because of it.

The rule matches on names, in two places: the enclosing type against a list of
markers (`simulation`, `mock`, `fake`, …) and the argument label against a
timestamp vocabulary. Neither is semantic. **A green result is evidence about
names, not about determinism** — a determinism-critical type called something
else is outside the rule entirely, by design, because a real device stamping the
real clock is correct and must not be flagged.

### Wall-clock assertions

The second temporal rule finds tests asserting on *measured elapsed time*
against a threshold. Those pass on a quiet machine and fail under load, and they
read as flaky tests rather than as the timing assumptions they are. `// TIMING:`
declares one intentional and enrolls it in stress runs instead.

### Cancellation checkpoints

``CancellationScan`` finds loops that never check for cancellation. Structured
concurrency cancels cooperatively: a task that never looks runs to completion no
matter who asked it to stop.

### Flip detection

``FlipDetector`` compares test outcomes across runs at an unchanged package
fingerprint. A test that passed and now fails with identical code did not change
behaviour — the schedule did. ``StressAnalysis`` drives that deliberately,
running timing-tagged tests under contention to make the window reproducible.

## Exemptions are recorded, not silent

`// temporal:exempt` and `// concurrency:exempt` suppress a finding *and* return
it as a `DiagnosticOverride`. The count appears in the report. An exemption
nobody can see is indistinguishable from a rule that never fired, and the two
should never look alike.

## Topics

### Temporal determinism
- ``TemporalScan``
- ``TemporalDeterminismConfig``

### Concurrency
- ``CancellationScan``

### Flake detection
- ``FlipDetector``
- ``StressAnalysis``
- ``TestRosterParser``
- ``TestOutcomeStore``
