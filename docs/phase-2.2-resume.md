# Phase 2.2 — Resume Prompt for Next Agent

Copy the fenced block below verbatim as the first message to the next agent
after compaction. Updated after each item closes so the "state at handoff"
section stays current.

---

```
Continue Phase 2.2 of VectorSuiteBench. Phase 2.1 closed; the registry
still ships only DotFamily. 2.2 adds the remaining six op families
(L2 / cosine / normalize-OOP / normalize-IP / axpy / topK / pairwise /
distanceMatrix) and lights up the Diff UI.

## State at handoff

- Repo: /Users/goftin/dev/gsuite/VectorSuiteBench · main · push authorized
- GitHub: gifton/VectorSuiteBench
- Last commit (after Item 0a / 1a / ... will be filled as items close):
  see `git log -1 --oneline`
- HEAD at planning close: `44e2f4a docs(2.2): planning document for
  op-family expansion and diff mode`
- Phase 2.1 closed at `025f9d1`; 14 items done; ~222 tests; app surface
  is fully wired end-to-end (calibration → sidebar → detail view with
  header/table/charts/toolbar → New Run modal with live estimator →
  Start → in-process RunController → Cancel).
- BenchKit tests: 71/71 passing.
- VSBCore tests: ~17 (dot-family only).
- VSBRun tests: 3.
- All three workload runner paths (Borrowing / Mutating / Async) are
  PLUMBED end-to-end in BenchKit. Smoke fixtures at
  `Packages/BenchKit/Tests/BenchKitTests/Fixtures/{NormalizeInPlaceSmokeWorkload,
  AsyncDotSmokeWorkload}.swift` already exercise the Mutating and Async
  paths. 2.2 adds zero new harness code in BenchKit beyond
  `Verify/TopKSetVerifier.swift`.
- BenchKit `Diff/RunDiff.swift` already implements the diff engine +
  Markdown export. Item 2 is purely the UI layer on top of an existing
  engine.

## Read first (don't skip)

1. **docs/phase-2.2-plan.md** — the plan. Critical sections:
     §1.5 — twelve locked decisions (six from 2.1 + six new for 2.2).
            Do not revisit without raising.
     §2   — 6 items + 17 sub-items. None done yet.
     §2.5 — build order with 16 visible milestones.
     §2.6 — test strategy (+90-130 → ~310-350 target).
     §3   — six carry-overs from 2.1 (the only one that might bite is
            Carry-over A — `CalibrationStatusTests.swift` pre-existing
            compile error; do NOT fix as part of 2.2 unless explicitly
            asked).
     §5   — conventions (Swift Testing, @Observable, no SwiftUI in
            packages, no SwiftUI #Preview blocks in new view files,
            ask decisions at sub-item boundaries).
     §6   — explicit out-of-scope for 2.2 (anything in 2.3+ territory).

2. **docs/phase-1-design.md** — overarching spec.
     §2.1 — workload protocols.
     §2.2 — WorkloadID identity rules; `vectorflavor` required iff
            impl == .vectorCore; `api: raw | metric` axis for dot only.
     §5   — verification rules including set-based Top-K (sqrt-aware
            multiset equality + index-validity re-check).
     §9   — Phase 1 case matrix; pins op-by-op flavor coverage, sizes,
            batches. Read the rows for the family you're working on.

3. **Packages/VSBCore/Sources/VSBCore/Registry.swift** — the existing
   DotFamily is the exact template every new family mirrors. Read
   `Packages/VSBCore/Sources/VSBCore/Ops/Dot.swift` and
   `Packages/VSBCore/Sources/VSBCore/Implementations/DotImpls.swift`
   alongside it — the file-pair pattern is what each new family
   ships.

4. **Packages/BenchKit/Sources/BenchKit/Workload/Workload.swift** —
   the three workload protocols. Confirm whichever protocol your
   family needs (BorrowingWorkload for L2/cosine/normalize-OOP;
   MutatingWorkload for normalize-IP/axpy; AsyncWorkload for
   topK/pairwise/distanceMatrix).

5. **Packages/BenchKit/Sources/BenchKit/Runner/{Runner,AsyncRunner}.swift** —
   both runners. Confirm the generic `run<W>(...)` for your protocol
   exists and is exercised by tests.

## Recommended sequence (per locked decision §1.5/1)

Phase 2.2 ships items in this order. The plan's §2.5 build order has
all 16 milestones; the abbreviated chain is:

  1. **Item 0 — Shared infrastructure** (4 sub-items)
     0a. TopKSetVerifier.swift in BenchKit/Verify/ + ~10 unit tests
     0b. Standard preset filter trim (drop Optimized at Standard)
     0c. RunConfigEstimator wall-time table extended for new ops
     0d. Oracle helpers (KahanFloat64Reference) for the 7 new refs

  2. **Item 1 — Borrowing families** (3 sub-items)
     1a. L2DistanceFamily (l2dist², spec §9 row 2)
     1b. CosineFamily (spec §9 row 4) — confirm api split during impl
     1c. NormalizeFamily out-of-place (spec §9 row 5)

  3. **Item 2 — Diff mode UI** (3 sub-items)
     2a. DiffSelection model + RunPickerView
     2b. DeltaTable + DeltaRow
     2c. Cross-fingerprint refusal + Markdown export + toolbar flip

  4. **Item 3 — Mutating families** (2 sub-items)
     3a. NormalizeInPlaceFamily (spec §9 row 6)
     3b. AXPYFamily (spec §9 row 7)

  5. **Item 4 — TopK + verifier integration** (3 sub-items)
     4a. TopKFamily skeleton + VectorCore-only first impl
     4b. Accelerate-heap baseline + naïve baseline
     4c. Integration tests + registry tie-in + fail-path test

  6. **Item 5 — pairwise + distanceMatrix** (2 sub-items)
     5a. PairwiseDistancesFamily (spec §9 row 9)
     5b. DistanceMatrixFamily (spec §9 row 10) — Phase 2.2 COMPLETE.

## First concrete task: Item 0a — TopKSetVerifier

Build the multiset-equality + sqrt-awareness + index-validity engine
from spec §5 as a standalone BenchKit type. This unblocks Item 4a
(when the TopK family wires it in) and is the only piece of net-new
harness code in 2.2 (everything else is in VSBCore + the app target).

**Files to create:**
- `Packages/BenchKit/Sources/BenchKit/Verify/TopKSetVerifier.swift`
  — pure function or namespace-enum surface:
  ```swift
  public enum TopKSetVerifier {
      public static func verify(
          candidate: [(index: Int, score: Float)],
          reference: [(index: Int, distance: Double)],
          implReturnsSquared: Bool,
          ulpWindow: UInt32,
          recomputeDistance: (Int) -> Double
      ) -> VerificationResult
  }
  ```
  Implementation steps (mirror spec §5 protocol exactly):
    1. If `implReturnsSquared`, sqrt the candidate scores into Double.
    2. Multiset-equality check: sort both distance arrays, compare
       pairwise within the ULP window for the underlying op.
    3. Index-validity re-check: for each candidate (idx, _), call
       `recomputeDistance(idx)` and confirm the result is present in
       the reference multiset within the ULP window.
  Spec §5's pseudo-code is the source of truth.

- `Packages/BenchKit/Tests/BenchKitTests/TopKSetVerifierTests.swift`
  — ~10 unit tests:
    * empty multiset (k=0)
    * single element (k=1)
    * all identical distances (ties)
    * mixed ties + uniques
    * candidate returns square-root mode
    * candidate returns squared mode
    * missing index (e.g., candidate returns idx 5 but reference
      doesn't contain it; recomputeDistance(5) returns a value not
      in the multiset → must fail)
    * wrong index (idx returned but recomputeDistance returns wrong
      value → must fail)
    * tolerance boundary (just within window passes; just outside
      fails)
    * smoke against a small hand-computed dataset

Read spec §5's "Top-K verification — set-based" subsection alongside
this file. The protocol's 3-step pseudo-code is exact; don't
paraphrase or simplify — the index-validity step in particular is
load-bearing for catching bugs that multiset-equality alone would
miss.

**Tests:** ~10 tests. Target BenchKit total after Item 0a: ~81.

Once 0a is complete, move to Item 0b (RunPreset filter trim). Each
sub-item is ONE commit — don't batch.

## Conventions (don't violate)

- **Swift Testing** (`@Suite`, `@Test`, `#expect`, `#require`,
  `Comment(rawValue:)` for failure messages — NOT plain strings when
  interpolating).
- **`@MainActor @Observable final class`** — pattern for UI state.
- **`nonisolated enum`** — pure-function namespaces.
- **`Color(.sRGB, ...)`** — explicit color space, never the implicit
  form (in any new app-target view).
- **All colors via `VSB.*` tokens; radii via `VSB.Radius.*`**
  (.swatch / .pill / .chip / .card). No raw literals.
- **No SwiftUI #Preview blocks in new view files** — user validates
  on physical-device runs.
- **One commit per sub-item.** Don't batch.
- **Conventional Commits + multi-paragraph body + Co-Authored-By trailer**
  (`Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).
- **Push to main authorized.** If auto-classifier blocks, ask.
- **Ask decisions before coding** at every sub-item boundary if
  design pressure surfaces — pattern from 2.1.
- **Review after each item, then polish** before moving on. 2.1's
  "implement → review → polish → next" cadence stays.
- **WorkloadID identity rules sacred** — bump SchemaVersion.minor on
  any additive change; never rename a wire-name without a migration.
- **`WorkloadFamily`-pattern for any new registry surface.** Each of
  the 6 new families follows the DotFamily template line for line.
- **`vectorflavor` required iff `impl == .vectorCore`.** Non-VectorCore
  impls (Accelerate, simd, naïve) must not carry `vectorflavor`;
  CanonicalParams canonicalizer rejects it.
- **Reference oracle operates on raw `[Float]`** regardless of
  candidate flavor. Runner unwraps Vector<DimN> / VectorNOptimized /
  DynamicVector before verification.
- **Twelve locked decisions are sacred.** 2.1's six (§1.5) + 2.2's six
  (§1.5 of phase-2.2-plan.md) — do not revisit; if you find yourself
  wanting to, stop and ask.

## Locked decisions reference

**From 2.1 §1.5 (still in force):**
  1. Sidebar: 3-line rows default. NO compact toggle.
  2. Mode pill: stays in every table row.
  3. Approximate-math: interleaved next to exact counterpart.
  4. Diff visual: merged delta table with ▼/▲ glyphs. ← this IS what
     Item 2 implements.
  5. Hardware fingerprint: headline + NSPopover on click.
  6. Color-blind paths: ALWAYS layer ▼/▲ glyphs; never hue alone.

**New for 2.2 §1.5:**
  1. Sequencing: Borrowing → Diff → Mutating → Async (TopK + verifier)
     → Async (pairwise + dM). Item-level order from above.
  2. VectorCore flavor coverage: Full DotFamily-equivalent per family
     (3 flavors × 5 sizes trimmed for missing types + baselines).
  3. Standard preset rebaseline: filter trim — drop Optimized from
     Standard (keep in Full). Target ~280 cases / ~7-8 min.
  4. TopKSetVerifier in BenchKit/Verify/, built standalone in Item 0a.
  5. Diff anchor: Left=older (baseline), Right=newer (comparison),
     user-swappable. Auto-pick next-newer-sibling as baseline.
  6. Diff empty-state: centered card ("Pick a run to compare against").

## When to stop and ask

- Plan silent on a sub-decision you're about to make → flag, propose,
  wait. User prefers explicit clarification over assumed defaults.
- Implementation forces a deviation from a locked decision → STOP,
  don't ship. Surface the conflict.
- VectorCore's API surface differs from what spec §9 expected (e.g.,
  cosine's metric variant returns same sign as raw; pairwiseDistances'
  signature changed) → flag the discrepancy, propose how to map.
- Test you didn't author goes red → don't paper over; trace the root
  cause. (Reminder: `CalibrationStatusTests.swift` pre-existing
  compile error is NOT yours to fix in 2.2.)
- An "obvious refactor" of existing code appears mid-item — propose
  it as a separate commit, don't bundle.

## Known quirks

- **`xcodebuild ... test` from CLI fails** at test-target link step
  (unable to find BenchKit symbols). cmd-U from Xcode IDE works.
  Pre-existing from before 2.1. Don't fix in 2.2.
- **`docs/libraries/*.md` untracked** — pre-2.0 carry-over. Leave
  unless you're already in there for unrelated reasons.
- **Xcode synchronized groups discovery**: new `.swift` files dropped
  into existing trees (e.g., `VectorSuiteBench/`, `Views/`, `Models/`)
  are picked up automatically. New top-level folders may still need
  manual wiring in Xcode.
- **Lock contention on git index**: `gitstatusd` (shell-prompt status
  daemon) can briefly hold `.git/index.lock` during prompt refresh.
  If `git add`/`commit` fails with "Unable to create index.lock",
  test that the lock file exists with `test -f .git/index.lock`
  and retry after a moment — usually the daemon releases within
  a second.

## Begin

1. Read `docs/phase-2.2-plan.md` end-to-end (especially §1.5, §2 Item
   0, §2.5 milestones 1-3, §6 out-of-scope).
2. Read `docs/phase-1-design.md §5` "Top-K verification — set-based"
   subsection in full.
3. Read `Packages/BenchKit/Sources/BenchKit/Verify/{ReferenceOracle,
   ULPWindows,VerificationResult}.swift` to confirm the surrounding
   Verify types are familiar.
4. Build Item 0a (TopKSetVerifier + ~10 unit tests) → commit → push.
5. Continue with Item 0b (preset filter trim), then 0c (estimator),
   then 0d (oracle helpers), then move to Item 1a (L2DistanceFamily).

If anything reads ambiguous, stop and ask — the twelve locked
decisions are NOT ambiguous, but the design doc is silent on a few
sub-decisions (e.g., cosine's api-axis question in Item 1b; exact
file split for the AsyncWorkload datasets in Items 4-5) and those
are fair game to surface.
```
