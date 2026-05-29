# Phase 2.2 — Resume Prompt for Next Agent

Copy the fenced block below verbatim as the first message to the next agent
after compaction. Updated after each item closes so the "state at handoff"
section stays current.

---

```
Continue Phase 2.2 of VectorSuiteBench. Items 0 (shared infrastructure),
1 (Borrowing families: l2dist, cosine, normalize-OOP), and 2 (Diff
mode UI) are COMPLETE. Next up: Item 3 — Mutating families. First
exercise of the MutatingWorkload protocol from VSBCore; the runner's
K-input-rotation Amortized-mode logic is already tested in BenchKit
by NormalizeInPlaceSmokeWorkload (fixture-only) — these items make
it real in the registry.

## State at handoff

- Repo: /Users/goftin/dev/gsuite/VectorSuiteBench · main · push authorized
- GitHub: gifton/VectorSuiteBench
- Last commit: `9351395 feat(2.2): Diff mode complete — refusal banner,
  MD export, toolbar flip (Item 2c)`
- Phase 2.2 progress (10 sub-items shipped across 10 commits):
    Item 0 — Shared infrastructure
      0a `571b8c9` TopKSetVerifier in BenchKit/Verify/ (11 tests)
      0b `9a26671` RunPreset.filter machinery + Standard rebaseline
                    (9 tests, +preset-filter pre-narrow in VSBRun + RunInvocation)
      0c `502d3c6` Per-op cost weights in RunConfigEstimator (7 tests)
      0d `d06feb4` Kahan-Float64 oracle helpers for 7 new families
                    (rename KahanFloat64DotReference.swift → KahanFloat64Reference.swift;
                     16 tests)
    Item 1 — Borrowing families
      1a `7f593b7` L2DistanceFamily (17 cases, 12 tests; Optimized only
                    — VC Generic + Dynamic have no typed squared-distance API)
      1b `197bd83` CosineFamily (17 cases, 12 tests; similarity only —
                    CosineDistance is value transform 1-x, separate op)
      1c `0a0f028` NormalizeFamily out-of-place (26 cases, 16 tests;
                    FIRST family with full ×3 VC flavor matrix; first
                    vector-output family)
    Item 2 — Diff mode UI
      2a `4e3c976` DiffSelection model + RunPickerView (11 tests)
      2b `474fea3` DeltaTable + DeltaRow + filter adapter (12 tests)
      2c `9351395` Diff mode complete — refusal banner, MD export,
                    toolbar flip (3 tests; AppRoot + RunDetailView +
                    AppToolbar wired)
- Tests:
    BenchKit:  91   (unchanged across Item 2 — diff engine pre-existed)
    VSBCore:   73   (unchanged across Item 2)
    VSBRun:     3   (unchanged)
    App target: ~138 + 7 estimator + 26 (Item 2: 11+12+3) — runs via
                cmd-U only because pre-existing CalibrationStatusTests
                blocks `xcodebuild build-for-testing` (Carry-over A)
- Registry total: 27 dot + 17 l2dist + 17 cosine + 26 normalize = 87
  workloads (unchanged across Item 2 — diff is UI-only).
- Plan §2.5 build order: step 10 of 16 — Items 3a (NormalizeInPlace)
  + 3b (AXPY) next. Both are MutatingWorkload + per-family file
  structure identical to Items 1a/1b/1c.

## Item 2 wiring summary (read if touching diff later)

DiffSelection (Models/DiffSelection.swift) is `@MainActor @Observable
final class` with .baselineRunID / .comparisonRunID + .pairing(in:).
Auto-pick rule resolved via user Q&A: selection → comparison (newer),
next-older-sibling-by-timestamp → baseline. If selection is the oldest
run, baseline = nil and DiffPaneView falls through to the §1.5/6
empty-state card.

DiffPaneView (Views/DiffPaneView.swift) branches on .pairing's three
states (empty / crossFingerprint / valid). Loads both RunDocuments
via the coordinator on `task(id: pairingKey)`. NSSavePanel-driven
Markdown export wraps RunDiff.markdownTable() with a self-describing
header (runID + fingerprint per side). UniformTypeIdentifiers import
required for UTType.plainText.

AppRoot.toggleDiffMode() handles first-entry auto-population (via
DiffSelection.enterDiffMode) while preserving picks across toggles
once set. AppToolbar's compare button consumes isDiffMode +
onToggleDiff; foreground tints to VSB.Impl.vectorCore while active.

CaseTableFilter.apply(toDelta:) is the seam DeltaTable uses to share
the existing filter chips' state with the single-run table. Same
axis-AND / within-axis-OR semantics; pure-function adapter in
DeltaRowFilterLogic.

## Read first (don't skip)

1. **docs/phase-2.2-plan.md** — the plan. Critical sections for Item 3:
     §2 Item 3 — `NormalizeInPlaceFamily` (3a) + `AXPYFamily` (3b),
                 both MutatingWorkload.
     §1.5/2 — VectorCore flavor coverage rule (full ×3 where API
                 exists; check VectorCore's normalize-in-place + axpy
                 surface before claiming flavor coverage).
     §2.5 — milestones 10 + 11 ("NormalizeInPlaceFamily registered" /
                 "AXPYFamily registered").

2. **Packages/VSBCore/Sources/VSBCore/Implementations/NaiveNormalizeWorkload.swift**
   (or any of the OOP impls from Item 1c) — Item 3's per-family
   structure mirrors Item 1c's shape exactly, just with the
   MutatingWorkload protocol instead of BorrowingWorkload and
   `makeInputs(count K: Int, rng:)` returning K freshly-randomized
   vectors (not one shared input).

3. **Packages/BenchKit/Sources/BenchKit/Workload/Workload.swift** —
   confirm the MutatingWorkload protocol signature. The runner already
   handles K-input rotation; new workloads just have to provide
   `makeInputs(count K:rng:)` and `invoke(_ input: inout Input)`.

4. **Packages/VSBCore/Tests/VSBCoreTests/NormalizeInPlaceSmokeWorkload-related**
   (search) — there's an existing fixture testing the runner's
   K-input-rotation; new family integration tests follow that pattern.

## Item 3 sub-items (the next concrete work)

**3a. `NormalizeInPlaceFamily`.** `aᵢ ← aᵢ / ‖a‖₂` in place. Mutating.
Impl set: VectorCore (×3) · vDSP in-place chain (`vDSP_vnrm2 +
vDSP_vsmul` writing back to source) · naïve in-place. Same 5 sizes
as Item 1c. The Phase 1 spec §9 case matrix doesn't include
`simd_normalize` here because Apple's `simd_normalize` returns a
new value (out-of-place semantics); reusing it as in-place would
be redundant with the OOP case in Item 1c.

**3b. `AXPYFamily`.** `y ← αx + y`. Mutating. Impl set: VectorCore
(×3) · `cblas_saxpy` · naïve. Same 5 sizes. α is held in
CanonicalParams as `"alpha": "0.5"` so the WorkloadID has a stable
identity; the value itself doesn't affect perf.

**Implementation note.** Both families' `makeInputs(count K: Int,
rng:)` returns K freshly-randomized vectors so the runner's K-input
rotation has independent data to consume. Don't pre-bake a "scratch"
buffer — that's the trap spec §2.4 warns against (NaN cascade in
tight loops).

**Tests per sub-item:** ~12 (size × impl matrix oracle tests +
integration smoke). Total Item 3: ~24 tests.

**Files per sub-item:** mirror Item 1c's structure.
- `Packages/VSBCore/Sources/VSBCore/Ops/<Family>Shared.swift` (new)
- `Packages/VSBCore/Sources/VSBCore/Implementations/{Naive,Accelerate,VectorCoreOptimized,VectorCoreGeneric,VectorCoreDynamic}<Family>Workload.swift` (new)
- `Packages/VSBCore/Sources/VSBCore/Registry.swift` (edit — `families += [<Family>()]`)
- `Packages/VSBCore/Tests/VSBCoreTests/<Family>WorkloadTests.swift` (new)

## Mid-item design pressure worth surfacing (don't decide silently)

Item 3 sub-decisions Item 1 didn't have to make:

- **NormalizeInPlace: which Generic API on Vector<D>?** VectorCore
  has both `.normalize()` (mutating) and `.normalizeInPlaceFast()` (?)
  variants depending on the type. Surface options to user; recommend
  the most-idiomatic-per-flavor per Item 1c's lock.

- **AXPY: which DynamicVector method?** Likely `add(_:scaledBy:)`
  or similar — confirm via grep against
  `/Users/goftin/dev/gsuite/VSK/VectorCore/Sources/VectorCore`
  before committing.

- **Alpha encoding in CanonicalParams.** Spec §9 says `"alpha":
  "0.5"`. Stable string. Mention in the family doc that varying
  alpha would produce distinct WorkloadIDs (each is a new case),
  not silently reuse one row.

Per Phase 2.1 + 2.2 user preference, **ask the user about these at
the start of each sub-item — don't decide silently**.

## Conventions (don't violate)

- **Swift Testing** (`@Suite`, `@Test`, `#expect`, `#require`,
  `Comment(rawValue:)`).
- **`@MainActor @Observable final class`** for UI state.
- **`nonisolated enum`** for pure-function namespaces.
- **All colors via `VSB.*` tokens; radii via `VSB.Radius.*`**
  (.swatch/.pill/.chip/.card). No raw literals.
- **NO SwiftUI #Preview blocks in new view files** — user validates
  on physical-device runs (2.1 user preference).
- **One commit per sub-item.** Don't batch.
- **Conventional Commits + multi-paragraph body + Co-Authored-By trailer**
  (`Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).
- **Push to main authorized.** If auto-classifier blocks, ask.
- **Ask decisions before coding** at each sub-item if design ambiguity
  surfaces.
- **Review after each item, then polish** before moving on.
- **MutatingWorkload single-shot mode pre-builds N fresh inputs**
  (one per sample) outside the timing window. Re-using one mutated
  input across N samples drifts toward NaN and corrupts measurement
  (spec §2.4 #1). The runner already handles this; just confirm
  `makeInputs(count K:rng:)` returns K independent inputs.
- **Twelve locked decisions are sacred.** 2.1's six + 2.2's six. Do
  not revisit; if you find yourself wanting to, stop and ask.

## Locked decisions reference

**From 2.1 §1.5 (still in force):**
  1. Sidebar: 3-line rows default. NO compact toggle.
  2. Mode pill: stays in every table row.
  3. Approximate-math: interleaved next to exact counterpart.
  4. Diff visual: merged delta table with ▼/▲ glyphs (Item 2 implemented).
  5. Hardware fingerprint: headline + NSPopover on click.
  6. Color-blind paths: ALWAYS layer ▼/▲ glyphs; never hue alone.

**From 2.2 §1.5:**
  1. Sequencing: Borrowing → Diff → Mutating → Async (TopK + verifier)
     → Async (pairwise + dM). On track — Item 3 (Mutating) is next.
  2. VectorCore flavor coverage: Full DotFamily-equivalent per family
     where API exists. Item 3 needs to confirm each impl's flavor
     surface before claiming coverage.
  3. Standard preset rebaseline: filter trim — drop Optimized from
     Standard (kept in Full). Wired in Item 0b.
  4. TopKSetVerifier in BenchKit/Verify/, built standalone in Item 0a.
  5. Diff anchor: Left=older (baseline), Right=newer (comparison),
     user-swappable. (Item 2a resolved the auto-pick ambiguity:
     selection → comparison, next-older sibling → baseline.)
  6. Diff empty-state: centered card ("Pick a run to compare against").
     (Item 2c implemented.)

## When to stop and ask

- Plan silent on a sub-decision you're about to make → flag, propose,
  wait. User prefers explicit clarification over assumed defaults.
- Implementation forces a deviation from a locked decision → STOP,
  don't ship. Surface the conflict.
- VectorCore's mutating API surface differs per flavor → propose
  options (skip / wrap a .copy() / call the most-idiomatic);
  ask before coding.
- Test you didn't author goes red → don't paper over; trace the root
  cause. (Reminder: `CalibrationStatusTests.swift` pre-existing
  compile error is NOT yours to fix in 2.2.)

## Known quirks

- **`xcodebuild build-for-testing` from CLI fails** at
  `CalibrationStatusTests.swift` — pre-existing compile error from
  before Phase 2.1. cmd-U from Xcode IDE works. Don't fix in 2.2.
- **`docs/libraries/*.md` untracked** — pre-2.0 carry-over. Leave.
- **Xcode synchronized groups**: new `.swift` files in existing trees
  (Views/, Models/, etc.) are picked up automatically. New top-level
  folders may need manual wiring.
- **Lock contention on `.git/index.lock`**: gitstatusd briefly holds
  the lock during prompt refresh. If `git add`/`commit` fails with
  "Unable to create index.lock", retry after a short wait
  (use a `for i in 1..10; do test -f .git/index.lock || break; sleep
  0.5; done && git ...` pattern).
- **DeltaRow.Cell.absent MainActor isolation**: the app target's
  MainActor default propagates into nested struct static properties.
  Mark them `nonisolated` if a nonisolated builder needs to reference
  them (caught at first build via warnings). Pattern applies to
  any new model-layer static `.absent` / `.empty` / etc. constants.
- **NSSavePanel requires UniformTypeIdentifiers import** on top of
  AppKit + SwiftUI for `UTType.plainText`. Caught in Item 2c.

## Begin

1. Read `docs/phase-2.2-plan.md` §2 Item 3 (2 sub-items, ~30 lines).
2. Grep VectorCore for mutating normalize/axpy method names per
   flavor (`grep -rn "normalize\b\|normalizeInPlace\|saxpy\|add.*scaledBy"
   /Users/goftin/dev/gsuite/VSK/VectorCore/Sources/`).
3. Pose mid-item design questions (especially flavor coverage —
   which method per VC flavor — before coding 3a).
4. Build Item 3a (NormalizeInPlaceFamily + tests) → commit → push.
   Then 3b.

If anything reads ambiguous, stop and ask — the twelve locked
decisions are NOT ambiguous, but the per-impl method choices ARE
fair game to surface.
```
