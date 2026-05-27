# Phase 2.2 — Op-family expansion + Diff mode

**Status when this doc was written:** Phase 2.1 closed `025f9d1`. ~222 tests pass across the Xcode app target (~131) and the SwiftPM packages (~91). The app surface lights up end-to-end: first-launch calibration → sidebar grouped by relative date → detail view with the 7-cell summary header + 8-column data table + ThroughputBarChart + window-level toolbar → New Run modal with live estimator → Start invokes `RunController` in-process with full cancellation semantics. The harness is done; the UI is done; the registry still ships only `DotFamily` (~27 cases of dot product).

Phase 2.2 closes that registry gap and lights up the Diff UI. **Six items + a small carry-over set from 2.1.** No Metal, no new charts beyond what already ships, no MetricKit — those all roll to 2.3+.

Subsequent slices: 2.3+ adds VectorAccelerate/Metal, the four deferred chart compositions (LatencyHistogram / LatencyPercentile / Roofline / MemoryPressure), MetricKit energy, PMC memory bandwidth, FAISS bridge, EmbedKit end-to-end.

This doc is the handoff. Assume the next agent has no prior context.

---

## 1. State at start of Phase 2.2

**Repo:** `/Users/goftin/dev/gsuite/VectorSuiteBench` · `main` · GitHub: `gifton/VectorSuiteBench` (push authorized).

**Read first:**
- `docs/phase-1-design.md` — the overarching spec. Critical sections for 2.2:
  - §2.1 — workload protocols (Borrowing / Mutating / Async; all three already plumbed end-to-end through `Runner` + `AsyncRunner`).
  - §2.2 — `WorkloadID` identity rules; `vectorflavor` required iff `impl == .vectorCore`; `api: raw | metric` axis for dot (the only family that needs the api split — `l2dist`, `cosine`, `normalize`, `axpy` have no DistanceMetric-wrapper-with-opposite-sign analog).
  - §5 — verification rules including the set-based Top-K protocol (sqrt-awareness + distance-multiset equality + index-validity re-check).
  - §9 — Phase 1 case matrix: pins op-by-op flavor coverage, sizes, batches, and notes.
- `docs/phase-2.1-plan.md §1.5` — six locked decisions that carry forward into every 2.x slice (sidebar density, mode pill in row, approximate interleaved, merged delta diff visual, hardware popover, color-blind glyphs always layered).
- `Packages/VSBCore/Sources/VSBCore/Registry.swift` — the existing `DotFamily: WorkloadFamily`. The exact pattern to repeat for each new family. Includes the inline flavor coverage map (lines ~46-55).
- `Packages/BenchKit/Sources/BenchKit/Workload/Workload.swift` — three workload protocols. `RunnableWorkload` parent dispatches to the right runner via `runVia(runner:asyncRunner:cancellation:)`.
- `Packages/BenchKit/Sources/BenchKit/Runner/{Runner,AsyncRunner}.swift` — generic `run<W: BorrowingWorkload>`, `run<W: MutatingWorkload>`, and `run<W: AsyncWorkload>` are all implemented and exercised by BenchKit smoke fixtures (`Tests/BenchKitTests/Fixtures/{NormalizeInPlaceSmokeWorkload, AsyncDotSmokeWorkload}.swift`). 2.2 adds **zero** new harness code in BenchKit beyond `Verify/TopKSetVerifier.swift`.

**What 2.2 composes:**

```
Packages/BenchKit/   (71 tests; library)
├── Verify/          ReferenceOracle, ULPWindows, VerificationResult
│                    ↳ 2.2 ADDS: TopKSetVerifier.swift + unit tests
├── Diff/            RunDiff (engine + Markdown export — ALREADY SHIPPED)
├── Runner/          Runner, AsyncRunner, RunController (no changes)
└── ...              everything else stays unchanged.

Packages/VSBCore/    (~17 tests; dot-family only today)
├── Ops/             Dot.swift
│                    ↳ 2.2 ADDS: L2Distance, Cosine, Normalize, AXPY,
│                      TopK, PairwiseDistances, DistanceMatrix
├── Implementations/ DotImpls only today; 2.2 mirrors per new family
├── Oracles/         KahanFloat64Reference for dot only; 2.2 adds the
│                    rest
└── Registry.swift   VSBCoreRegistry.families grows from 1 to 7

VectorSuiteBench/    (app target)
├── Views/           RunDetailView, CaseTable, RunListSidebar, etc.
│                    ↳ 2.2 ADDS: DiffPaneView, RunPickerView,
│                      DeltaTable, DeltaRow (use 2.1's atoms:
│                      DeltaGlyph, NumberCell, etc.)
└── Models/          ↳ 2.2 ADDS: DiffSelection (@Observable model
                       holding {baseline, comparison} run IDs)
```

**What's NOT built** (Phase 2.2 fills these gaps):
- 6 of the 7 op families that Phase 1 §9 specs (everything except dot).
- `BenchKit.Verify.TopKSetVerifier` — the multiset-equality + sqrt-awareness + index-validity machinery from spec §5.
- Diff UI — the `⇋ Compare` toolbar button currently ships disabled with a "Coming in Phase 2.2" tooltip (Item 3d of 2.1). 2.2 flips it on.
- `RunPreset` filter logic for Standard needs trimming (decision §1.5/2 below) to keep wall-clock at ~5-7 min after the registry triples in size.
- `RunConfigEstimator`'s per-case wall-time lookup table is dot-only seeded; 2.2 adds rough estimates for the new families.

---

## 1.5 Locked decisions for Phase 2.2

The 2.1 plan's §1.5 locked six decisions that survive forward (visual / IA / accessibility decisions). 2.2 adds **six more**, resolved up-front via Q&A so items can ship without re-negotiation. As with 2.1's §1.5, do NOT revisit these without raising.

| # | Question | Decision | Rationale to preserve |
|---|----------|----------|------------------------|
| 1 | Item sequencing | **Borrowing → Diff → Mutating → Async (TopK + verifier) → Async (pairwise + distanceMatrix).** | Borrowing-bucket items repeat DotFamily exactly — lowest-risk start that builds registry coverage fast. Diff lands as soon as we have ≥4 op families' worth of rows to compare (real visual delta vs dot-only). Mutating adds the K-input-rotation pattern that the runner already supports but VSBCore hasn't exercised. Async (TopK + verifier) is the highest-risk piece — saved until after the verifier has unit-test coverage and the registry is rich enough that pairwise/distanceMatrix have honest comparators. |
| 2 | VectorCore flavor coverage per family | **Full DotFamily-equivalent coverage.** Each family ships every VectorCore flavor (optimized / generic / dynamic) at every dim where VectorCore exposes a type for it, plus all baselines (Accelerate / simd / naïve) at all 5 sizes. | The whole point of the suite is to keep VectorCore's 3 flavors visibly distinct (per spec §9 correction #3 — "type-erased benchmarking is forbidden"). Trimming the matrix would lose the headline comparison the doc was built to surface. |
| 3 | Preset budget rebaseline | **Re-pin Standard via filter trim; Full grows naturally.** Standard's filter narrows to VectorCore generic + dynamic only (drops the Optimized variants from Standard; they stay in Full). Smoke unchanged. Full uncapped → ~1500 cases / ~90-100 min — explicitly billed as nightly/pre-release. New Standard target: ~250-300 cases / ~7-8 min. | Spec §3 says "the user sees what they're committing to before clicking Start" — keeping Standard runnable in a coffee break preserves that affordance. Full becomes the catch-all without artificial trimming. |
| 4 | `TopKSetVerifier` location | **`BenchKit/Verify/TopKSetVerifier.swift`, built in Item 0 with standalone unit tests.** Item 4 (TopK family) then becomes pure integration — the algorithmically-tricky multiset-equality + sqrt-awareness piece is already validated before the first AsyncWorkload sees it. | Spec §5 codes the verifier as orthogonal to any one consumer — both topK and pairwiseDistances use it. Building it once in BenchKit's Verify namespace keeps it reusable; building it ahead of its first consumer means Item 4's risk is just integration. |
| 5 | Diff baseline-vs-comparison anchor | **Left pane = older run (baseline); Right pane = newer run (comparison).** Delta computed as `comparison - baseline`; `-12%` means newer is 12% faster. User can swap via a "Swap A↔B" button in the diff toolbar. When entering Diff mode from RunDetail, the currently-selected run becomes the *comparison* (right); the picker auto-defaults to the next-newer-in-sidebar run as baseline. | Matches PR-description mental model ("X is faster than its parent"). Chronological default is unambiguous on first glance. The Swap button is the escape hatch for the rare case where the user wants the reverse anchor. |
| 6 | Diff mode empty-state | **Centered card: "Pick a run to compare against."** Shown when Diff mode is active but the baseline is unset (e.g., user clicked ⇋ Compare from a run that has no chronologically-prior sibling, or the auto-pick failed). Matches the 2.1 "Select a run" empty state aesthetically. | Empty card is the lowest-friction option. Dimming the existing table reads as a bug; auto-picking aggressively could hide that the user *wants* a specific baseline. |

### Locked decisions from 2.1 §1.5 that still apply

All six 2.1 locks remain in force for 2.2:

1. 3-line sidebar rows, no compact toggle.
2. Mode pill in every table row.
3. Approximate-math interleaved adjacent to exact counterpart (note: 2.2 ships no approximate impls; the locking matters for chart treatment when 2.3+ adds them).
4. **Merged delta table for diff** — `142 ns [-12% ▼]` style. This IS the Item 2 visual. The 2.1 lock is what Item 2 implements.
5. Hardware fingerprint headline + NSPopover for detail.
6. Color-blind paths: always layer ▼/▲ glyphs, never hue alone. `DeltaGlyph` already does this and 2.2's `DeltaRow` reuses it.

---

## 2. Phase 2.2 scope — sequenced items

Six items, build order in §2.5. Sub-items break each into one-commit increments; each closes with something visible in the running app or a green test target.

### Item 0 — Shared infrastructure

The cross-cutting work that unblocks everything else. Doesn't ship a new family by itself; flips on the foundations.

**0a. `BenchKit/Verify/TopKSetVerifier.swift`.** The multiset-equality + sqrt-awareness + index-validity re-check engine from spec §5. Standalone — takes `(candidateResults: [(Int, Float)], referenceResults: [(Int, Double)], implReturnsSquared: Bool, ulpWindow: UInt32, recomputeDistance: (Int) -> Double) -> VerificationResult`. No dependency on TopK family or any specific dataset shape. Pure function.

**0b. Standard preset filter trim.** Update `RunController` / `RunPreset.standard`'s filter logic (see `Packages/BenchKit/Sources/BenchKit/Runner/RunPreset.swift` and the registry-filter callsite) so that when 2.2 lands all 7 families, Standard naturally lands at ~250-300 cases. Filter rule: at Standard, drop `vectorflavor == "optimized"` (those stay in Full). All baselines + VectorCore generic + dynamic remain.

**0c. `RunConfigEstimator` wall-time table refresh.** The estimator currently has dot-only per-case timings seeded from Phase 2.0 smoke runs. Add coarse per-op estimates for the 6 new families using rough cycles-per-FLOP arithmetic (vector ops 2-5 ns/element at dim 1536; pairwise distances M×N×D × ~1.5 ns; distanceMatrix the same with parallelism factor). Estimates need only be ±50%. The estimator is a transparency aid, not a contract.

**0d. Shared oracle helpers in `VSBCore/Oracles/KahanFloat64Reference.swift`.** The file currently has `referenceDot(_:_:)` only. Add `referenceL2Squared`, `referenceCosine`, `referenceNormalize`, `referenceAxpy`, `referenceTopK` (k=10 nearest by Euclidean), `referencePairwise`, `referenceDistanceMatrix`. Each takes raw `[Float]` buffers per spec §5's buffer convention; each uses Kahan-Neumaier Float64 accumulation. **No candidate workload code yet** — just the references, with unit tests against trivial hand-computed inputs.

**Tests:**
- `TopKSetVerifierTests` — synthetic distance multisets, ties, sqrt vs non-sqrt input modes, index-validity catches via a closure that simulates a "wrong index" case. ~10 tests.
- `OracleReferenceTests` — each new reference function against ~3 hand-computed inputs. ~12 tests.
- `RunConfigEstimatorTests` extended with the new ops; cases-count assertions exact, wall ±50%. ~6 new tests.
- `RunPresetFilterTests` — exercise the Standard filter rule against a synthetic registry containing optimized + generic + dynamic flavors; assert the optimized variants are excluded. ~3 tests.

**Files:**
- `Packages/BenchKit/Sources/BenchKit/Verify/TopKSetVerifier.swift` (new)
- `Packages/BenchKit/Tests/BenchKitTests/TopKSetVerifierTests.swift` (new)
- `Packages/BenchKit/Sources/BenchKit/Runner/RunPreset.swift` (edit — filter logic)
- `Packages/BenchKit/Tests/BenchKitTests/RunPresetFilterTests.swift` (new)
- `Packages/VSBCore/Sources/VSBCore/Oracles/KahanFloat64Reference.swift` (extend)
- `Packages/VSBCore/Tests/VSBCoreTests/OracleReferenceTests.swift` (new)
- `VectorSuiteBench/VectorSuiteBench/Models/RunConfigEstimator.swift` (extend — new ops in the wall-time table)
- `VectorSuiteBench/VectorSuiteBenchTests/RunConfigEstimatorTests.swift` (extend)

---

### Item 1 — Borrowing families

Three isomorphic-to-DotFamily families, no new protocol surface. Each closes when its workloads are registered, oracle-verified, and tests pass.

**1a. `L2DistanceFamily` (`l2dist²`).** Squared Euclidean distance, `Σ(aᵢ - bᵢ)²`. Borrowing. Spec §9:

```
| `l2dist²` | Borrowing | VectorCore (×3 flavors) · `vDSP_distancesq`
                         · `simd_distance_squared` · naïve
            | 64, 256, 512, 1536, 4096 | 1, 100, 10000 |
```

Mirror DotFamily's structure exactly: `L2DistanceFamily: WorkloadFamily` enumerates `NaiveL2DistWorkload`, `AccelerateL2DistWorkload`, `SimdL2DistWorkload`, `VectorCoreOptimizedL2DistWorkload<V>`, `VectorCoreGenericL2DistWorkload<D>`, `VectorCoreDynamicL2DistWorkload`. ~23 cases (slightly fewer than dot — no `api: metric` axis).

**1b. `CosineFamily`.** Cosine similarity, `(a·b) / (‖a‖ · ‖b‖)`. Borrowing. Same impl set + sizes. **Note**: VectorCore has both `Vector.cosineSimilarity` and `CosineDistance.distance(_:_:)`. **Confirm during implementation whether the sign convention differs** (mirror dot's `api: raw | metric` axis if so, otherwise ship `api: raw` only). The Phase 1 case matrix lists cosine without the metric variant — implementation reading is the tiebreak.

**1c. `NormalizeFamily` (out-of-place).** `aᵢ ← aᵢ / ‖a‖₂` returning a new vector. Borrowing. Impl set: VectorCore (×3 flavors) · `vDSP_vnrm2+vDSP_vsmul` composed · `simd_normalize` · naïve. Same 5 sizes.

**Common pattern for each sub-item:**
- One file per family in `Packages/VSBCore/Sources/VSBCore/Ops/<Family>.swift`.
- One file per family in `Packages/VSBCore/Sources/VSBCore/Implementations/<Family>Impls.swift`.
- Registry tie-in: append the family to `VSBCoreRegistry.families`.
- Per-impl correctness test against the Item 0 oracle.
- One integration test that runs a single small case through `RunController` end-to-end and verifies the produced `RunDocument` shape.

**Tests per sub-item:** ~12-15 (5 sizes × ~3 impl-classes per family, plus oracle round-trip, plus registry validation). Total Item 1: ~40 tests.

**Files (per family, mirroring DotFamily):**
- `Packages/VSBCore/Sources/VSBCore/Ops/<Family>.swift` (new — workload structs + factory)
- `Packages/VSBCore/Sources/VSBCore/Implementations/<Family>Impls.swift` (new — concrete impls)
- `Packages/VSBCore/Sources/VSBCore/Registry.swift` (edit — `families += [<Family>()]`)
- `Packages/VSBCore/Tests/VSBCoreTests/<Family>Tests.swift` (new)
- `Packages/VSBCore/Tests/VSBCoreTests/<Family>IntegrationTests.swift` (new — one E2E case)

---

### Item 2 — Diff mode UI

The first place 2.1's `DeltaGlyph` atom + `BenchKit.RunDiff` engine meet user input. Three sub-deliverables.

**2a. `DiffSelection` model + `RunPickerView`.** `@MainActor @Observable final class DiffSelection` with `var baselineRunID: String?` and `var comparisonRunID: String`. Auto-defaults baseline to the next-newer-in-sidebar run on entry per locked decision §1.5/5. `RunPickerView` is a SwiftUI view: two sidebar-row-shaped capsules in the diff toolbar, with a `Swap A↔B` button between them. Each capsule taps to open a `Menu`-backed picker listing runs (chronological order, newest first). Cross-fingerprint runs render greyed-out with a `cpu.mac.fill` icon — selectable, but selecting one transitions to 2c's refusal banner.

**2b. `DeltaTable` view + `DeltaRow`.** Mirrors `CaseTable`'s 8-column manifest from 2.1 but each numeric cell renders as `<comparison-value>  <DeltaGlyph(delta%, polarity: .lowerIsBetter)>`. Missing cells (case present in one run, absent in the other) render `[ N/A ]` in `VSB.Text.lo`. Filter state shared with the existing `CaseTableFilter` so the user can scope the diff to one op family. Builds against `BenchKit.RunDiff.compute(baseline:comparison:)` which returns `[DiffEntry]` keyed by `WorkloadID`.

**2c. Cross-fingerprint refusal + Markdown export + empty-state.** When `baseline.hardware.fingerprint != comparison.hardware.fingerprint`, render the full-card refusal banner ("Cannot compare runs from different hardware fingerprints"). When `baselineRunID == nil`, render the empty-state card from §1.5/6 ("Pick a run to compare against"). When valid, render an `Export Markdown` button in the diff toolbar that calls `RunDiff.markdownExport(...)` (already exists in `Packages/BenchKit/Sources/BenchKit/Diff/RunDiff.swift`) and writes via `NSSavePanel`.

**Toolbar wiring.** `AppToolbar`'s `⇋ Compare` button (currently `.disabled(true)` with "Coming in Phase 2.2" tooltip) flips to enabled. When clicked: `RunDetailView` switches to its Diff layout (DiffPickerView at top, DeltaTable in body). Exit Diff via a second click (the button becomes a toggle) or the toolbar's `← Detail` back-button equivalent.

**Tests:**
- `DiffSelectionTests` — auto-pick baseline logic, swap correctness, cross-fingerprint detection. ~6 tests.
- `DeltaRowDataTests` — synthetic baseline + comparison `CaseResult` pairs → expected `(value, delta%, polarity)` triples. ~4 tests.
- `DiffMarkdownExportTests` — round-trip the existing `RunDiff.markdownExport` output. ~2 tests (mostly already covered by BenchKit's existing tests; just smoke).

**Files:**
- `VectorSuiteBench/VectorSuiteBench/Models/DiffSelection.swift` (new)
- `VectorSuiteBench/VectorSuiteBench/Views/DiffPaneView.swift` (new — container)
- `VectorSuiteBench/VectorSuiteBench/Views/RunPickerView.swift` (new)
- `VectorSuiteBench/VectorSuiteBench/Views/DeltaTable.swift` (new)
- `VectorSuiteBench/VectorSuiteBench/Views/DeltaRow.swift` (new)
- `VectorSuiteBench/VectorSuiteBench/Views/AppToolbar.swift` (edit — flip Compare button to enabled)
- `VectorSuiteBench/VectorSuiteBench/Views/RunDetailView.swift` (edit — Diff mode body switch)
- `VectorSuiteBench/VectorSuiteBenchTests/{DiffSelectionTests, DeltaRowDataTests, DiffMarkdownExportTests}.swift` (new)

Total Item 2: ~12 tests.

---

### Item 3 — Mutating families

First exercise of the `MutatingWorkload` protocol from VSBCore. The runner's K-input-rotation Amortized-mode logic is already tested in BenchKit by `NormalizeInPlaceSmokeWorkload` (fixture-only) — these items make it real in the registry.

**3a. `NormalizeInPlaceFamily`.** `aᵢ ← aᵢ / ‖a‖₂` in place. Mutating. Impl set: VectorCore (×3) · vDSP in-place chain (`vDSP_vnrm2 + vDSP_vsmul` writing back to source) · naïve in-place. Same 5 sizes. The Phase 1 spec §9 case matrix doesn't include `simd_normalize` here because Apple's `simd_normalize` returns a new value (out-of-place semantics); reusing it as in-place would be redundant with the OOP case in Item 1c.

**3b. `AXPYFamily`.** `y ← αx + y`. Mutating. Impl set: VectorCore (×3) · `cblas_saxpy` · naïve. Same 5 sizes. α is held in `CanonicalParams` as `"alpha": "0.5"` so the WorkloadID has a stable identity; the value itself doesn't affect perf.

**Implementation note.** Both families' `makeInputs(count K: Int, rng:)` returns K freshly-randomized vectors so the runner's K-input rotation has independent data to consume. Don't pre-bake a "scratch" buffer — that's the trap spec §2.4 warns against (NaN cascade in tight loops).

**Tests per sub-item:** ~12 (size × impl matrix oracle tests + integration smoke). Total Item 3: ~24 tests.

**Files:** mirror Item 1's per-family structure.

---

### Item 4 — TopK + verifier integration

The first `AsyncWorkload` in VSBCore. The verifier infrastructure is already shipped (Item 0a); this item wires it to a real op family.

**4a. `TopKFamily` skeleton + VectorCore-only first impl.** Define `TopKFamily: WorkloadFamily` and `TopKWorkload: AsyncWorkload`. Initial impl: `VectorCoreTopKWorkload` calling `Operations.findNearest(query:in:k:metric:)`. Single configuration: `k = 10`, candidate counts {1000, 10000, 100000}, query count {1, 100}. Verifies against Item 0's `referenceTopK` via Item 0a's `TopKSetVerifier`.

**4b. Accelerate-heap baseline + naïve baseline.** `AccelerateTopKWorkload` (custom min-heap maintained with `cblas_sdot` distance computation) and `NaiveTopKWorkload` (full sort, take first k). All three impls share the same `TopKSetVerifier` invocation — verifies that tie-breaking differences across impls don't trigger false failures.

**4c. Integration tests + registry.** Append `TopKFamily()` to `VSBCoreRegistry.families`. Add `TopKFamilyIntegrationTests` exercising the full Async path through `AsyncRunner` and producing a valid `CaseResult` on disk. Add `TopKVerificationTests` exercising the runner's verification-failure path (corrupt the naïve impl, confirm the case is reported `.failed` with no perf numbers leaked, mirroring spec §10 acceptance test #9).

**Tests:** ~16 (3 impls × candidate-count + a verifier integration smoke + a fail-path test).

---

### Item 5 — pairwiseDistances + distanceMatrix

The remaining two Async families. Both use `TopKSetVerifier`'s multiset-equality logic for verification (without the index re-check — these ops return distance matrices, not indices), so Item 0a's coverage already includes them.

**5a. `PairwiseDistancesFamily`.** `BatchOperations.pairwiseDistances`. Async. Spec §9: dim ∈ {384, 768, 1536}, M×N ∈ {64×64, 256×256, 1024×1024}. Impls: VectorCore (single-flavor — `BatchOperations` is the API; flavor doesn't apply at this layer) · naïve nested loop. Exercises TaskGroup auto-parallelism — the whole point of using AsyncWorkload here.

**5b. `DistanceMatrixFamily`.** `Operations.distanceMatrix`. Async. Spec §9: dim ∈ {384, 768, 1536}, M×N ∈ {256×256, 1024×1024, 4096×4096}. Impls: VectorCore · Accelerate `cblas_sgemm`-trick (the well-known L2² = ‖A‖² + ‖B‖² - 2A·Bᵀ rewrite) · naïve.

**Wall-time note.** `distanceMatrix` at 4096×4096 with dim 1536 runs into multi-second territory per case; reference verification at that size is the slow path. Standard preset already excludes this case (per spec §3 / 2.1 §1.5 inheritance). Full preset includes it; tests use the 256×256 case at dim 384 to keep CI fast.

**Tests:** ~14 per sub-item × 2 = ~28 total.

**Files:** mirror Item 1's per-family structure. Pay attention to the AsyncWorkload's `makeInput(rng:) async` signature — pre-build all dataset arrays inside the Task tree before timing starts (spec §2.4 #3).

---

## 2.5 Build order + visible milestones

The items above can ship in this sequence. Each step ends in something visible — a new family lighting up in the sidebar's `RunDocument` data, a new column in `CaseTable`, or a new toolbar button.

| # | Step | What's visible after |
|---|------|----------------------|
| 1 | Item 0a — `TopKSetVerifier` + tests | BenchKit's test count climbs from 71 → ~81. Nothing user-visible yet. |
| 2 | Item 0b — Standard preset filter trim | New Run modal's live estimator footer shows the trimmed Standard case count (~280 instead of ~600 once the families ship). |
| 3 | Item 0c + 0d — Estimator table + Oracle helpers | Estimator tests + oracle tests pass. ~+18 tests. |
| 4 | Item 1a — `L2DistanceFamily` registered | `swift run vsb-run --preset smoke` (with smoke filter expanded) produces L2 cases in the run document. App's CaseTable shows L2 rows next to dot. |
| 5 | Item 1b — `CosineFamily` registered | Cosine rows visible. |
| 6 | Item 1c — `NormalizeFamily` registered | Normalize-OOP rows visible. **First moment the registry is wide enough that Diff has interesting deltas.** |
| 7 | Item 2a — `DiffSelection` + `RunPickerView` | ⇋ Compare button still disabled but the picker view renders standalone in a SwiftUI Preview. |
| 8 | Item 2b — `DeltaTable` rendering | Clicking ⇋ Compare (still wired carefully) renders the delta table against two runs. |
| 9 | Item 2c — Cross-fingerprint refusal + Markdown export + empty-state + toolbar flip | **⇋ Compare button enabled in production. Diff mode complete.** |
| 10 | Item 3a — `NormalizeInPlaceFamily` registered | Normalize-IP rows visible. First MutatingWorkload in VSBCore exercised end-to-end. |
| 11 | Item 3b — `AXPYFamily` registered | AXPY rows visible. |
| 12 | Item 4a — `TopKFamily` (VectorCore-only) | First AsyncWorkload in VSBCore. Top-K cases produce results; verifier runs in `TopKSetVerifier` path. |
| 13 | Item 4b — TopK Accelerate + naïve impls | Top-K rows for all 3 impls; multiset-equality verifier confirms ties don't trip false failures. |
| 14 | Item 4c — Integration + verification-failure smoke | Full TopK family in the registry. ~+16 tests. |
| 15 | Item 5a — `PairwiseDistancesFamily` registered | pairwiseDistances rows visible in CaseTable. |
| 16 | Item 5b — `DistanceMatrixFamily` registered | **Phase 2.2 COMPLETE.** Standard preset runs all 7 families. Diff mode renders. ~310-350 tests pass. |

**Sequencing rationale:** Item 0 unblocks every later item. Item 1's three sub-items can land in any internal order (they're independent) but the listed order (L2 → cosine → normalize-OOP) matches Phase 1 §9 case-matrix order. Item 2 (Diff) requires Item 1 at minimum to have interesting cross-family deltas. Items 3, 4, 5 are independent of each other once Item 0 lands; the recommended order matches §1.5/1 (Mutating before Async to defer the highest-risk piece).

**If a session has to skip ahead**, the only blocking dependency chain is: Item 0a → Item 4a (TopKSetVerifier consumed by TopKWorkload). Items 1, 3, 5 only need Item 0d (oracles). Item 2 only needs Item 1 (registry width). Item 0b, 0c can land any time before 2.2 closes; they're polish on the New Run estimator.

Estimated work: 10-15 focused sessions. Item 0 is the largest (4 sub-items + ~20 tests). Item 1 + Item 3 are isomorphic-to-DotFamily, mostly mechanical. Item 2 (Diff UI) is the most design-pressure-bearing item. Item 4's TopK integration is the highest-risk single sub-item (AsyncWorkload + verifier wiring).

---

## 2.6 Test strategy

Phase 2.2 adds ~90-130 tests on top of the ~222 baseline (target: ~310-350 total). The decomposition:

| Item | Tests added | Type |
|------|-------------|------|
| 0a `TopKSetVerifier` | ~10 | Pure unit tests (multiset, ties, sqrt, index-validity, edge cases) |
| 0b Preset filter trim | ~3 | Synthetic-registry filter tests |
| 0c Estimator extension | ~6 | Cases-count exact, wall ±50% |
| 0d Oracle helpers | ~12 | Each reference function against hand-computed inputs |
| 1a-1c Borrowing families | ~40 | Per-impl correctness + 1 E2E smoke per family |
| 2 Diff UI | ~12 | DiffSelection logic + DeltaRow data + Markdown export round-trip |
| 3a-3b Mutating families | ~24 | Per-impl correctness + E2E smoke per family |
| 4a-4c TopK + verifier integration | ~16 | 3 impls × candidate-count + verification-fail path |
| 5a-5b pairwiseDistances + distanceMatrix | ~28 | Per-impl correctness + E2E smoke |
| **Total new** | **~151 max, ~115 target** | |

The estimator is intentionally above 130 because per-impl correctness tests across the size × flavor matrix add up; if a sub-item's test counts grow above its target, that's a signal that the family has more shape coverage than DotFamily and should be flagged.

**What gets tested:**
- Each new oracle reference function against hand-computed trivial inputs (e.g., `referenceL2Squared([1,2,3], [4,6,8])` against `25` exact).
- Each candidate impl across {smallest size, largest size} against the oracle within shape-dependent ULP windows. NOT every size — the runner's verification step catches all-size correctness in the E2E path.
- TopKSetVerifier exhaustively: empty multiset, single element, all ties, mixed ties, missing index, wrong index, sqrt-mode vs non-sqrt-mode.
- Diff UI logic (selection, swap, cross-fingerprint detection); NOT the SwiftUI rendering.
- Registry validation: assert no duplicate WorkloadIDs across families, every workload has a non-nil oracle (except NullWorkload), `vectorflavor` present iff `impl == .vectorCore`.

**What's NOT tested:**
- SwiftUI views themselves — visual review via app builds and user testing on physical hardware (per 2.1 user preference: no SwiftUI #Preview blocks in new view files).
- Cross-process e2e (the existing `RunControllerIntegrationTests` covers the in-process E2E path).
- Performance assertions — perf data is for visual review, not pass/fail (per spec §6 methodology).

---

## 3. Phase 2.1 carry-overs (fold in if convenient)

Non-blocking. Land any that you touch the affected code for.

### Carry-over A — `CalibrationStatusTests.swift` pre-existing compile error

Pre-existing from before 2.1 work; predates this slice. cmd-U from the Xcode IDE works (presumably via scheme-level framework linking), but `xcodebuild ... test` from CLI fails at the test-target link step trying to find BenchKit symbols. Doesn't block any item. Worth diagnosing as a cleanup pass — likely a missing framework reference in the test target's "Link Binary With Libraries" build phase that the IDE auto-fixes but the CLI exposes.

### Carry-over B — Streaming row treatment for `.inflight`

The `VerificationDisplayState.inflight` seam shipped in 2.1's Item 3b (CaseTable), but no streaming behavior wires it. `RunInvocation` runs the case loop in a Task; while in-flight, the current case's row should render with a trailing `⋯` pill (per 2.1 design doc §4) and animate as the verification + sampling phases proceed. Defer to 2.3 unless touching the table for unrelated reasons.

### Carry-over C — Manual re-calibrate button

Currently peaks calibration only happens at first launch or when the fingerprint changes. A "Re-calibrate Peaks" button in the toolbar would let the user force a re-measure (useful if the cached peaks/<fp>.json was measured under thermal stress). Small surface; ~20 LOC + a Settings menu item.

### Carry-over D — `docs/libraries/*.md` cleanup

Pre-existing untracked files from 2026-05-11 that survived Phases 1.5 / 2.0 / 2.1. Either stage them at the start of 2.2 (if still relevant) or `git rm` them. Don't let them keep showing up in `git status` indefinitely.

### Carry-over E — Mid-run cancellation e2e test

The cancellation tests in `RunControllerIntegrationTests.swift` + `RunInvocationIntegrationTests.swift` pre-cancel via the token. A proper mid-run test — start the run, wait until ~2 cases are complete via polling, cancel, verify the partial document has the expected number of cases + a `.truncated` flag on the in-flight one — wasn't added because subprocess SIGINT delivery is timing-sensitive. Worth attempting in 2.2 once Item 4's AsyncWorkload paths land, since the polling pattern has more places to interleave with.

### Carry-over F — `RunListSidebar` empty-state CTA wiring

The 2.1-shipped empty state currently shows "Run your first benchmark" but the CTA doesn't deep-link into the New Run modal. Small fix — add a `Button` with the `+ New Run` toolbar action wired through.

---

## 4. Validation

```bash
# Existing 222 tests still pass.
cd Packages/BenchKit && swift test    # 71 → ~95 after Item 0a
cd Packages/VSBCore  && swift test    # 17 → ~130 after Item 5
cd Packages/VSBRun   && swift test    # 3   (unchanged)

# App target builds clean.
xcodebuild -project VectorSuiteBench/VectorSuiteBench.xcodeproj \
           -scheme VectorSuiteBench -configuration Release build

# E2E smoke: run a Standard preset, verify all 7 families produce CaseResults.
swift run --package-path Packages/VSBRun vsb-run --preset standard --skip-peaks
# Expected output: ~280 cases (Standard trimmed per §1.5/3); RunDocument
# contains rows for dot, l2dist, cosine, normalize-OOP, normalize-IP, axpy,
# topK, pairwiseDistances, distanceMatrix.

# E2E smoke: open the app, run a Smoke preset, click ⇋ Compare against a
# prior smoke run, verify Diff UI renders.
open VectorSuiteBench/VectorSuiteBench.xcodeproj
```

Expected test count at 2.2 close: **~310-350** (~222 carried + ~90-130 new).

---

## 5. Conventions to follow

(Reaffirming from 2.1 plus any new 2.2-specific items.)

- **Swift Testing** (`@Suite`, `@Test`, `#expect`, `#require`, `Comment(rawValue:)` for failure messages — NOT plain strings when interpolating).
- **`@MainActor @Observable final class`** — pattern for UI state (e.g., `DiffSelection`).
- **`nonisolated enum`** — for pure-function namespaces (e.g., `RunPresetFilter.standardFilter(_:)`).
- **All colors via `VSB.*` tokens; radii via `VSB.Radius.*`** (.swatch/.pill/.chip/.card). No raw hex; no SwiftUI `.cornerRadius(8)` literals.
- **One commit per sub-item.** Don't batch.
- **Conventional Commits + multi-paragraph body + Co-Authored-By trailer** (`Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).
- **Push to main authorized.** If the auto-classifier blocks, ask the user.
- **`borrowing Input` requires struct, not tuple** (Swift 6 constraint; bit them once in 2.0).
- **`BenchClock`, not `Clock`** (BenchKit's clock type is `BenchClock` to avoid Foundation's `Clock` confusion).
- **WorkloadID identity rules sacred** — bump `SchemaVersion.minor` on any additive change; never rename a wire-name without a migration.
- **`ImplClass` is algorithm shape, not library identity.** Don't conflate `.standard` with "is this an Apple library".
- **`WorkloadFamily`-pattern for any new registry surface.** Phase 2.2 adds 6 more families — each follows the DotFamily template line for line.
- **Sendable everywhere.** `OSAllocatedUnfairLock<T>` for mutable state shared across actors.
- **SwiftUI views in the app target only.** Packages have NO `import SwiftUI`. The app reads `RunDocument` / `CaseResult` / `WorkloadID` from BenchKit; new Diff views construct from those types directly.
- **`@Observable` over `ObservableObject`.**
- **Charts render on completion, not mid-run** (spec §3); no live updates while sampling. Diff mode is post-hoc by definition.
- **NO SwiftUI `#Preview` blocks in new view files.** User validates on physical-device runs, not Previews. (Per 2.1 user preference.)
- **Ask decisions before coding** at every item — pattern from 2.1. Pose `AskUserQuestion` rounds at sub-item boundaries when design ambiguity surfaces.
- **Review after each item, then polish** before moving on. 2.1's "implement → review → polish → next" cadence stays.
- **§1.5 locked decisions (both 2.1's six and 2.2's six) are sacred.** Do not revisit; if you find yourself wanting to, stop and ask the user.

---

## 6. What Phase 2.2 explicitly does NOT include

The spec specs the full chart suite + Metal + MetricKit + FAISS + EmbedKit; that breadth is for 2.3+, not 2.2.

**Deferred to 2.3:**

- **Four deferred chart compositions** — `LatencyHistogram`, `LatencyPercentile`, `Roofline`, `MemoryPressure`. Currently render `"Coming in 2.3"` placeholders inside the Table/Charts toggle (shipped in 2.1's Item 3c). 2.2 does NOT promote any to real charts.
- **Streaming row treatment for `.inflight`** (Carry-over B above). The seam exists; the polling wiring does not.
- **VectorAccelerate / Metal** integration. New library; new package; new shaders. Out of scope.
- **MetricKit energy capture.** Spec §0 deferred to "alongside Metal" — Phase 2.3 territory.
- **PMC memory bandwidth instrumentation.** Same Phase 2.3 territory.

**Deferred to 2.4+ / later phases:**

- **VectorIndex vs FAISS** (C++ bridge). Phase 3.
- **EmbedKit end-to-end.** Phase 4.
- **ANE occupancy.** Phase 4 with EmbedKit.
- **Automatic regression alarms / CI integration.** Any later phase. Diff stays human-driven in 2.2.
- **Headless CLI executable target.** Already exists (`vsb-run`); 2.2 doesn't add functionality beyond the new families lighting up naturally.

**Stop and ask if you find yourself starting any of the above before 2.2 closes.**

---

## 7. How to start

1. Read this doc end-to-end.
2. Read `docs/phase-1-design.md` §2.1 (workload protocols), §5 (verification rules + TopKSetVerifier protocol), §9 (case matrix).
3. Read `Packages/VSBCore/Sources/VSBCore/Registry.swift` + `Packages/VSBCore/Sources/VSBCore/Ops/Dot.swift` + `Packages/VSBCore/Sources/VSBCore/Implementations/DotImpls.swift` — the exact template.
4. `cd Packages/BenchKit && swift test` — confirm 71 pass. Repeat for VSBCore (17) and VSBRun (3).
5. **Implement in §2.5's order.** Highlights:
   - Item 0 unblocks every later item; build it first.
   - Item 4a is the highest-risk single sub-item (first AsyncWorkload in VSBCore + first verifier integration). Don't skip the standalone verifier tests in 0a — they're load-bearing.
   - Each sub-item is one commit; no batching.
6. Push to `main` as you go. Update §8 of this doc with the commit list + final test count when 2.2 closes.

If anything reads ambiguous, **stop and ask before guessing.** The §1.5 locked decisions (2.1's six + 2.2's six = twelve total) are *not* ambiguous — they're locked. Everything else is fair game to surface.

---

## 8. State at end of Phase 2.2

*(To be filled in by the agent that completes 2.2. Include commit hashes, final test count, the actual Standard-preset case count after Item 0b's filter lands, and any in-flight follow-ups that should flow to 2.3.)*
