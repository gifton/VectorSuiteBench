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
- Last commit (after Item 3b): see `git log -1 --oneline`
- Tests: ~169 total. ~78 in the Xcode app target (DeltaGlyphTests,
  NumberCellSanitizeTests, RunStoreCoordinatorTests, RunProgressTests,
  RunSummaryGroupingTests, CalibrationStatusTests,
  RunSummaryFormattersTests, **CaseTableFilterTests** — +15 from
  Item 3b's row-builder + filter tests),
  plus 91 across the BenchKit/VSBCore/VSBRun SwiftPM packages.
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
  shell), **3b** (CaseTable — 8-column data table with 6 row treatments
  + CaseRowBuilder + CaseTableFilter shared with 3c).
  Remaining: 3c, 3d, 4a, 4b, 4c.
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

## Recommended sequence (3 sub-items → close 2.1)

  1. **Item 3c — ThroughputBarChart + Table ⟷ Charts toggle.** Reuses
     the `CaseTableFilter` shipped in 3b; pass the same instance into
     both surfaces so they share cohort state.

  2. **Item 3d — Diff toolbar placeholder.**

  3. **Item 4a → 4b → 4c** — New Run modal + RunController integration.

## First concrete task: Item 3c — `ThroughputBarChart` + Table ⟷ Charts toggle

Item 3b shipped `CaseTableFilter` as a `@MainActor @Observable final class`
at `VectorSuiteBench/Models/CaseTableFilter.swift`. **Reuse it.** Pass the
same `CaseTableFilter` instance into both the `CaseTable` (already wired
in `RunDetailView`) and the new `ThroughputBarChart`; both consumers
observe its state. The chart's op + impl chip filter row writes to the
filter's `ops` / `impls` axes — the same toggles the (future) table
filter chips will also write to.

Build `Views/ThroughputBarChart.swift` (Swift Charts `BarMark` grouped
by op, colored by impl). Approximate impls render hatched + dashed via
the existing `HatchedFillModifier`. Mode pill stays in the chart
header (§1.5/2). Wire the Table ⟷ Charts segmented control in
`RunDetailView` so the body swaps between `CaseTable` and the chart.

The four remaining chart slots (LatencyHistogram, LatencyPercentile,
Roofline, MemoryPressure) render placeholders that read "Coming in
2.3" — design doc §06.

Files to create:
- `Views/ThroughputBarChart.swift`
- `Charts/ChartDataBuilder.swift` — pure `[CaseRow] → [ChartSeries]`
  builder (reuses the same row list the table consumes).
- `Tests/ChartDataBuilderTests.swift`

Target tests after Item 3c: ~177 total (169 + ~8 new).

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

1. Read docs/phase-2.1-plan.md §1.5, §2 Item 3c, §2.5, §5, §6.
2. Read docs/design/phase-2.1-design.html sections 04 (Main Window /
   Data Table) and 06 (Chart compositions — ThroughputBarChart spec).
3. Skim VectorSuiteBench/VectorSuiteBench/Models/CaseTableFilter.swift
   and Views/CaseTable.swift to see the shared filter contract.
4. Start with Item 3c (ThroughputBarChart + toggle) → commit → push.

If anything reads ambiguous, stop and ask — the locked decisions are
NOT ambiguous, but the design doc is silent on a few sub-decisions
(e.g. preset-chip styling per preset type, sort-control affordance) and
those are fair game to surface.
```
