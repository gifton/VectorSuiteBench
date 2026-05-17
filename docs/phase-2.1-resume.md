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
- Last commit (after Item 2.0 schema bump): see `git log -1 --oneline`
- Tests: ~112 total. ~22 in the Xcode app target (DeltaGlyphTests,
  NumberCellSanitizeTests, RunStoreCoordinatorTests, RunProgressTests),
  plus 90 across the BenchKit/VSBCore/VSBRun SwiftPM packages (BenchKit
  bumped from 67 → 70 with the schema-bump tests).
- SchemaVersion is now 1.2. `RunMetadata.wallTimeNanos: UInt64?` and
  `RunSummary.wallTimeNanos: UInt64?` are populated by
  `RunController.run()` from the queue's start/end clock ticks and
  rewritten into the manifest by `RunStore.finalizeRun(runID:wallTimeNanos:)`.
  Pre-1.2 documents decode cleanly with nil.
- Xcode app target: builds clean. NavigationSplitView shell launches with
  a RunStoreCoordinator wired to
  ~/Library/Application Support/VectorSuiteBench/ and a temporary
  tappable sidebar listing runs by preset+SHA. Selecting a row loads the
  RunDocument and shows the case count. Crude, but proves the
  BenchKit→UI data spine is alive.
- Items DONE (8 → 5 remaining): 0 (design system), 1a (strip SwiftData
  template), 1c (data spine), 2.0 (schema bump for wallTimeNanos).
  Remaining: 2 (sidebar — schema is ready, view still needs writing),
  5, 3a, 3b, 3c, 3d, 4a, 4b, 4c.

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

## Recommended sequence (7 sub-items → close 2.1)

  1. **Item 2 — RunListSidebar** (critical path — unblocks 3a/b/c/d).
     Schema is ready (wallTimeNanos in RunSummary); the view-side work
     is the only thing left for Item 2.

  2. **Item 5 — First-launch / calibration empty state.**

  3. **Item 3a → 3b → 3c → 3d** — detail surface.

  4. **Item 4a → 4b → 4c** — New Run modal + RunController integration.

## First concrete task: Item 2 — RunListSidebar (view-side)

Replace the placeholder list in `AppRoot.swift` (currently inside
`sidebarPlaceholder`, lines ~53–71) with a dedicated `RunListSidebar`.

Design doc §04 (read it). Specs:
- Three-line rows, ~62 px tall, in a `List` with relative-date section
  headers ("Today" / "Yesterday" / "May 13"). Locked decision §1.5/1:
  3-line default; NO compact toggle.
- Line 1: time (HH:MM) — implicit from group header.
- Line 2: preset chip (use Pill — `.accent` for SMOKE, `.neutral` for
  STANDARD/FULL, `.warn` for CUSTOM, or similar; check design doc) +
  branch in `.vsbBody(color: VSB.Text.md)` + short SHA via `.vsbMonoSha()`.
- Line 3: duration (formatted from `summary.wallTimeNanos`) + case count
  ("342 cases" or "342/600" when `completedCaseCount < caseCount`).
- Top-right of row: warn-colored dot (probably a new `ThrottleDot` atom —
  distinct semantic from VerificationDot) when
  `summary.thermalEscalations > 0`.
- Sortable via header toolbar buttons or context menu: by date (default,
  newest first), sha, preset, case count.
- Click selects → write to `AppRoot.selectedRunID` via the environment-
  passed coordinator OR `@Binding` from AppRoot.

Files to create:
- `VectorSuiteBench/VectorSuiteBench/Views/RunListSidebar.swift`
- `VectorSuiteBench/VectorSuiteBench/Models/RunSummaryGrouping.swift`
  — pure functions that bucket [RunSummary] into [(SectionHeader, [Summary])]
  by relative date (Today / Yesterday / weekday-name / formatted-date).
  Pull out as pure functions so they're unit-testable without SwiftUI.
- `VectorSuiteBench/VectorSuiteBench/Views/ThrottleDot.swift` (probably
  warrants its own atom — distinct semantic from VerificationDot).

Tests (in VectorSuiteBenchTests/):
- `RunSummaryGroupingTests` — given a list of summaries with timestamps
  ranging over today/yesterday/last-week/last-month, verify the
  grouping produces the right section headers and the right ordering
  within and across sections.

### Closing Item 2

Update AppRoot to use `RunListSidebar` and remove the placeholder list.
User performs Xcode "Add Files to Target" pass for the new files; cmd-B
+ cmd-U should be green.

Target tests after Item 2: ~118 total (112 + ~6 new).

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
