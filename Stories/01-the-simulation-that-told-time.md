# The simulation that told time

*Rule: `temporal-simulated-wall-clock` · try it: `vigil scan`*

## The failure

A biofeedback package had a flaky test: `SimulationDeviceTests.timestampSpacing`
occasionally failed, claiming samples weren't evenly spaced. The obvious move —
blame the test, loosen the tolerance, move on.

The test was fine. **Production was wrong.** `SimulationDevice`, a *simulated*
data source, stamped each emitted sample with the wall clock:

```swift
return BioSample(rrInterval: rr, timestamp: ContinuousClock.now)   // ❌
```

Generation was driven by `Task.sleep`, and `Task.sleep` guarantees *at least*
the requested duration — never *exactly*. So the inter-sample spacing tracked
scheduler jitter instead of the intended RR interval. Simulated data whose
timestamps depend on how busy your machine is isn't simulated data; it's a
load monitor wearing a costume.

The fix derived time from a logical origin:

```swift
let timestamp = origin.advanced(by: .milliseconds(Int(elapsedSeconds * 1000)))  // ✅
```

## Why existing tools missed it

Linters look at tests for flakiness. This bug lived in `Sources/`, and the code
was idiomatic Swift — no force-unwraps, no races, nothing a style rule frowns
at. Tools that ban nondeterminism ban *randomness* (unseeded RNGs); nothing
guarded nondeterminism from *reading the clock*. And a human reviewer sees
`timestamp: ContinuousClock.now` as the most natural line in the world.

## The rule

Inside a type whose name matches `simulation|synthetic|mock|fake|stub|replay|fixture`,
vigil flags a wall-clock read (`ContinuousClock.now`, `Date()`, `DispatchTime.now()`,
`mach_absolute_time()`, …) used as a time-typed value — passed to a
`timestamp:`/`at:`/`createdAt:`-style argument or assigned to a
`time`/`date`-named member.

The scoping is the point: a real hardware device *legitimately* stamps `.now`.
A simulation must derive time from a logical origin, or its output embeds the
scheduler. Flagging only simulation-named types keeps the rule quiet on code
that's allowed to tell time.

## Reproduce it

```swift
// Sources/Demo/SimulationDevice.swift
actor SimulationDevice {
    func generateNextSample(at elapsedSeconds: Double) -> Sample {
        Sample(timestamp: ContinuousClock.now)   // vigil flags this line
    }
}
```

```
$ vigil scan .
…: warning: [temporal-simulated-wall-clock] …
```

Escape hatch, recorded not silent: `// temporal:exempt` on the line.
