# The test that timed the scheduler

*Rule: `temporal-wall-clock-assertion` · try it: `vigil scan`*

## The failure

A numerical library had four performance tests asserting absolute wall-clock
thresholds — "this Monte Carlo batch completes in under 200ms" and friends.
They passed for months. Then a CI machine picked up a background indexing job,
and the suite started failing a few times a week, always a different test,
always green on re-run.

Each failure burned an investigation. Each investigation concluded "load
spike." Each conclusion trained everyone to re-run red tests without reading
them — which is precisely the reflex that later lets a *real* regression
through.

## Why existing tools missed it

The assertions were syntactically unimpeachable: measure a clock delta,
compare against a constant. Every testing framework *documents* this pattern
for benchmarks. The problem isn't the syntax; it's the venue — a wall-clock
threshold inside the correctness suite makes the suite's verdict a function of
machine load. No style rule models "this assertion's truth depends on what
else the kernel is doing."

## The rule

Inside a test, vigil flags an assertion (`#expect`, `#require`, `XCTAssert*`)
comparing a **measured elapsed wall-clock value** (a clock delta,
`timeIntervalSince*`, `start.duration(to:)`, or a variable bound to one)
against a numeric threshold.

Intentional perf tests declare themselves: `// TIMING:` on the assertion line
exempts it — and enrolls the test in `vigil stress`, where timing-sensitive
tests get run under deliberate contention instead of pretending load doesn't
exist. The rule doesn't ban benchmarks; it makes them opt in and get stressed
honestly.

## Reproduce it

```swift
// Tests/DemoTests/PerfTests.swift
@Test func fastEnough() {
    let start = ContinuousClock.now
    doWork()
    let elapsed = ContinuousClock.now - start
    #expect(elapsed < .milliseconds(50))   // vigil flags this line
}
```

```
$ vigil scan .
…: warning: [temporal-wall-clock-assertion] …
```

Mark it intentional — and stress it: add `// TIMING:` above the assertion,
then `vigil stress --runs 5`.
