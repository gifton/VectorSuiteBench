# Phase 2.1 — First UI surface

**Status when this doc was written:** Phase 2.0 closed `47fcaa4`. 87 tests pass across BenchKit + VSBCore + VSBRun. The CLI writes complete `RunDocument`s to `~/Library/Application Support/VectorSuiteBench/` but nothing reads them back into a UI. The Xcode app target (`VectorSuiteBench.app`) is still the empty default template that came with `xcodebuild new`.

Phase 2.1 closes that gap. **Five UI items + six carry-overs from 2.0.** No new op families, no Metal, no new measurement code — the harness is done; this slice is purely about making a run viewable.

Subsequent slices: 2.2 adds new op families (L2 / cosine / normalize / AXPY / Top-K / pairwiseDistances / distanceMatrix); 2.3+ adds VectorAccelerate/Metal, MetricKit, FAISS.

This doc is the handoff. Assume the next agent has no prior context.

---

## 1. State at start of Phase 2.1

**Repo:** `/Users/goftin/dev/gsuite/VectorSuiteBench` · `main` · GitHub: `gifton/VectorSuiteBench` (push authorized).

**Read first:**
- `docs/design/phase-2.1-design.html` — **the visual source of truth.** Token sheet, IA, all five chart treatments, edge-case states. Decisions in §1.5 below resolve every open question in that doc's §08.
- `docs/phase-1-design.md` §3 (Reporting & Visualization) — pins the five canonical chart compositions and navigation shape.
- `docs/phase-2.0-plan.md` §8 — the carry-overs that flow into 2.1.

**What 2.1 composes:**

```
Packages/BenchKit/   (87 tests, library)
├── IO/              RunDocument, RunStore, CaseResult, MemorySample
├── Diff/            RunDiff (cross-fingerprint refusal + Markdown export)
├── Hardware/        HardwareInventory, PeakMeasurement (peaks/<fp>.json)
└── ... everything else built in 2.0 stays unchanged.

Packages/VSBCore/    (17 tests, dot family only)
Packages/VSBRun/     (3 tests, CLI)

VectorSuiteBench.xcodeproj    ← empty default SwiftUI template; the work happens here.
```

**What's NOT built** (Phase 2.1 fills these gaps):
- `VectorSuiteBench/` app target still imports no packages and shows the default ContentView.
- No `RunListSidebar`, `RunDetailView`, `RunConfigView`, `DiffPaneView`.
- No Swift Charts — even the manifest's `samples.csv` has no rendering.
- `PeakMeasurement.ensureCached` exists but no UI surfaces "Measure peaks?" on first launch.
- The `VectorSuiteBench/` target's `Package.swift` integration is unwritten — Xcode project needs to depend on `Packages/BenchKit` and `Packages/VSBCore`.

---

## 1.5 Visual source of truth + locked decisions

The design doc at `docs/design/phase-2.1-design.html` is the canonical visual reference for everything in 2.1. Tokens (color, typography, badge vocabulary), information architecture (3 surfaces — sidebar / detail / sheet), the data-table column manifest, the New Run modal layout, and every edge-case state are specified there. Implement against the doc; do not re-derive.

**Locked decisions** (resolves the doc's §08 open questions; do NOT revisit without raising):

| # | Question | Decision | Rationale to preserve |
|---|----------|----------|------------------------|
| 1 | Sidebar density (3-line default vs 1-line compact toggle) | **Keep 3-line as default.** No compact toggle. | Commit SHA + date + preset are the *identity* of a run. Compact strips context engineers actually scan for. Tight space → use scroll. |
| 2 | Mode pill location (table column vs top-level filter) | **Keep in the table row.** Every row carries `SHOT` / `LOOP`. | Rows get exported to CSV, pasted into PRs, screenshotted. The row must be entirely self-documenting; a top-level filter chip evaporates the moment data leaves the window. |
| 3 | Approximate-math placement (interleaved vs grouped at bottom) | **Interleaved, adjacent to the exact counterpart.** | The whole point of an approximate kernel is comparing it against the exact baseline (`100 ns exact` next to `40 ns approx`). Grouping at bottom destroys the comparison loop. |
| 4 | Diff visual (side-by-side vs merged delta) | **Merged delta table.** Single row: `142 ns  [-12% ▼]`. Missing baseline cells render as `[ N/A ]` or `—` in muted text. | Side-by-side forces ping-pong eye movement and mental arithmetic. Merged is drastically faster to read; the delta carries the comparison. |
| 5 | Hardware fingerprint detail | **Top level shows headline only** (`M3 Max · 14C / 30G`). **Click → `NSPopover`** with L1/L2 cache sizes, P/E split, memory bandwidth limits, OS build. | Regressions hide in the weeds, but the headline shouldn't shout them on every screen. Popover is the standard macOS affordance for "more detail on demand." |
| 6 | Color-blind paths | **Always layer directional glyphs by default.** `▼` for a drop, `▲` for an increase, paired with green/red text. Never hue alone. | (a) Accessibility floor; (b) polarity flips by metric — latency-lower-is-better vs throughput-higher-is-better. Glyphs eliminate the "is negative good here?" cognitive tax. |

### macOS chrome guard — traffic-lights reservation

**Reserve ~70px wide × ~28px tall in the top-left of the toolbar/sidebar for the native macOS window controls (Red/Yellow/Green "traffic lights").** Do NOT place sidebar titles, search bars, segmented controls, or back buttons in that zone — the macOS window decorations sit there and any UI underneath them ends up unreachable. SwiftUI's `Window` scene draws traffic lights automatically; use `.toolbar` content insets and `.safeAreaInset` rather than absolute positioning when adding content above the sidebar list.

### External-agent UI components

The user's external design agent is producing SwiftUI components alongside this plan. When those components are shared:

1. Drop them under `VectorSuiteBench/Components/` (preserving their internal structure).
2. Re-read this plan's items 2–5 — most items will move from "build the view" to "wire the supplied component to `RunStoreCoordinator` and friends."
3. Decisions in §1.5 supersede anything in the components that contradicts them. Ask the user before deviating from a locked verdict.

---

## 2. Phase 2.1 scope — sequenced items

The original plan listed five items. After the design doc landed, two of those (Item 1 wiring; Item 3 detail surface) are too coarse — the detail surface alone needs four sub-deliverables, and the app target's current state needs explicit cleanup before any new code lands. The revised breakdown is **eight items**, sequenced for incremental on-screen progress (see §2.5 Build order).

### Item 0 — Design system primitives (cross-cutting)

Before any view: build the design tokens and atomic components that every other item reuses. Skipping this means re-deriving cyan in five places and getting the `tabular-nums` modifier wrong on row 47.

**Tokens** (`VectorSuiteBench/Design/Tokens.swift`): `Color` extensions for `bg / surface0 / surface1 / surface2 / surface3 / hair / hair2 / divider`, `text.hi / md / lo / dim`, `impl.vectorCore / vDSP / accelerate / metal / naive`, `status.pass / fail / warn / info`. All `Color` values use OKLCH-equivalent RGB triplets from the design doc. The impl tokens drive both swatches and chart series colors.

**Typography** (`VectorSuiteBench/Design/Typography.swift`): `display / title / body / caption` (SF Pro Text variants) and `mono.number / mono.shaAxis` (SF Mono with `.monospacedDigit()` AND `tabular-nums` font feature). Every number cell in the app must use `mono.number` — no exceptions.

**Components** (`VectorSuiteBench/Components/Design/`):
- `Pill.swift` — 8 variants: `pass / fail / warn / info / neutral / approx / accent / mode`. All use SF Mono 700 with 0.4–0.6 tracking, 3 px rounded chip, matched chroma. `approx` is the dashed-border variant.
- `ImplSwatch.swift` — 10 × 10 color square keyed by `ImplKind`. Accepts an `isApproximate: Bool` modifier that switches to hatched fill (`Canvas` with 45° diagonal lines at 5 px pitch).
- `NumberCell.swift` — Right-aligned mono number with optional accent treatment for VectorCore rows. Handles nil → `—`, failed → `ERR` (in `--fail`).
- `DeltaGlyph.swift` — `▼` / `▲` + signed percentage + colored text. Polarity-aware: pass a `LowerIsBetter | HigherIsBetter` enum so the same `-12 %` reads green for latency and red for throughput (locked decision §1.5/6).
- `VerificationDot.swift` — small colored dot keyed by `VerificationResult`.
- `HatchedFillModifier.swift` — `ViewModifier` that overlays the diagonal-line pattern; used by `ImplSwatch` and by `ThroughputBarChart` bar marks for approximate rows.

**Tests:** none for view atoms (SwiftUI Previews carry the visual review). One unit test that `DeltaGlyph` flips polarity correctly given the `LowerIsBetter` enum — that's the only piece with real logic.

**Files:**
- `VectorSuiteBench/Design/Tokens.swift`
- `VectorSuiteBench/Design/Typography.swift`
- `VectorSuiteBench/Components/Design/{Pill, ImplSwatch, NumberCell, DeltaGlyph, VerificationDot, HatchedFillModifier}.swift`
- `VectorSuiteBenchTests/DeltaGlyphTests.swift`

---

### Item 1 — Xcode app target + data spine

Item 1 has three sub-deliverables. The app target today is the literal macOS SwiftData template (`Item.swift`, default `ContentView`, `sharedModelContainer`) — it has to be stripped before real code lands.

**1a. Strip the template.** Remove `Item.swift`, the `ModelContainer` setup, and the default `ContentView` body. `VectorSuiteBenchApp` becomes a thin `WindowGroup { AppRoot() }`. Remove the SwiftData / Item references from `VectorSuiteBenchTests/VectorSuiteBenchTests.swift`.

**1b. Add SwiftPM dependencies.** The app target needs to depend on `Packages/BenchKit`, `Packages/VSBCore`, and `Packages/VSBRun` (for `RunPreset` and the `PresetArg` enum if we choose to share it). **Decision required:** these edits live in `VectorSuiteBench.xcodeproj/project.pbxproj`. Two paths:
  - **(A) User adds the package refs in Xcode** — File → Add Package Dependencies → Add Local… × 3. 60 seconds, no pbxproj risk.
  - **(B) Agent edits `project.pbxproj` directly** — the format is text but finicky (XCSwiftPackageProductDependency + XCLocalSwiftPackageReference + target frameworks build phase). Possible but the pbxproj has more invariants than a hand-edit guarantees.

Recommend (A) — explicit hand-off; the plan flags this is the one place a fresh agent must pause for user action.

**1c. Data spine** (`VectorSuiteBench/Models/`):
- `RunStoreCoordinator.swift` — `@Observable` actor-equivalent. Loads `RunStore.defaultStore()` once. Publishes `var index: RunIndex` and a `func run(for: String) async throws -> RunDocument` cache. Watches `index.json` for changes (FSEvents or simple poll-on-foreground) so a CLI run while the app is open reflects within a second.
- `RunProgress.swift` — `@Observable` progress tracker, instantiated when a run starts. Polls `runs/<runID>/cases/` for new JSON files at 500 ms cadence; exposes `completedCount`, `totalCount`, `currentCase: WorkloadID?`. Stops on `finalizeRun`.
- `AppRoot.swift` — top-level `NavigationSplitView` with placeholder Sidebar / Detail pending Items 2 and 3.

**Tests:**
- `RunStoreCoordinatorTests` — populate a temp store with 3 runs via `RunStore.beginRun + writeCase + finalizeRun`, point the coordinator at it, verify `index` reflects all 3 with correct ordering (newest first).
- `RunProgressTests` — fake run dir with case files appearing over time; verify `completedCount` updates.

**Files:**
- `VectorSuiteBench/VectorSuiteBenchApp.swift` (rewrite — drop SwiftData).
- `VectorSuiteBench/AppRoot.swift` (new).
- `VectorSuiteBench/Models/RunStoreCoordinator.swift` (new).
- `VectorSuiteBench/Models/RunProgress.swift` (new).
- `VectorSuiteBench/Item.swift` → **delete**.
- `VectorSuiteBench/ContentView.swift` → **delete**.
- `VectorSuiteBenchTests/{RunStoreCoordinatorTests, RunProgressTests}.swift`.

### Item 2 — `RunListSidebar`

`index.json`-backed list. **Three-line row, ~62 px tall** (per locked decision §1.5/1):

```
┌─────────────────────────────────────────────┐
│ 14:32 · Today                          ⚠     │ ← throttle dot top-right
│ STANDARD · main · abc1234                    │ ← preset chip + branch + short SHA
│ 4m 51s · 342 cases                            │ ← duration + case count
└─────────────────────────────────────────────┘
```

- Group rows by relative date ("Today" / "Yesterday" / "May 13") via section headers.
- Surface short SHA before commit subject. Engineers triangulate by SHA — subject lines are long and rarely diagnostic.
- The throttle warning dot in the top-right corner flags runs with `thermalEvents.count > 0`. Never hide this behind hover — it's the single most common reason to not trust a run.
- Sortable by date / sha / preset / case count via column-header-style toolbar buttons.
- Empty state when `index.runs.isEmpty` shows a "Run your first benchmark" CTA that opens the Run Config sheet (Item 4) — or, on a fresh machine without `peaks/<fp>.json`, defers to the first-launch hardware-calibration flow (Item 5).

**Files:**
- `VectorSuiteBench/Views/RunListSidebar.swift`.

### Item 3 — Run Detail surface (broken into 4 sub-items)

The detail surface is the work surface. It's the biggest item by far — 4 sub-deliverables that build on each other (3a → 3b → 3c → 3d).


The work surface. Three regions, top to bottom:

**3a. Run Summary header — 7-cell info grid** spanning the top of the detail pane. Each cell: caption label (one line), value (mono, tabular, one line), context (mono, lo-color, one line). 1 px hair lines between cells so the grid reads as one structure, not seven cards. Cells:

1. **Hardware** — `M3 Max · 14C / 30G` (click → `NSPopover` with full chip/cache/clock detail per §1.5/5).
2. **Run started** — wall-clock time + ago-stamp.
3. **Duration** — `4m 51s`.
4. **Preset** — colored chip (`SMOKE` / `STANDARD` / `FULL` / `CUSTOM`).
5. **Build** — `Release · -O · Swift 6.0+`.
6. **Cases** — `342/342 · 0 failed · 4 ⚠` (truncates to `342/600 · 12 ⚠` when run is cancelled / in-flight).
7. **Git** — `main · abc1234` + dirty flag if applicable.

**Thermal-throttle banner** above the grid when `cases.contains { !$0.thermalEvents.isEmpty }`. Warn-tinted, non-dismissable. Explains when and how many events occurred. The signal is too important to be a tooltip.

**3b. Table ↔ Charts toggle.** Default lands on the Table (matches "did my change regress something?" workflow). The toolbar's `+ New Run` / `⇋ Compare` / `↓ Export CSV` / `⌖ Calibrate` lives at the top of the window (Item 1).

**3c. Data Table** — native macOS table with right-aligned numerics, zebra at 2% white, sortable column heads. Column manifest (FROZEN; matches the design doc; matches CSVExporter columns where applicable):

| Column | Treatment |
|--------|-----------|
| Operation | SF Pro 600. `dot ƒ32` (kernel + dtype suffix). |
| Implementation | 10×10 color swatch + library name + (optional) `~ APPROX` pill. Hatched swatch + dashed border on approximate variants. |
| Mode · Size | `SHOT` / `LOOP` capsule + mono `n=1024`. *Always present per locked decision §1.5/2.* |
| Median ns | SF Mono · tabular · right-aligned. VectorCore rows: number rendered in `--vc` accent at 600. |
| P99 ns | Same as median. |
| P999 ns | Same as median. **NO mean column ever** (spec §6). |
| GFLOP/s · GB/s | Same numeric system. VectorCore rows colored. |
| Status | Verification dot + optional flag pill (`⌇ BIMODAL` / `⏱ TRUNC` / `~ APPROX`) + optional note (`ε ≤ 2⁻¹⁵`, `ulp>1024`). |

Row-level integrity treatments (all from design doc §4 "Row-level integrity treatments" — implement against the design doc, not this summary):

- **VERIFIED** — normal row.
- **FAILED** — perf cells redact to `—` / `ERR` in `--fail`. Operation cell stays at `text-hi` so the row remains findable in a scan.
- **UNVERIFIABLE** — numbers shown but in `text-md`.
- **BIMODAL** — row gets a faint amber-tinted background; P999 cell colored `--warn`.
- **TRUNC** — P999 cell redacted; median/P99 stand.
- **APPROX** — entire row in `text-md`, swatch hatched, border dashed. **Interleaved adjacent to the exact counterpart per §1.5/3.**
- **In-flight** (during a streaming run) — implementation cell carries a trailing `⋯` pill.

**3d. Charts toggle target** — Phase 2.1 ships only `ThroughputBarChart` per item 6 scope. The toggle is wired but renders a "Coming in 2.3" placeholder for the other four chart slots. (Full chart suite is specced in the design doc §06.)

`ThroughputBarChart`: X = op, Y = GFLOP/s (or GB/s via toggle), grouped by impl. **Mode pill always visible in the chart header** (per §1.5/2 — mode is sacred). `.approximate` impls render with hatched fill (45° lines, 5 px pitch) + dashed 1 px border. VectorCore bars are the only saturated cyan; vDSP/Accelerate/simd/naïve are hue-varying graphites at chroma 0.04. Op / impl filter pickers above the chart share state with the table's filter — one filter, two consumers.

**Sub-items (build in order — 3a is the shell, 3b–3d slot into it):**

**3a. Summary header + thermal banner + detail shell.**
- `RunDetailView` — the container. Reads `selectedRunID` from `AppRoot`; loads the `RunDocument` via `RunStoreCoordinator`; renders `RunSummaryHeader` + a `Table ⟷ Charts` segmented control + a placeholder body.
- `RunSummaryHeader` — the 7-cell grid + thermal banner.
- `HardwareFingerprintPopover` — `NSPopover`-backed content for click-to-expand hardware details (locked decision §1.5/5).
- **Tests:** `RunSummaryHeader` preview-only. `HardwareFingerprintPopover` data-formatter tests (chip name → display string).

**3b. Data table.**
- `CaseTable.swift` — 8 columns, 6 row treatments per the manifest above.
- `CaseTableFilter` — `@Observable` filter model with op + impl + verification-status + mode pickers. Will be shared with 3c.
- **Tests:** `CaseTableFilterTests` — apply each filter axis to a sample registry, verify the resulting case list. View tests are SwiftUI Previews.

**3c. ThroughputBarChart + Table ⟷ Charts toggle wiring.**
- `ThroughputBarChart.swift` — Swift Charts `BarMark` grouped by op, colored by impl. Approximate impls use `.foregroundStyle` overrides + hatched fill modifier (Item 0).
- Wire the segmented toggle in `RunDetailView` so it switches the body between `CaseTable` and `ThroughputBarChart`. Both views observe the same `CaseTableFilter` instance.
- Placeholder views for the other 4 chart slots (rendered as "Coming in 2.3" cards inside the chart picker).
- **Tests:** `ThroughputBarChartDataTests` — feed the chart data builder a synthetic `RunDocument` and verify the resulting `[ChartSeries]` shape (groups, colors, hatched flags).

**3d. Diff toolbar placeholder.**
- Add the `⇋ Compare` button to the toolbar but mark it disabled with a "Coming in 2.2" tooltip. Reserves the chrome real estate per the design doc so 2.2 lands without re-shuffling.

**Files:**
- `VectorSuiteBench/Views/RunDetailView.swift`
- `VectorSuiteBench/Views/RunSummaryHeader.swift`
- `VectorSuiteBench/Views/HardwareFingerprintPopover.swift`
- `VectorSuiteBench/Views/CaseTable.swift`
- `VectorSuiteBench/Models/CaseTableFilter.swift`
- `VectorSuiteBench/Charts/ThroughputBarChart.swift`
- `VectorSuiteBench/Charts/ChartDataBuilder.swift`
- `VectorSuiteBenchTests/{CaseTableFilterTests, ChartDataBuilderTests, HardwareFingerprintFormatterTests}.swift`

### Item 4 — `RunConfigView` (New Run modal sheet)

Standard macOS sheet, **980 × 720**, dropped from the window titlebar. Five sections stacked vertically with a **180 px label gutter on the left** (one-line title + one-line hint per section) and form controls on the right.

**Section 1 — Preset.** Segmented control: `SMOKE` · `STANDARD` · `FULL` · `CUSTOM`. Selecting a preset pre-fills every section below. Touching any control after that quietly flips the chip to `CUSTOM` — no modal alert; visual cue only.

**Section 2 — Operations.** 4-column grid of Checkbox chips. Each chip carries the op name and its mathematical shorthand: `dot · ∑ aᵢbᵢ`. The math glyph removes the "does L2 mean norm or distance?" cognitive tax.

**Section 3 — Implementations.** 2-column grid of `ImplChip`s. Each: impl color swatch + library label + `APPROX` pill if fast-math. 2 columns (vs 4 for ops) because impls have richer per-row metadata. Both grids share selected-state treatment: 6% cyan fill, 0.5 px cyan border, checkbox glyph fills with accent.

**Section 4 — Vector sizes.** Horizontally-wrapping **pill grid** at log-spaced powers of 2 (`16 · 32 · 64 · 128 · ... · 4M · 16M`). Tap to toggle. This is the right pattern for a sweep with a fixed candidate set; slider handles would feel clinical and lose per-size precision.

**Section 5 — Budgets.** 3 × 2 grid of native-style select fields. Each has a one-line caption in mono underneath. The wall-clock-estimate caption is wired live to the footer (see below). Captions surface implications a perf engineer cares about: `Warm-up — 20 iter · skip` tells them the first 20 iterations don't count.

**Sticky live-estimate footer.** Pinned to the bottom of the sheet. Three numbers in accent: `~342 cases`, `~4m 50s`, `~12 MB JSON` — read first. A small breakdown grid on the right explains the math (`5 ops × 2 dtypes · 5 impls · 7 sizes · shot + loop`). Recompute on every toggle so the cost of every checkbox click is obvious in real time — prevents accidental 45-minute Full runs.

**Start button.** Only emphasized primary in the entire sheet: 6% inner highlight + 35% accent glow. `⌘↵` as a hotkey hint is the only mono text in the button.

**Wiring.** Start invokes `RunController` in-process with `measurePeaks: true` (unless `peaks/<hardware.fingerprint>.json` already exists). Progress reflected by `@Observable RunProgress` that watches the run dir + drives the "in-flight" row treatment in the data table (Item 3). Cancel button on the toolbar uses the `CancellationToken` path validated in Phase 2.0 — a cancelled run produces a *valid* partial RunDocument.

**Sub-items (build in order):**

**4a. Static modal shell.** All 5 sections rendered with placeholder selected state. No live computation. Verifies the layout dimensions + 180 px gutter + section ordering. Gets the design pixel-perfect before logic.

**4b. Live-estimate footer.** Compute the `(cases, wall, bytes)` triple from the current selection. Cases = Cartesian product of op × impl × size × mode. Wall = sum of per-case estimates (use a simple lookup table seeded from Phase 2.0 smoke-run timings; refine in later phases). Bytes = `cases × averageBytesPerCase` (~32 KB based on Phase 2.0 measured JSON sizes). Wire it to recompute on every toggle.
- **Tests:** `RunConfigEstimatorTests` — given a selection, expect the triple. The wall estimate is allowed to be ±50 % rough; cases must be exact.

**4c. RunController invocation + progress wiring + cancellation.**
- Start button → spawn a detached `Task` that calls `RunController(registry: filteredRegistry, store: store, preset: preset, cancellation: token).run()`.
- A `RunProgress` instance (Item 1c) gets created and passed to `AppRoot` so the sidebar can show the in-flight row treatment and the detail table can show streaming rows.
- Cancel button on the toolbar → `token.cancel()`. The CLI's SIGINT handler validated this path in 2.0; the in-process equivalent is direct.
- **Tests:** an integration test that spawns RunController against a single-case registry through the UI's start path (not the CLI's) and verifies the same RunDocument shape. Mirrors `RunControllerIntegrationTests` but exercises the UI's wiring.

**Files:**
- `VectorSuiteBench/Views/RunConfigView.swift`
- `VectorSuiteBench/Views/ImplChip.swift`
- `VectorSuiteBench/Views/PresetSegmentedControl.swift`
- `VectorSuiteBench/Views/LiveEstimateFooter.swift`
- `VectorSuiteBench/Models/RunConfigEstimator.swift`
- `VectorSuiteBenchTests/RunConfigEstimatorTests.swift`

### Item 5 — First-launch / hardware-calibration flow

When `peaks/<fingerprint>.json` is absent (fresh install, hardware changed, or method version stale) the main canvas refuses to show charts — peak measurement is required first so the Roofline (Phase 2.3+) has reference lines and so `Throughput` charts have a `%-of-peak` annotation.

**Empty state:** centered `cpu.mac` hero icon, `"Hardware Calibration Required"`, and a primary `⌖ Measure Peaks (~30 s)` button. While running, a terminal-style status feed (mono, `text-md`) renders below a small circular spinner — engineers want to see what step they're on, not a generic indeterminate bar.

After peaks land:
- If `index.runs.isEmpty` too → flip to a `"Run your first benchmark"` CTA that opens the Run Config sheet (Item 4) with `.smoke` preselected.
- If a previous run exists → fall through to the normal `RunDetailView`.

Re-prompts whenever `HardwareInventory.probe().fingerprint` changes (new Mac, dual-boot) or `PeakMeasurement.{computeMethodVersion,bandwidthMethodVersion}` differs from cached.

**Files:**
- `VectorSuiteBench/Views/FirstLaunchView.swift`.
- `VectorSuiteBench/Views/CalibrationStatusFeed.swift`.

---

## 2.5 Build order + visible milestones

The items above can ship in this sequence. Each step ends in something visibly different in the running app — easier to course-correct + easier to demo.

| # | Step | What's visible after |
|---|------|----------------------|
| 1 | Item 0 — design system primitives | Nothing in the app yet, but all SwiftUI Previews of the atoms (Pill / ImplSwatch / NumberCell / DeltaGlyph / VerificationDot) render. |
| 2 | Item 1a — strip SwiftData template | App builds and launches; window is empty. (Sanity gate before we add anything.) |
| 3 | Item 1b — **PAUSE: user adds package deps in Xcode** | App can `import BenchKit` / `import VSBCore` / `import VSBRun`. |
| 4 | Item 1c — data spine + `AppRoot` shell | App launches into a `NavigationSplitView` with empty Sidebar and Detail. `RunStoreCoordinator` loads `~/Library/Application Support/VectorSuiteBench/` if present. |
| 5 | Item 5 — first-launch / calibration | App on a fresh machine (no `peaks/<fp>.json`) shows the hardware-calibration empty state with a `⌖ Measure Peaks` button that runs. |
| 6 | Item 2 — `RunListSidebar` | Sidebar populates with any runs from previous CLI smoke runs (`swift run vsb-run --preset smoke`). Selecting a row is wired but the Detail still says "Select a run". |
| 7 | Item 3a — summary header + thermal banner + shell | Selecting a run shows the 7-cell header, with `NSPopover` working for the hardware cell. Body says "Coming next". |
| 8 | Item 3b — `CaseTable` | Selecting a run shows the full data table with all 8 columns and the 6 row treatments. **First moment the app is materially useful.** |
| 9 | Item 3c — `ThroughputBarChart` + Table↔Charts toggle | Toggling switches the body. Chart honors the shared filter state. Other 4 chart slots render placeholders. |
| 10 | Item 3d — diff toolbar placeholder | `⇋ Compare` button reserved in the toolbar (disabled). |
| 11 | Item 4a — modal shell | `+ New Run` opens the empty 5-section sheet. Nothing wired yet. |
| 12 | Item 4b — live estimate | Toggling controls updates the `~342 cases · ~4m 50s · ~12 MB` footer in real time. |
| 13 | Item 4c — RunController invocation | Start runs an in-process benchmark; rows stream into the Detail table during the run; Cancel works. **Phase 2.1 complete.** |

Estimated work: 6–9 focused sessions. Item 0 is small; Item 1c + Item 3b are the biggest chunks; Item 4c is the most error-prone (in-process orchestration + observable wiring + Task lifecycle).

If a session has to skip ahead, the dependencies are: Item 0 unblocks everything; Item 1b unblocks everything else; Item 3b can't ship before Item 3a; Item 4c can't ship before Item 1c. Items 2, 3a, 3c, 5 are independent of each other once their predecessors land.

---

## 2.6 Test strategy

Phase 2.1 ships ~15–20 new tests against the 87-test baseline (target ~105 total). UI is mostly visually reviewed via SwiftUI Previews; model + formatter + chart-data logic gets coverage.

**What gets tested:**

- `DeltaGlyphTests` — polarity flip works.
- `RunStoreCoordinatorTests` — temp store with 3 runs, verify index loads + ordering + per-run cache.
- `RunProgressTests` — fake run dir with case files appearing over time, verify counts update.
- `HardwareFingerprintFormatterTests` — chip string + core counts → display strings the popover renders.
- `CaseTableFilterTests` — each filter axis (op / impl / verification / mode) applied to a synthetic registry returns the expected case set.
- `ChartDataBuilderTests` — synthetic `RunDocument` → `[ChartSeries]` shape (groups, colors, hatched flags for approximate, mode pill data).
- `RunConfigEstimatorTests` — selection → `(cases, wall, bytes)` triple; cases exact, wall ±50 %.
- `RunControllerUIIntegrationTests` — start path through the UI invokes `RunController` and produces the same `RunDocument` shape as `RunControllerIntegrationTests` did in Phase 2.0 (via the CLI).

**What's NOT tested:**

- SwiftUI views themselves — visual review via Previews + manual smoke. Snapshot tests are out of scope for 2.1; revisit if Phase 2.2 finds a stable shape.
- Cross-process e2e (launch the `.app` binary from a test) — too brittle for 2.1; the CLI's e2e tests cover the harness path.

---

## 3. Phase 2.0 carry-overs (fold in if convenient)

Non-blocking. Land any that you touch the affected code for.

### Carry-over A — MemoryProbe stop race (cosmetic)

`DispatchSource.cancel()` is non-blocking; the `stopped` flag closes most of the window but a handler invocation that already passed the flag check can still land one extra sample. The idempotency test accepts `0 ≤ delta ≤ 1`. To eliminate entirely: either hold the snapshot lock across the handler body (expensive — the syscall inside `readResidentSize` would block other state ops), or queue-drain via `barrier_async` on the probe's serial queue before snapshot. The latter is the right move if anyone ends up debugging a memory trace anomaly; otherwise accept the bound.

### Carry-over B — vsb-run `--op` / `--impl` split

`--filter` currently disambiguates by which enum a token parses to. Today no op name overlaps any impl name (`dot` vs `naive` etc.), but a future op like `accelerate` (unlikely) or impl like `cosine` (very unlikely) would be ambiguous. Splitting into `--op dot --impl naive` is the safe form. Update `VSBRun/Sources/vsb-run/main.swift` if you're already in there for a CLI-progress flag in Item 4's polling.

### Carry-over C — PeakMeasurement `bytesPerArray` configurability

Currently fixed at 128 MiB × 3 = 384 MiB. Fine on M-series ≥ 16 GB. Problematic on 8-GB M1s if another app is RAM-pressed. Expose `--peak-bytes-per-array` on the CLI and a slider in Item 5's first-launch flow. Default stays 128 MiB.

### Carry-over D — `HardwareInventory.gpuCoreCount` IORegistry probe

Still `0` from Phase 1 (`Hardware/HardwareInventory.swift:61`). For the fingerprint to distinguish e.g. M3 Pro 14-core from M3 Pro 18-core GPU SKUs, this needs a real probe. IORegistry entry path: `IOService:/AppleARMPE/arm-io@10F00000/AppleH16IO/agx@1B000000`. Skip unless Phase 2.3+ Metal work demands it; the current fingerprint (chip + P/E cores + RAM) is unique enough for diff in practice.

### Carry-over E — `docs/libraries/*.md`

Pre-existing files from 2026-05-11 that have stayed untracked through Phase 1.5 + 2.0. Either stage them at the start of 2.1 (if still relevant) or `git rm` them. Don't let them keep showing up in `git status` indefinitely.

### Carry-over F — Mid-run cancellation e2e

The cancellation test in `RunControllerIntegrationTests.swift` pre-cancels via the token. A proper mid-run cancellation test for the CLI — spawn `vsb-run`, wait ~200 ms, `kill -INT <pid>`, wait for exit, load the partial RunDocument and assert it has *some* completed cases plus a `.truncated` on the in-flight one — wasn't added because subprocess SIGINT delivery is timing-sensitive across machines. Worth attempting in 2.1 if you find a stable shape; the RunConfigView's "Stop" button needs the same cancellation path so the e2e verifies the user-facing flow too.

---

## 4. Validation

```bash
# Existing 87 tests still pass.
cd Packages/BenchKit && swift test
cd Packages/VSBCore && swift test
cd Packages/VSBRun && swift test

# New: app target builds.
xcodebuild -project VectorSuiteBench/VectorSuiteBench.xcodeproj \
           -scheme VectorSuiteBench -configuration Release build

# New: end-to-end UI smoke. (Manual — open the app after a CLI smoke run.)
swift run vsb-run --preset smoke --skip-peaks --filter dot --filter naive
open VectorSuiteBench/VectorSuiteBench.xcodeproj
# Run the app; verify the run shows in sidebar, detail view renders chart + table.
```

Expected test count at 2.1 close: **~105** (87 carried + ~18 new). The new tests are listed in §2.6 — primarily models / formatters / chart-data builders; SwiftUI views themselves are reviewed via Previews + manual smoke, not snapshot-tested.

---

## 5. Conventions to follow

(Reaffirming from 2.0 plus the new UI-specific items.)

- **Swift Testing** (`import Testing`), not XCTest.
- **`borrowing Input` requires struct, not tuple.**
- **`BenchClock`, not `Clock`.**
- **No SourceKit pre-resolution** — `swift build` is truth.
- **WorkloadID identity rules sacred** — bump `SchemaVersion.minor` on any additive change.
- **`ImplClass` is algorithm shape, not library identity.**
- **`WorkloadFamily`-pattern for any new registry surface.**
- **Sendable everywhere.** `OSAllocatedUnfairLock<T>` for mutable state.
- **Auto-classifier may block `git push` to main** — user has authorized direct pushes; if blocked, ask.
- **NEW: SwiftUI views in the app target only.** Packages have no `import SwiftUI`. The app reads `RunDocument` / `CaseResult` / `WorkloadID` from BenchKit; charts construct from those types directly. No UI types leak into BenchKit.
- **NEW: `@Observable` over `ObservableObject`.** Swift 5.9+ macro form; cleaner Sendable story.
- **NEW: Charts render on completion, not mid-run.** Spec §3 pins this — no live updates while sampling. Run Config's "live estimate" is the only continuous UI during a run.

---

## 6. What Phase 2.1 explicitly does NOT include

The design doc specs the full chart suite + diff mode; that breadth is the *visual* target for the whole 2.x cycle, not 2.1 alone.

**Designed but deferred (ship the slot, not the chart):**

- **Remaining four chart compositions** — `LatencyHistogram`, `LatencyPercentile`, `Roofline`, `MemoryPressure`. Render each as a `"Coming in 2.3"` placeholder inside the Table/Charts toggle (Item 3). The histogram and roofline mockups in the design doc §06 are *spec input* for Phase 2.3; do not implement them in 2.1.
- **Diff mode** (`⇋ Compare` toolbar button). Locked decision §1.5/4 pins the visual (merged delta table with `▼` / `▲` glyphs), but the underlying `BenchKit.RunDiff` is already implemented. Phase 2.1 may leave the toolbar button disabled with "Coming in 2.2" tooltip OR omit the button entirely — agent's call based on how cleanly the toolbar arrangement reads. Don't implement the mode.

**Phase 2.2 territory:**

- **Additional op families**: L2 distance², cosine, normalize-OOP, normalize-IP (Mutating), AXPY (Mutating), Top-K (Async), pairwiseDistances (Async), distanceMatrix (Async). Each becomes its own `WorkloadFamily`.
- The set-based Top-K verification protocol from spec §5 lands with the Top-K family.
- Diff mode implementation (the visual is locked; the wiring isn't).

**Phase 2.3+ territory:**

- The four deferred chart compositions, this time actually rendered.
- VectorAccelerate (Metal kernels), Metal Performance Counters.
- MetricKit energy + PMC memory bandwidth.
- VectorIndex vs FAISS (C++ bridge).
- EmbedKit end-to-end.

**Stop and ask if you find yourself starting any of the above before 2.1 closes.**

---

## 7. How to start

1. Read `docs/design/phase-2.1-design.html` — the visual source of truth. Then read this doc (you're here).
2. Read `docs/phase-2.0-plan.md` §8 — confirms what's on disk and what tools exist.
3. `cd Packages/BenchKit && swift test` — confirm 67 pass. Repeat for VSBCore (17) and VSBRun (3).
4. Run the CLI once to populate the run store with smoke data:
   `swift run --package-path Packages/VSBRun vsb-run --preset smoke --skip-peaks --filter dot --filter naive`
5. **Implement in the order in §2.5.** Highlights:
   - Item 0 (design system) is the foundation — every later item references it.
   - At step 3 of the build order you **pause for the user** to add the three local SwiftPM dependencies in Xcode (File → Add Package Dependencies → Add Local… → BenchKit / VSBCore / VSBRun). Do not edit `project.pbxproj` directly.
   - Commit each sub-item as it lands; don't accumulate multi-item commits.
6. Push to `main` as you go. Update §8 of this doc with the commit list + final test count when 2.1 closes.

If anything reads ambiguous, **stop and ask before guessing.** The §1.5 locked decisions are *not* ambiguous — they're locked. Everything else is fair game to surface.

---

## 8. State at end of Phase 2.1

*(To be filled in by the agent that completes 2.1. Include commit hashes, final test count, and any in-flight follow-ups that should flow to 2.2.)*
