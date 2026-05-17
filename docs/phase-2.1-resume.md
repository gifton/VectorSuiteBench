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
- Last commit (after Item 5): see `git log -1 --oneline`
- Tests: ~134 total. ~42 in the Xcode app target (DeltaGlyphTests,
  NumberCellSanitizeTests, RunStoreCoordinatorTests, RunProgressTests,
  RunSummaryGroupingTests, CalibrationStatusTests — +8 from Item 5),
  plus 91 across the BenchKit/VSBCore/VSBRun SwiftPM packages
  (BenchKit 71 with PeakMeasurement.writeCached round-trip test).
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
- Items DONE (8 → 3 remaining): 0 (design system), 1a (strip SwiftData
  template), 1c (data spine), 2.0 (schema bump for wallTimeNanos),
  2 (RunListSidebar + grouping + ThrottleDot), 5.0 (PeakMeasurement
  .writeCached), 5 (FirstLaunchView + CalibrationStatus +
  CalibrationStatusFeed + AppRoot routing).
  Remaining: 3a, 3b, 3c, 3d, 4a, 4b, 4c.
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

## Recommended sequence (5 sub-items → close 2.1)

  1. **Item 3a → 3b → 3c → 3d** — detail surface (summary header,
     case table, throughput chart, diff toolbar placeholder).

  2. **Item 4a → 4b → 4c** — New Run modal + RunController integration.

## First concrete task: Item 3a — Run-summary header

Replace `AppRoot`'s `detailPlaceholder` with a real header view per
design doc §04 (Run Summary header) + §07 (thermal-throttle banner
edge case).

Design doc highlights:
- 7-cell info grid spanning the top of the detail pane. Each cell:
  one line of label (caption), one line of value (mono, tabular),
  one line of context (mono, lo-color). Cell borders are 1px hair
  lines so the grid reads as one structure.
- When `thermalEscalations > 0`: a warn-tinted **non-dismissable
  banner** sits above the grid explaining when/how many events
  occurred.
- Hardware cell opens an `NSPopover` (locked decision §1.5/5) with
  full chip details (cluster sizes, base/boost clocks, memory
  channels). The headline shows just "M3 Max · 14C / 30G".
- Body below the header reads "Coming next" until Item 3b lands the
  CaseTable.

Files to create:
- `VectorSuiteBench/VectorSuiteBench/Views/RunSummaryHeader.swift` —
  the 7-cell info grid.
- `VectorSuiteBench/VectorSuiteBench/Views/ThermalBanner.swift` — the
  warn-tinted banner.
- `VectorSuiteBench/VectorSuiteBench/Views/HardwareDetailPopover.swift`
  — the NSPopover content for the hardware cell.
- `VectorSuiteBench/VectorSuiteBench/Views/RunDetailView.swift` — host
  view that loads a `RunDocument` from the coordinator and composes
  the header + banner + placeholder body.

Tests:
- `RunSummaryHeaderFormattingTests` — pure-function formatters for the
  7 cells (preset, time, hardware fingerprint, swift/build, thermal
  summary, harness floor, schema version).

Wiring:
- AppRoot's `detailPlaceholder` becomes `RunDetailView(selection:)`
  conditional on `selectedRunID != nil`. When nil, show a "Select a
  run" placeholder.

Target tests after Item 3a: ~140 total (134 + ~6 new).

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

1. Read docs/phase-2.1-plan.md §1.5, §2 (Items 2 + 5 in particular),
   §2.5, §5, §6.
2. Read docs/design/phase-2.1-design.html sections 04 (Main Window) and
   07 (Edge cases — for the throttle state).
3. Skim VectorSuiteBench/VectorSuiteBench/AppRoot.swift to see what the
   placeholder sidebar looks like today.
4. Start with Item 2 (RunListSidebar) → commit → push.

If anything reads ambiguous, stop and ask — the locked decisions are
NOT ambiguous, but the design doc is silent on a few sub-decisions
(e.g. preset-chip styling per preset type, sort-control affordance) and
those are fair game to surface.
```
