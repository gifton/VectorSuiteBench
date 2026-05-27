# Phase 2.1 — Resume Prompt for Next Agent

Copy the fenced block below verbatim as the first message to the next agent
after compaction. Updated after each item closes so the "state at handoff"
section stays current.

---

```
Continue Phase 2.1 of VectorSuiteBench. The harness work is done; the
phase is now UI implementation against a locked design doc.

## State at handoff

- Repo: /Users/goftin/dev/gsuite/VectorSuiteBench · main · push authorized
- GitHub: gifton/VectorSuiteBench
- Last commit (after Item 4c): see `git log -1 --oneline`
- Tests: ~222 total. ~131 in the Xcode app target (+ **RunInvocationIntegrationTests**
  — 4 tests covering the Start path, pre-cancellation, empty-selection
  guard, and concurrent-start no-op), plus 91 across the
  BenchKit/VSBCore/VSBRun SwiftPM packages.
- SchemaVersion is 1.2. `RunMetadata.wallTimeNanos: UInt64?` and
  `RunSummary.wallTimeNanos: UInt64?` are populated by
  `RunController.run()` from the queue's start/end clock ticks.
- Xcode app target: builds clean (verified via `xcodebuild ... build`).
  `AppRoot` uses the real `RunListSidebar` — three-line rows grouped by
  relative date (Today / Yesterday / older), preset pill + branch +
  short SHA on line 2, duration + case count on line 3, throttle dot
  in the top-right when `thermalEscalations > 0`. Selection writes
  through to `AppRoot.selectedRunID`.
- **Xcode synchronized groups discovery**: the project uses Xcode's
  modern synchronized-folder references — new `.swift` files in
  `VectorSuiteBench/`, `VectorSuiteBench/Models/`,
  `VectorSuiteBench/Views/`, `VectorSuiteBench/Components/Design/`, and
  `VectorSuiteBenchTests/` are picked up automatically. **No more
  manual "Add Files to Target" passes required** for files dropped into
  those existing trees. New top-level folders may still need wiring;
  add via Xcode if a new tree is needed.
- Items DONE: 0 (design system), 1a (strip SwiftData template), 1c
  (data spine), 2.0 (schema bump for wallTimeNanos), 2 (RunListSidebar
  + grouping + ThrottleDot), 5.0 (PeakMeasurement.writeCached), 5
  (FirstLaunchView + CalibrationStatus), 3a (RunSummaryHeader + 7-cell
  grid + HardwareFingerprintPopover + thermal banner + RunDetailView
  shell), 3b (CaseTable — 8-column data table with 6 row treatments
  + CaseRowBuilder + CaseTableFilter shared with 3c), 3c
  (ThroughputBarChart + ChartsPane 5-slot picker + Table ⟷ Charts
  toggle in RunDetailView; chart honors the shared filter), 3d
  (window-level AppToolbar with 4 disabled buttons + LiveStateChip;
  keyboard shortcuts reserved on disabled buttons so 4a's New Run
  ⌘N activation needs no retraining), 4a (New Run modal shell:
  RunConfig model with preset-flips-to-custom logic; RunConfigView
  with 5 sections + sticky footer + CheckboxChip/ImplChip/FlowLayout
  atoms; New Run button in AppToolbar wired to present the sheet;
  Start button stays disabled until 4c), **4b** (live-estimate
  footer: `RunConfigEstimator` with exact case count + uniform-
  per-mode wall + linear bytes; footer renders `342 cases · ~4m 50s
  · ~12 MB JSON` with combined-element a11y label).
  4b (live-estimate footer: `RunConfigEstimator` ...), **4c**
  (RunInvocation orchestrator + RunController in-process wiring;
  Start button enabled; `+ New Run` ↔ `◼ Cancel` toolbar swap;
  ReleaseGuard errors surface to LiveStateChip as `.failed`; empty-
  selection produces a `.failed` state with reason; minimum-viable
  scope — streaming row treatment deferred to 2.2+).
  **Phase 2.1 is COMPLETE.**
- **Known Xcode quirk**: `xcodebuild ... test` fails at the test-target
  link step (unable to find BenchKit symbols). cmd-U from Xcode IDE
  works (presumably via scheme-level framework linking that diverges
  from CLI). Pre-existing — predates Item 2. Worth diagnosing as a
  cleanup pass but does NOT block any item.

## Read first (don't skip)

1. **docs/phase-2.1-plan.md** — the plan. Critical sections:
     §1.5 — six locked decisions (sidebar density, mode pill, approximate
            placement, diff visual, hardware popover, color-blind glyphs).
            Do not revisit these without raising.
     §2   — 8 items + sub-items. 0 / 1a / 1c / 2.0 are done.
     §2.5 — build order with on-screen milestones.
     §2.6 — test strategy.
     §5   — conventions (Swift Testing, BenchClock, @Observable, etc.)
     §6   — explicit out-of-scope for 2.1.

2. **docs/design/phase-2.1-design.html** — visual source of truth.
   Open in a browser. Tokens, IA, badge vocabulary, every chart treatment,
   every edge-case state. Implement against this; do not re-derive.

3. **docs/phase-2.0-plan.md §8** — what tools exist in BenchKit/VSBCore/
   VSBRun. Specifically: RunController, RunStore, PeakMeasurement,
   RunDocument, CaseResult, RunSummary (now with wallTimeNanos),
   RunIndex, RunMetadata (now with wallTimeNanos), WorkloadID, ImplKind,
   VerificationResult.

4. **Current app target code** (these are the atoms you'll compose with):
     VectorSuiteBench/VectorSuiteBench/Design/{Tokens,Typography}.swift
     VectorSuiteBench/VectorSuiteBench/Components/Design/*.swift
       — Pill (7 variants incl. systemImage init), ImplSwatch,
         NumberCell (.value/.missing/.error, NaN-sanitized),
         DeltaGlyph (polarity-aware, ▼/▲ always layered),
         VerificationDot (pulses on .inflight, with a11y label),
         HatchedFillModifier.
     VectorSuiteBench/VectorSuiteBench/Models/{RunStoreCoordinator,RunProgress}.swift
     VectorSuiteBench/VectorSuiteBench/AppRoot.swift  ← placeholder sidebar
                                                       to be replaced.

## Recommended sequence (1 sub-item → close 2.1)

  1. **Item 4c — RunController invocation + cancellation.** Start
     button flips to enabled; tap → spawn detached Task →
     RunController.run(). RunProgress observable drives the streaming
     row treatment in the table + the LiveStateChip in the toolbar.
     Cancel via the cancellation token already validated in Phase 2.0.

## First concrete task: Item 4c — RunController invocation + cancellation

The last piece of Phase 2.1. The modal shell (4a) opens, the
estimator (4b) shows what the run will cost, but Start is still
disabled. 4c flips it on and wires the actual benchmark.

**Files to create:**
- `Models/RunInvocation.swift` — `@MainActor @Observable` glue that
  owns the in-flight `Task`, the `CancellationToken`, and exposes
  `RunProgress` for observation by the LiveStateChip + the table's
  in-flight row treatment. Spawns RunController on `.start(config:)`.

**Files to modify:**
- `Views/RunConfigView.swift` — flip Start to `.disabled(false)`,
  wire its action to `RunInvocation.start(config:)`, dismiss the
  sheet on success.
- `Views/AppToolbar.swift` — accept `liveState` driven by
  `RunInvocation.state` instead of hardcoded `.idle`.
- `AppRoot.swift` — own a `RunInvocation` instance; pass to toolbar
  + (eventually) to the table for the in-flight row treatment.
- `Views/CaseTable.swift` — read `RunProgress` to flip the
  in-flight row's `VerificationDisplayState.inflight` (the seam
  shipped in 3b).

**Tests:**
- `RunInvocationIntegrationTests` — start path through the UI
  invokes `RunController` and produces the same RunDocument shape
  the CLI's `RunControllerIntegrationTests` did. Mirror that test's
  fixture; verify document on disk.
- Cancellation path: start → wait briefly → cancel → expect a
  truncated partial RunDocument.

Target tests after 4c: ~225 (218 + ~7 new). **Phase 2.1 complete.**

## Conventions (don't violate)

- **Swift Testing** (`@Suite`, `@Test`, `#expect`, `#require`,
  `Comment(rawValue:)` for failure messages — NOT plain strings when
  interpolating).
- **`@MainActor @Observable final class`** — pattern for UI state.
- **`Color(.sRGB, ...)`** — explicit color space, never the implicit form.
- **SwiftUI Font carries no tracking** — apply via `.tracking()` on the
  View, ideally bundled into the `.vsb*()` modifier.
- **SourceKit cross-file diagnostics are stale.** Truth is `cmd-B` in
  Xcode or `swift build` from the SwiftPM package dirs.
- **One commit per sub-item.** Don't batch.
- **Conventional Commits + multi-paragraph body + Co-Authored-By trailer**
  (`Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).
- **Push to main authorized.** If auto-classifier blocks, ask the user.
- **User does Xcode file-adds.** After every commit that creates new
  files in the app target, the user has to manually add them to the
  Xcode target (right-click sidebar → Add Files → tick target membership).
  Document the new file list at the bottom of every commit message so
  the user knows what to add.
- **`main.swift` is reserved** in SwiftPM executables — naming a file
  `main.swift` AND putting `@main` on a struct elsewhere causes a hard
  compile error. The VSBRun CLI hit this once already (`main.swift` →
  `VSBRunCommand.swift`). Don't recreate the bug.
- **Locked decisions in plan §1.5 are sacred.** Do not revisit; if you
  find yourself wanting to, stop and ask the user.

## Locked decisions reference (plan §1.5)

  1. Sidebar: 3-line rows default. NO compact toggle.
  2. Mode pill: stays in every table row (self-doc for CSV/PR exports).
  3. Approximate-math: interleaved next to exact counterpart, not grouped.
  4. Diff visual: merged delta table with ▼/▲ glyphs.
  5. Hardware fingerprint: headline + NSPopover with full detail on click.
  6. Color-blind paths: ALWAYS layer ▼/▲ glyphs; never hue alone.

## When to stop and ask

- Design doc silent on a sub-decision you're about to make → flag, propose,
  wait. The user prefers explicit clarification over assumed defaults.
- Implementation forces a deviation from a locked decision → STOP, don't
  ship. Surface the conflict.
- Test you didn't author goes red → don't paper over; trace the root cause.
- An "obvious refactor" of existing code appears mid-item — propose
  it as a separate commit, don't bundle.

## Begin

1. Read docs/phase-2.1-plan.md §2 Item 4c + §2.5 step 13 + §6
   (out-of-scope reminders).
2. Read docs/phase-2.0-plan.md §8 for the RunController invocation
   shape — same path the CLI's main.swift takes, just hosted in an
   in-process Task.
3. Skim VectorSuiteBench/VectorSuiteBench/Views/RunConfigView.swift
   `startButton` — flip `.disabled(true) → .disabled(false)` and
   wire `.action`.
4. Build 4c (RunInvocation + Start wiring + cancellation) → commit
   → push. **Phase 2.1 complete.**

If anything reads ambiguous, stop and ask — the locked decisions are
NOT ambiguous, but the design doc is silent on a few sub-decisions
(e.g. preset-chip styling per preset type, sort-control affordance) and
those are fair game to surface.
```
