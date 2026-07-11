# The loop with three exits

*Rule: `concurrency.cancellation-checkpoint-after-loop` · try it: `vigil scan`*

## The failure

A session-recording app had a bug that survived design-first TDD, code review,
and more than three consecutive green test cycles: a user-initiated **stop**
was occasionally recorded as a **completed** session. It finally surfaced only
because unrelated packages' test suites happened to run in parallel and
stress-loaded the scheduler.

The code looked correct — the author was demonstrably careful about
cancellation:

```swift
func run(_ stream: AsyncThrowingStream<Sample, Error>) async throws {
    for try await sample in stream {
        try Task.checkCancellation()      // cancellation treated as semantic ✓
        process(sample)
    }
    session.markCompleted()               // ❌ also runs on the cancelled path
}
```

The mental model was "we fall out of the loop when the stream finishes."
Wrong. When the surrounding `Task` is cancelled, `for try await` **ends
quietly** — the iterator returns `nil` and the loop exits *normally*. It does
not throw `CancellationError`. There are three exits from that loop: stream
finished, error thrown, and *cancelled-silently* — and everything after the
loop that depends on **why** it exited runs on the third path too.

## Why existing tools missed it

This is semantically valid Swift concurrency, blessed by the compiler under
complete strict-concurrency checking. There's no data race for a sanitizer to
find, no API misuse for a linter's pattern to match. And a flake policy of
"pass twice in a row and we believe you" is *correct* here and still passes
it — cancellation rarely lands inside the loop's await window. The defect is
in the author's model of the control flow, and only a rule that models the
control flow can see it.

## The rule

vigil flags a `for await` / `for try await` loop when **both** hold:

1. The enclosing function already references `Task.checkCancellation()` or
   `Task.isCancelled` — the author has *shown* cancellation is semantic here.
   (This opt-in gate keeps false positives near zero.)
2. The loop's following statements reach exit-reason-dependent code without an
   intervening cancellation check. `defer` blocks are exempt — cleanup runs on
   every path by design.

The fix is one line:

```swift
    }
    try Task.checkCancellation()          // the loop exit is a stage boundary
    session.markCompleted()
```

## Reproduce it

Paste the failing shape above into any package's `Sources/` and:

```
$ vigil scan .
…: warning: [concurrency.cancellation-checkpoint-after-loop] cancelled
iteration ends quietly (nil), not by throwing — a loop exit is a stage
boundary; check cancellation before exit-reason-dependent code
```

Escape hatch, recorded not silent: `// concurrency:exempt` on the loop line.
