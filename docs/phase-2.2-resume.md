# Phase 2.2 — Resume Prompt for Next Agent

Copy the fenced block below verbatim as the first message to the next agent
after compaction. Updated after each item closes so the "state at handoff"
section stays current.

---

```
Continue Phase 2.2 of VectorSuiteBench. Item 0 (shared infrastructure)
and Item 1 (Borrowing families: l2dist, cosine, normalize-OOP) are
COMPLETE. Next up: Item 2 — Diff mode UI. This is the first 2.2 item
that lives in the app target (SwiftUI), not VSBCore — a context shift
from the workload-registration pattern of Items 0d/1a/1b/1c.

## State at handoff

- Repo: /Users/goftin/dev/gsuite/VectorSuiteBench · main · push authorized
- GitHub: gifton/VectorSuiteBench
- Last commit: `0a0f028 feat(2.2): NormalizeFamily — out-of-place L2
  normalize op (Item 1c)`
- Phase 2.2 progress (7 sub-items shipped across 7 commits):
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
- Tests:
    BenchKit:  71 → 91   (+20 across Item 0)
    VSBCore:   17 → 73   (+56 across Items 0d + 1a-c)
    VSBRun:     3        (unchanged)
    App target: ~138 + 7 estimator tests (Item 0c) — runs via cmd-U
                only because pre-existing CalibrationStatusTests blocks
                `xcodebuild build-for-testing` (Carry-over A)
- Registry total: 27 dot + 17 l2dist + 17 cosine + 26 normalize = 87
  workloads (vs 27 at planning).
- Next: Item 2 — Diff mode UI. Two more workload-family items (3
  Mutating + 4-5 Async) follow. **Plan §2.5 build order is now at
  step 9: 1c complete → start Item 2.**

## Read first (don't skip)

1. **docs/phase-2.2-plan.md** — the plan. Critical sections:
     §1.5 — twelve locked decisions (six from 2.1 + six new for 2.2).
            **Items 2 implements §1.5/4 (merged delta table from 2.1) +
            §1.5/5 (anchor: older-left/newer-right + Swap) +
            §1.5/6 (empty-state card "Pick a run to compare against").**
     §2 Item 2 — three sub-items: 2a DiffSelection + RunPickerView,
                 2b DeltaTable + DeltaRow, 2c cross-fingerprint refusal
                 + Markdown export + toolbar flip.
     §2.5 — build order milestone 9 ("⇋ Compare button enabled in
            production; Diff mode complete").
     §6 — out-of-scope: chart deltas are explicitly NOT in 2.2 (locked
          §1.5 Diff scope; table-only).

2. **VectorSuiteBench/VectorSuiteBench/Views/AppToolbar.swift** — the
   `⇋ Compare` button currently ships disabled with a "Coming in Phase
   2.2" tooltip (Item 3d of 2.1). Item 2c flips it on.

3. **VectorSuiteBench/VectorSuiteBench/Views/CaseTable.swift** — mirror
   its 8-column row manifest for DeltaTable. Reuse 2.1's atoms: Pill,
   NumberCell, DeltaGlyph (polarity-aware ▼/▲), VerificationDot.

4. **Packages/BenchKit/Sources/BenchKit/Diff/RunDiff.swift** — the diff
   engine already exists from Phase 2.0. Includes cross-fingerprint
   refusal logic and a Markdown export. Item 2's UI consumes it
   directly; no new BenchKit code needed.

5. **VectorSuiteBench/VectorSuiteBench/Models/RunStoreCoordinator.swift** —
   how the sidebar reads runs. Diff picker also reads from here.

6. **VectorSuiteBench/VectorSuiteBench/AppRoot.swift** — top-level
   NavigationSplitView shell. Knows about `selectedRunID`; Item 2
   adds a parallel `diffSelection` state.

## Item 2 sub-items (the next concrete work)

**2a. `DiffSelection` model + `RunPickerView`.**

Build `@MainActor @Observable final class DiffSelection`:
```
var baselineRunID: String?     // older run (anchor; left pane)
var comparisonRunID: String    // newer run (right pane)
```
Initial baseline auto-picks the next-newer-in-sidebar run on entry to
Diff mode (per locked decision §1.5/5). User can Swap A↔B via a
toolbar button. Cross-fingerprint runs render greyed-out in the picker
but remain selectable (selecting one transitions to 2c's refusal banner).

`RunPickerView` is SwiftUI: two capsules in the diff toolbar showing
"YYYY-MM-DD · sha · preset" for each side, a `⇋ Swap` button between
them, and a Menu (or similar) for picking each side from the run list.

Tests in `DiffSelectionTests`: auto-pick logic, swap correctness,
cross-fingerprint detection. ~6 tests.

**2b. `DeltaTable` + `DeltaRow`.**

Mirror CaseTable's 8-column manifest but each numeric cell renders as:
  `<comparison-value>  <DeltaGlyph(delta%, polarity: .lowerIsBetter)>`
e.g. `142 ns  [-12% ▼]`. Missing cases (present in one run, absent
in the other) render `[ N/A ]` in `VSB.Text.lo`. Filter state shared
with existing `CaseTableFilter` so the user can scope diff to one op
family. Builds against `BenchKit.RunDiff.compute(baseline:comparison:)`
which returns `[DiffEntry]` keyed by WorkloadID.

Tests in `DeltaRowDataTests`: synthetic baseline+comparison CaseResult
pairs → expected (value, delta%, polarity) triples. ~4 tests.

**2c. Cross-fingerprint refusal + Markdown export + toolbar flip.**

When `baseline.hardware.fingerprint != comparison.hardware.fingerprint`,
render full-card refusal banner ("Cannot compare runs from different
hardware fingerprints"). When `baselineRunID == nil`, render the empty
state card from §1.5/6 ("Pick a run to compare against"). When valid,
render an `Export Markdown` button in the diff toolbar that calls
`RunDiff.markdownExport(...)` (exists in BenchKit) via `NSSavePanel`.

`AppToolbar.swift`'s `⇋ Compare` button flips from `.disabled(true)
.help("Coming in Phase 2.2")` to enabled + state-toggling. When
active, RunDetailView switches to its Diff layout (DiffPaneView).

Tests: `DiffMarkdownExportTests` (~2 tests). Toolbar wiring covered
by manual physical-device validation (no SwiftUI #Previews per 2.1
convention).

**Total Item 2 test budget: ~12 tests.**

## Mid-item design pressure worth surfacing (don't decide silently)

Item 2 leaves several sub-details unspecified by the plan:

- **Diff-mode entry UX.** Click ⇋ Compare → switch the whole detail
  pane to Diff layout? Or overlay a picker bar above the existing
  table? Locked decision §1.5/4 says "merged delta table" — implies
  it replaces the table, not overlays. Confirm before coding 2b.

- **RunPicker UI shape.** SwiftUI Menu? Popover? Inline sidebar
  selector? Three reasonable options with different visual weights.

- **Markdown export trigger location.** Toolbar button (parallel to
  ⇋ Compare)? Inside the diff pane? Both?

- **Disabled-when-no-comparable-run state.** If only one run exists
  in the sidebar, ⇋ Compare has nothing to compare against. Disable
  the button? Show empty state on click? Hide entirely until ≥2 runs?

Per Phase 2.1 user preference, **ask the user about these at the start
of each sub-item — don't decide silently**.

## Conventions (don't violate)

- **Swift Testing** (`@Suite`, `@Test`, `#expect`, `#require`,
  `Comment(rawValue:)`).
- **`@MainActor @Observable final class`** for UI state
  (e.g., `DiffSelection`).
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
- **Reuse 2.1 atoms** wherever possible: Pill, ImplSwatch, NumberCell,
  DeltaGlyph (polarity-aware), VerificationDot, HatchedFillModifier.
- **Twelve locked decisions are sacred.** 2.1's six + 2.2's six. Do
  not revisit; if you find yourself wanting to, stop and ask.

## Locked decisions reference (especially 2.2 §1.5/4-6 for Item 2)

**From 2.1 §1.5 (still in force):**
  1. Sidebar: 3-line rows default. NO compact toggle.
  2. Mode pill: stays in every table row.
  3. Approximate-math: interleaved next to exact counterpart.
  4. **Diff visual: merged delta table with ▼/▲ glyphs.** ← Item 2's
     spec. `142 ns  [-12% ▼]` style.
  5. Hardware fingerprint: headline + NSPopover on click.
  6. Color-blind paths: ALWAYS layer ▼/▲ glyphs; never hue alone.

**New for 2.2 §1.5:**
  1. Sequencing: Borrowing → Diff → Mutating → Async (TopK + verifier)
     → Async (pairwise + dM). On track.
  2. VectorCore flavor coverage: Full DotFamily-equivalent per family
     where API exists. L2/Cosine ship Optimized only (no typed Generic/
     Dynamic API); Normalize ships ×3 flavors.
  3. Standard preset rebaseline: filter trim — drop Optimized from
     Standard (kept in Full). Wired in Item 0b.
  4. TopKSetVerifier in BenchKit/Verify/, built standalone in Item 0a.
  5. **Diff anchor: Left=older (baseline), Right=newer (comparison),
     user-swappable. Auto-pick next-newer-sibling as baseline.** ← Item 2a.
  6. **Diff empty-state: centered card ("Pick a run to compare against").**
     ← Item 2c.

## When to stop and ask

- Plan silent on a sub-decision you're about to make → flag, propose,
  wait. User prefers explicit clarification over assumed defaults.
- Implementation forces a deviation from a locked decision → STOP,
  don't ship. Surface the conflict.
- Existing atom (Pill, DeltaGlyph, etc.) doesn't fit the diff cell
  pattern → propose extending it vs creating a parallel; ask.
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

## Begin

1. Read `docs/phase-2.2-plan.md` §2 Item 2 (3 sub-items, ~50 lines).
2. Read `VectorSuiteBench/VectorSuiteBench/Views/AppToolbar.swift`
   and `VectorSuiteBench/VectorSuiteBench/Views/CaseTable.swift` to
   understand the surrounding patterns.
3. Read `Packages/BenchKit/Sources/BenchKit/Diff/RunDiff.swift` to
   know the existing diff-engine API surface.
4. Pose mid-item design questions (especially: entry UX, picker shape,
   markdown export location, disabled-when-only-one-run behavior)
   before coding 2a.
5. Build Item 2a (DiffSelection + RunPickerView + tests) → commit →
   push. Then 2b, then 2c.

If anything reads ambiguous, stop and ask — the twelve locked
decisions are NOT ambiguous (they govern visual + IA), but the
mid-item UX sub-details listed above ARE fair game to surface.
```
