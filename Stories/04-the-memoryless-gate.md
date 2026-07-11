# The memoryless gate

*Rules: flip detection + stress runs · try them: `vigil watch`, `vigil stress`*

## The failure

The same session-recording race from [story 3](03-the-loop-with-three-exits.md)
exposed a second, quieter problem: the test suite ran on every commit, and
**every run was memoryless**. A run cannot tell "this test passed yesterday
and fails today *with identical code*" from "this test always fails." The
first is a five-alarm signal — scheduler-dependent behavior, a real race,
reproducible only under load. The second is Tuesday.

Without memory, both look the same: a red test you re-run until it's green.
Teams institutionalize the re-run. The signal dies in the noise it should have
risen above.

## Why existing tools missed it

CI systems retry; retry *destroys* exactly the evidence that matters. Flake
trackers count failure rates but rarely condition on "did the code change?" —
and that conditioning is the whole trick. A test whose outcome flips while its
package fingerprint is unchanged has, by construction, been decided by
something other than the code. That's not a flaky test. That's the scheduler
testifying.

## The rules

**`vigil watch`** — after each test run, vigil stores the full pass/fail
roster keyed by a fingerprint of the package's sources and manifest. On the
next run of *identical* code, any outcome flip is reported as
scheduler-dependent behavior, with both commits named — a regression window,
not an accusation. A changed fingerprint resets honestly: different code is
allowed to behave differently.

**`vigil stress --runs N`** — for the tests that *declare* timing sensitivity
(`// TIMING:` — see [story 2](02-the-test-that-timed-the-scheduler.md)), vigil
runs them N times under full-core CPU contention. A test that is not unanimous
across N identical runs is a **definitive race**: same commit, same source,
different answers. No two-clean-runs policy can launder that.

## Reproduce it

```
$ vigil watch .        # run 1: records the roster
$ vigil watch .        # run 2, identical code: reports any flips, exit 1
```

```swift
// A test that loses under contention:
@Test func racesTheScheduler() async throws {
    // TIMING:
    let start = ContinuousClock.now
    try await Task.sleep(for: .milliseconds(10))
    #expect(ContinuousClock.now - start < .milliseconds(15))
}
```

```
$ vigil stress --runs 5
warning: definitive race: '…racesTheScheduler' was not unanimous across 5
identical stress runs (3 passed / 2 failed) — same commit, same source
```
