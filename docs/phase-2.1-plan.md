# Phase 2.1 — First UI surface

**Status when this doc was written:** Phase 2.0 closed `47fcaa4`. 87 tests pass across BenchKit + VSBCore + VSBRun. The CLI writes complete `RunDocument`s to `~/Library/Application Support/VectorSuiteBench/` but nothing reads them back into a UI. The Xcode app target (`VectorSuiteBench.app`) is still the empty default template that came with `xcodebuild new`.

Phase 2.1 closes that gap. **Five UI items + six carry-overs from 2.0.** No new op families, no Metal, no new measurement code — the harness is done; this slice is purely about making a run viewable.

Subsequent slices: 2.2 adds new op families (L2 / cosine / normalize / AXPY / Top-K / pairwiseDistances / distanceMatrix); 2.3+ adds VectorAccelerate/Metal, MetricKit, FAISS.

This doc is the handoff. Assume the next agent has no prior context.

---

## 1. State at start of Phase 2.1

**Repo:** `/Users/goftin/dev/gsuite/VectorSuiteBench` · `main` · GitHub: `gifton/VectorSuiteBench` (push authorized).

**Read first:**
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

## 2. Phase 2.1 scope — five UI items

### Item 1 — Xcode app target wiring + RunStore plumbing

The app target needs to depend on the three packages. Inside Xcode this is "Add Package Dependency → Add Local…" pointing at `Packages/BenchKit`, `Packages/VSBCore`, `Packages/VSBRun` (the last for `RunPreset` parity with the CLI). Then add an `@StateObject RunStoreCoordinator` (or actor-equivalent) that loads `RunStore.defaultStore()` once and exposes the loaded `RunIndex` + per-run `RunDocument` to views.

Acceptance: a smoke test `swift run vsb-run --preset smoke --skip-peaks` followed by launching the app shows the run in the sidebar.

**Files:**
- `VectorSuiteBench/VectorSuiteBench.xcodeproj` (Xcode project edit — add package refs).
- `VectorSuiteBench/Models/RunStoreCoordinator.swift` (new) — `@Observable` wrapper around `RunStore`.
- `VectorSuiteBench/App.swift` (replace template body).

### Item 2 — `RunListSidebar`

`index.json`-backed list. Sortable by date / sha / preset / case count. Click a row → selects that run for the detail view. Empty state when `index.runs.isEmpty` shows a "Run your first benchmark" CTA that opens the Run Config sheet (Item 4).

**Files:**
- `VectorSuiteBench/Views/RunListSidebar.swift`.

### Item 3 — `RunDetailView` (Summary + first chart + case table)

Three sections in one detail view:

1. **Summary block** — hardware fingerprint, build provenance, FPCR state, timer overhead, harness floor, thermal events, completed/total case count.
2. **ThroughputBarChart** — first Swift Charts composition. X = op, Y = GFLOP/s (or GB/s via toggle), grouped by impl. Mode pill (Single-shot · Amortized) always visible. `.approximate` impls render dashed. Filtered by op / impl pickers above the chart.
3. **CaseTable** — sortable table of every `CaseResult`. Columns mirror the CSV header. Per-row "Show raw samples" expands to a tiny inline LatencyHistogramChart (or punts to Phase 2.2's full histogram view).

The CaseTable should be wired so its filter state is shared with the chart's filter pickers — one filter, two consumers.

**Files:**
- `VectorSuiteBench/Views/RunDetailView.swift`.
- `VectorSuiteBench/Charts/ThroughputBarChart.swift`.
- `VectorSuiteBench/Views/CaseTable.swift`.

### Item 4 — `RunConfigView` (Run Config sheet)

Sheet for starting a new run. Bound to `RunController`. UI:
- Preset selector (smoke · standard · full · custom).
- Op / impl multi-select pickers (drive the registry filter).
- Verify toggle (currently always-on; show as locked).
- Live estimate (case count + wall time prediction).
- Cancel / Start buttons.

Start invokes `RunController` in-process with `measurePeaks: true` (unless peaks are already cached for this hardware fingerprint). Progress is reflected by polling `RunStore` for new case files plus a `CancellationToken` exposed via the coordinator.

**Files:**
- `VectorSuiteBench/Views/RunConfigView.swift`.
- `VectorSuiteBench/Models/RunProgress.swift` — `@Observable` progress tracker that watches the run dir.

### Item 5 — First-launch flow

Empty state for `index.json` AND missing `peaks/<fingerprint>.json`:
1. Greeting + "Measure peaks (~30 s)?" CTA → calls `PeakMeasurement.ensureCached`.
2. After peaks land: "Run your first benchmark" → opens Run Config sheet with `.smoke` preselected.

Also re-prompts if `HardwareInventory.probe().fingerprint` changes (new Mac, dual-boot) or `peakMethodVersion` differs from cached.

**Files:**
- `VectorSuiteBench/Views/FirstLaunchView.swift`.

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

Expected test count at 2.1 close: ~95 (87 carried + ~8 new for the `RunStoreCoordinator` + `RunProgress` observable wrappers + chart formatting helpers; the SwiftUI views themselves are mostly tested by eye).

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

**Phase 2.2 territory:**
- Additional op families: L2 distance², cosine, normalize-OOP, normalize-IP (Mutating), AXPY (Mutating), Top-K (Async), pairwiseDistances (Async), distanceMatrix (Async). Each becomes its own `WorkloadFamily`.
- The set-based Top-K verification protocol from spec §5 lands with the Top-K family.

**Phase 2.3+ territory:**
- Remaining four Swift Charts compositions (LatencyHistogram, LatencyPercentile, Roofline, MemoryPressure). 2.1 ships only ThroughputBarChart.
- DiffPaneView — Phase 1 design has it; 2.2 or 2.3 likely. Two-runs comparison + Markdown export.
- VectorAccelerate (Metal kernels), Metal Performance Counters.
- MetricKit energy + PMC memory bandwidth.
- VectorIndex vs FAISS (C++ bridge).
- EmbedKit end-to-end.

**Stop and ask if you find yourself starting any of the above before 2.1 closes.**

---

## 7. How to start

1. Read `docs/phase-2.0-plan.md` §8 (state at end of 2.0) — confirms what's on disk.
2. Read this doc.
3. `cd Packages/BenchKit && swift test` — confirm 67 pass. Repeat for VSBCore (17) and VSBRun (3).
4. Run the CLI once to populate `~/Library/Application Support/VectorSuiteBench/`:
   `swift run --package-path Packages/VSBRun vsb-run --preset smoke --skip-peaks --filter dot --filter naive`
5. Open `VectorSuiteBench/VectorSuiteBench.xcodeproj`. Add local-package dependencies (Item 1).
6. Implement Items 1 → 2 → 3 → 4 → 5 in that order. Items 1 and 5 are bookends; 2/3/4 are the body. Commit each.
7. Push to `main`. Update §8 of this doc with the commit list + final test count.

Estimated work: 4–6 focused sessions. Item 3 is the largest (chart + case table + filter wiring); Items 1, 2, and 5 are mostly plumbing; Item 4 is medium (RunController integration + progress observation).

If anything reads ambiguous, **stop and ask before guessing.**

---

## 8. State at end of Phase 2.1

*(To be filled in by the agent that completes 2.1. Include commit hashes, final test count, and any in-flight follow-ups that should flow to 2.2.)*
