# VectorSuiteBench — Phase 1 Design

## Context

`VectorSuiteBench` is a comprehensive benchmarking suite for a group of Swift/Metal libraries built for high-throughput computation on Apple Silicon:

- **PipelineKit** — `/Users/goftin/dev/gsuite/PipelineKit` (NOT used as harness; see §0)
- **VectorCore** — `/Users/goftin/dev/gsuite/VSK/VectorCore` (Phase 1 target)
- **VectorAccelerate** — `/Users/goftin/dev/gsuite/VSK/future/VectorAccelerate` (Phase 2)
- **EmbedKit** — `/Users/goftin/dev/gsuite/VSK/EmbedKit` (Phase 4)
- **VectorIndex** — `/Users/goftin/dev/gsuite/VSK/VectorIndex` (Phase 3)

Each library already ships its own local benchmarks. This suite is **not** a replacement — it is a **cross-library, comparative harness** that runs them under one roof, adds head-to-head competitor baselines (Apple Accelerate / vDSP / BLAS in Phase 1; FAISS in Phase 3), and adds richer metrics (latency distributions, derived memory bandwidth, energy in later phases, GPU/ANE occupancy in later phases) with first-class visualization (live Swift Charts) and persistent run history.

The repo currently contains a fresh Xcode macOS app target (`VectorSuiteBench.app`). The macOS app shape is intentional: it gives clean access to `os_signpost`, MetricKit (later), Metal Performance Counters (later), and lets us ship Swift Charts visualizations directly with the runner.

**Scope of this spec: Phase 1 only.** Phase 1 delivers the shared measurement harness + the first concrete library target: VectorCore micro-ops compared against Apple's vDSP/BLAS, a naïve Swift baseline, and Apple's `simd` framework. Later phases (Metal/VectorAccelerate, VectorIndex vs FAISS, EmbedKit end-to-end, MetricKit energy, memory bandwidth via PMC counters, GPU/ANE occupancy) are out of scope here and will each get their own spec built on top of Phase 1's harness.

---

## §0 — Design Decisions (locked)

| Decision | Choice | Notes |
|---|---|---|
| Deployment | macOS app (keep current Xcode project) | Unlocks signposts, MetricKit, Metal counters in later phases. |
| Orchestration | Purpose-built; **no PipelineKit, no command-bus pattern** | PipelineKit's ~1–10 µs/op overhead is fatal for sub-µs SIMD micro-ops. |
| Phasing | Phase 1 = harness + VectorCore vs Apple Accelerate only | Subsequent libraries get their own specs reusing the harness. |
| Baselines (Phase 1) | VectorCore (default config) · Apple Accelerate (vDSP/BLAS) · naïve Swift loop · Apple `simd` framework (`simd_dot`, `simd_length_squared`, …) | `swift-numerics` removed: it provides `Real`/`Complex` protocols + `Float16`, not BLAS. Wrong baseline class for dense linear algebra. |
| Reporting (Phase 1) | Live in-app Swift Charts **+** JSON/CSV export | App is also the analysis tool, not just a runner. |
| Energy / MetricKit | **Deferred to Phase 2.** Live memory-pressure tracing **is** in Phase 1. | Energy comparisons get meaningful once GPU lands. |
| AsyncWorkload | **Promoted to Phase 1** (was: deferred to Phase 2+). Async-first APIs (`Operations.findNearest`, `Operations.distanceMatrix`, `BatchOperations.*`) cannot be benchmarked honestly through a sync wrapper — TaskGroup-based parallelism becomes invisible. | Sync `BorrowingWorkload`/`MutatingWorkload` retained for raw kernels and `DistanceMetric` closures. |
| Measurement modes | Always report **both** single-shot and **Amortized** per case (no auto-switch). | "Amortized" replaces earlier "Batched" name to avoid collision with VectorCore's `BatchOperations` API. Mode always visible on every chart. |
| Stance | Median + tail percentiles only. No mean. No outlier trimming. | Explicit disagreement with XCTMetric / Google Benchmark / Criterion conventions; documented in §6. |
| Reference oracle | Kahan/Neumaier compensated summation in **Float64**, mandatory for every dense-FP workload | |
| Schema | Versioned JSON on disk; migration registry on raw `Data`; CSV is export-only | |

---

## §1 — Package Layout

```
VectorSuiteBench.xcodeproj                       (existing macOS app target — SwiftUI shell)
└── Packages/
    ├── BenchKit/                                (SwiftPM, pure Foundation + os + simd)
    │   ├── Sources/BenchKit/
    │   │   ├── Workload/         Workload.swift, AsyncWorkload.swift, WorkloadID.swift, WorkloadMetadata.swift
    │   │   ├── Runner/           Runner.swift, AsyncRunner.swift (skeleton), RunPreset.swift, WallClockBudget.swift, Cancellation.swift
    │   │   ├── Clock/            Clock.swift, TimerCalibration.swift
    │   │   ├── Stats/            LatencyDistribution.swift, AmortizedResult.swift, BandwidthEstimator.swift
    │   │   ├── Probes/           MemoryProbe.swift, ThermalProbe.swift, SignpostEmitter.swift, NullWorkload.swift
    │   │   ├── IO/               Reporter.swift, RunStore.swift, RunDocument.swift, SchemaVersion.swift, MigrationRegistry.swift, CSVExporter.swift
    │   │   ├── Verify/           ReferenceOracle.swift, VerificationResult.swift, ULPWindows.swift
    │   │   ├── Hardware/         HardwareInventory.swift, PeakMeasurement.swift (FMA + STREAM)
    │   │   ├── Provenance/       BuildProvenance.swift, GitProvenance.swift, FPCRState.swift
    │   │   ├── Seeds/            SplitMix64.swift, SeedTable.swift, InputDistribution.swift
    │   │   └── Util/             BlackHole.swift, ReleaseGuard.swift
    │   └── Tests/BenchKitTests/
    ├── VSBCore/                                 (depends on BenchKit + VectorCore + Accelerate; uses Apple `simd` from system)
    │   ├── Sources/VSBCore/
    │   │   ├── Ops/              Dot.swift, L2Distance.swift, Cosine.swift, Normalize.swift, AXPY.swift, TopK.swift, PairwiseDistances.swift, DistanceMatrix.swift
    │   │   ├── Implementations/  VectorCoreImpl.swift, AccelerateImpl.swift, NaiveImpl.swift, SimdImpl.swift
    │   │   ├── Oracles/          KahanFloat64Reference.swift
    │   │   └── Registry.swift    declarative case enumeration
    │   └── Tests/VSBCoreTests/   correctness vs reference; round-trip canonicalization tests
    └── (future)  VSBAccelerate/  VSBIndex/  VSBEmbedKit/
```

**Invariants:**
- BenchKit imports nothing about the libraries under test.
- Suites packages have **no SwiftUI imports** and **no UI types**. Headless.
- App depends on packages, never the reverse.
- Naming rule: `VSB<X>` = benchmark suite targeting library `<X>` (or `Vector<X>`).
- All three buildable as Release with `-O` for measurement runs. Release-build guard (§7) refuses Debug-built measurement runs.

A future headless CLI is a new SwiftPM executable target inside BenchKit linking the same suites — no harness rewrite.

---

## §2 — Measurement Core

### 2.1 Workload protocols (three siblings)

```swift
public protocol WorkloadMetadata: Sendable {
    var identifier: WorkloadID { get }
    var bytesMoved: Int { get }
    var flops: Int { get }
    var inputDistribution: InputDistribution { get }
    var referenceOracle: ReferenceOracle? { get } // mandatory for dense FP ops
    // ULP tolerance is computed by `ulpTolerance(op:implClass:shape:)` (§5) — shape-dependent, not a constant.
}

// 1) Read-only inputs (dot, l2dist, cosine, normalize-out-of-place, ...).
//    Swift 6 `borrowing` ensures same input is safely reused across all K Amortized iterations.
public protocol BorrowingWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output
    func makeInput(rng: inout SplitMix64) -> Input
    func invoke(_ input: borrowing Input) -> Output
}

// 2) Mutating inputs (axpy, in-place normalize). Amortized runner pre-allocates K
//    independent inputs and rotates per iteration — re-using one input causes
//    drift / NaN cascade over thousands of iterations, which triggers microcode
//    penalties and corrupts latency measurements.
public protocol MutatingWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output
    func makeInputs(count K: Int, rng: inout SplitMix64) -> [Input]
    func invoke(_ input: inout Input) -> Output
}

// 3) Async / actor-bound entry points whose performance depends on internal
//    parallelism (Operations.findNearest, Operations.distanceMatrix,
//    BatchOperations.pairwiseDistances, BatchOperations.findNearest, ...).
//    Sync wrappers would defeat the TaskGroup-based parallelism we're trying
//    to measure. Async/throws overhead is acceptable because these ops are
//    large-grained by definition (≥ µs).
public protocol AsyncWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output
    func makeInput(rng: inout SplitMix64) async -> Input
    func invoke(_ input: inout Input) async throws -> Output
}
```

**Notes:**
- **Protocol choice is enforced at compile time.** No "mutatesInput: Bool" runtime flag — the type system tells the runner which dispatch path to use, and a mis-classified workload fails to compile against the wrong runner overload.
- `bytesMoved` / `flops` are author-declared. Harness derives GB/s and GFLOP/s from them.
- `inputDistribution` declared per workload (`.uniform`, `.normal`, `.embeddingLike(σ)`, `.adversarial(.denormals|.zeros|.NaNs)`). Phase 1 uses `.uniform` for all standard cases but the seam is real.
- ULP tolerance is shape-dependent — see §5 for the `ulpTolerance(op:implClass:shape:)` function.

### 2.2 WorkloadID

```swift
public struct WorkloadID: Hashable, Codable, Sendable {
    let op: OpKind           // .dot, .l2dist, .cosine, .normalize, .axpy, .topK,
                             // .pairwiseDistances, .distanceMatrix                              (closed enum)
    let impl: ImplKind       // .vectorCore, .accelerate, .naive, .simd                          (closed enum)
    let implClass: ImplClass // .standard, .approximate
    let dtype: DType         // .f32 (Phase 1)
    let shape: Shape         // .vector(n), .pairwise(b, n), .matrix(b, n)
    let params: CanonicalParams
}
```

**`CanonicalParams` mandatory keys for vector ops:**
- `vectorflavor`: required **iff `impl == .vectorCore`**. One of `optimized` | `generic` | `dynamic` — distinguishes `VectorNOptimized` (SIMD4-laid-out fused-kernel path), `Vector<DimN>` (generic), and `DynamicVector(dimension: N)` (heap-backed). These have **wildly different perf** and must never collapse into one `WorkloadID`. VectorCore's docs explicitly warn against type-erased benchmarking; this param exists to honor that warning. **Absent for non-VectorCore impls** — `cblas_sdot`, `simd_dot`, and the naïve baseline consume a raw `[Float]` buffer and have no flavor concept; canonicalizer rejects `vectorflavor` if present alongside `impl != .vectorCore`.
- For `dot` specifically: `api`: one of `raw` | `metric`. Distinguishes `Vector.dot()` (returns `+a·b`) from `DotProductDistance.distance(_:_:)` (returns `−a·b`, negated for min-search ordering). Both are public, both benchmarked, but mixing them silently is a verification-failure waiting to happen. Applies to `impl == .vectorCore` only; other impls implicitly produce `+a·b` and oracle is wired to that.

**Identity rules (locked):**
- `params` is a typed `CanonicalParams` wrapper, **not** `[String: String]`. Construction normalizes keys (sorted, lowercased) and separators (`:`). Round-trip canonicalization test required for every registered workload, **including the `vectorflavor` and `api` axes above**.
- Renaming an enum case = breaking schema change. Wire-names are **frozen forever** via `@CodableKey` aliasing; only Swift identifiers may evolve.
- `WorkloadID` is the primary dedup key across runs. The diff view pairs cases by `WorkloadID`; anything else is apples-to-oranges and refused.

### 2.3 Clock & timer calibration

```swift
public struct Clock {
    let timebase: mach_timebase_info_data_t
    @inline(__always) func now() -> UInt64 { mach_absolute_time() }
    func nanos(_ delta: UInt64) -> UInt64
}
```

Startup runs ~10 000 back-to-back `mach_absolute_time` reads; the median Δ is the `timerOverheadNanos`, **recorded in the run manifest as context metadata only**.

**Critical: timer overhead is NEVER subtracted from per-sample single-shot values.** At the ~41.6 ns Apple Silicon timebase resolution (24 MHz), subtracting a similarly-sized overhead from a fast op produces zero or negative latency — manifestly wrong. Overhead correction applies only at the **Amortized aggregate** level (where total loop time ≥100 µs renders the per-iteration overhead a sub-1 % effect that washes out arithmetically) and is presented as a chart annotation, never folded into raw samples.

**Known resolution floor on Apple Silicon: ~41.6 ns** (24 MHz timebase). Ops <~50 ns single-shot are unmeasurable in single-shot mode — Amortized is the only honest signal at that scale. The mode is always recorded in `CaseResult`.

### 2.4 Runner — measurement protocol per case

1. **Build input(s)** with `SplitMix64` seeded from the **SeedTable** keyed by `WorkloadID` (§7). Same seed → same bytes across impls, runs, machines.
   - `BorrowingWorkload`: one input, reused across all iterations (single-shot and Amortized).
   - `MutatingWorkload`:
     - **Single-shot mode**: `makeInputs(count: N, rng:)` produces N fresh inputs ahead of time; sample *i* consumes input *i*. The input-build cost lives outside the timing window. Re-using a single mutated input across N samples would drift toward NaN, corrupting later samples.
     - **Amortized mode**: `makeInputs(count: K, rng:)` produces K fresh inputs; the tight loop rotates input `j % K` per iteration. Re-using one input across thousands of iterations triggers severe microcode penalties for denormal/NaN math.
   - `AsyncWorkload`: built inside the Task tree before timing starts; semantics match `BorrowingWorkload` unless the workload also conforms to a mutating variant (out-of-scope for Phase 1).
2. **Verify correctness** against `referenceOracle`. Fail → abort case, no perf numbers (§5).
3. **Warm-up loop**: **100 ms budget AND ≥50 iterations, whichever last** (NOT "whichever first"). Apple Silicon P-core migration + frequency ramp requires ~10–30 ms of sustained load; the previous "whichever first" rule terminated warm-up in microseconds for fast ops and we'd be measuring a down-clocked E-core. The new rule guarantees a real warm CPU before sampling begins.
4. **Thermal gate**: read `ProcessInfo.processInfo.thermalState`. Pause or abort on `.serious` / `.critical` (configurable). Recorded in `CaseResult.thermalEvents`.
5. **Sampling — both modes for cases <1 ms (which is most of Phase 1):**
   - **Single-shot**: time one `invoke` per sample. Default N=1000 (for ops <10 µs), N=100 (<1 ms), N=30 (≥1 ms). Raw nanos retained without overhead correction (see §2.3).
   - **Amortized**: tight K-iteration loop sized so total ≥100 µs (well above clock resolution). Per-loop time recorded; nanos/op = loopTime / K. Timer-overhead correction applies only at this aggregate. **Renamed from "Batched"** to avoid collision with VectorCore's `BatchOperations` namespace.
6. **Anti-DCE**: every `Output` consumed via `BlackHole.consume(_:)` — `@inline(never)` volatile sink. Required (without it `-O` deletes the work). Cost ~2–5 ns/call, recorded in `RunMetadata.harnessOverheadNanos` via the NullWorkload self-bench (§7).
7. **Signposts**: warm-up and sampling phases wrapped with `OSSignpostType.begin/.end` on dedicated log so Instruments traces align.
8. **Memory probe — two-mode to avoid injecting OS jitter into the very samples we measure:**
   - **Single-shot sampling**: snapshot `mach_task_basic_info().resident_size` once before the sample loop and once after. **No continuous sampling** — a 100 Hz background queue would compete for the same SoC and the kernel's brief accounting-structure lock during each `mach_task_basic_info` read is exactly the kind of preemption that shows up as tail-latency jitter in single-shot histograms.
   - **Amortized sampling**: continuous 100 Hz probe on a background queue. The K-iteration loop body (≥100 µs total) amortizes the probe's cost; preemption mid-loop affects loop wall time by sub-1 %.

### 2.5 CaseResult

```swift
public struct CaseResult: Codable {
    let id: WorkloadID
    let singleShot: LatencyDistribution?    // nil if op too long for honest single-shot
    let amortized: AmortizedResult?         // K-iteration loop result; renamed from "batched"
    let bandwidthGBPerSec: Double           // derived from amortized.nanosPerOp
    let gflops: Double                      // derived from amortized.nanosPerOp
    let preSampleRSS: UInt64                // single-shot pre-loop snapshot
    let postSampleRSS: UInt64               // single-shot post-loop snapshot
    let memoryTrace: [MemorySample]         // continuous trace ONLY during Amortized sampling
    let thermalEvents: [ThermalEvent]
    let timerOverheadNanos: Double          // metadata only; not applied to single-shot samples
    let verification: VerificationResult
    let flags: Set<CaseFlag>                // .truncated, .bimodal, .approximate, …
    let runID: String                       // backpointer; HardwareInventory lives in RunMetadata only
}

public struct LatencyDistribution: Codable {
    let samples: [UInt64]                   // sorted nanos, kept raw (≤8 KB / case @ 1000 samples)
    var p50, p99, p999, min, max: UInt64    // computed
}
```

**Raw samples kept, never approximated.** ≤8 KB per case at default sample count; trivial cost, enables any later statistic without re-running.

### 2.6 Concurrency policy (one-page doc, lives in `BenchKit/README.md`)

- **Measurement runs inside a Swift `Task` tree** ("the measurement Task") at QoS `.userInteractive`. Required for `AsyncWorkload`; adopted for sync `BorrowingWorkload`/`MutatingWorkload` too so that **`@TaskLocal` bindings propagate**. Without this, VectorCore's `@TaskLocal Operations.$simdProvider` and `ComputeProvider` silently fall back to defaults and we'd be benchmarking those defaults instead of whatever the workload's `setUp` configured. The hot loop is invoked inside the workload's declared `Operations.$simdProvider.withValue(...) { ... }` (or analogous) binding scope.
- **Memory probe**: background `DispatchQueue` at 100 Hz **only during Amortized sampling** (where the K-iteration loop amortizes the probe's cost). During single-shot sampling: snapshot-only (pre/post loop). Eliminates the OS-jitter contamination that 100 Hz sampling would inject into sub-µs single-shot measurements.
- **No core pinning**: macOS has no public `pthread_setaffinity_np`. The scheduler can migrate the measurement Task between P/E cores, producing occasional bimodal distributions. Recognized, not chased — the histogram view auto-flags bimodal cases (`flags.insert(.bimodal)`).
- **Verification** runs on the measurement Task sequentially before warm-up. For `BorrowingWorkload` / `MutatingWorkload`: a normal synchronous call. For `AsyncWorkload`: the runner `await`s the candidate's `invoke`, then runs the (synchronous) Float64 reference, then compares — all on the measurement Task. Keeps thermal state simple; accepts the wall-time hit on `distanceMatrix` verification (~seconds for large M×N).

### 2.7 Things the runner deliberately does not do

- No outlier trimming. P999 spikes are real data.
- No mean.
- No within-run confidence intervals. Reproducibility comes from multi-run diff, not synthetic CI math on jitter.
- No async/GCD in the hot path.
- No automatic mode switching — single-shot and Amortized both reported when feasible.

---

## §3 — Reporting & Visualization (App target, Swift Charts)

Five canonical chart compositions, all in `/Charts/` in the app target. None depend on BenchKit's internals beyond `CaseResult` / `RunDocument`.

1. **ThroughputBarChart** — X=op, Y=GFLOP/s (or GB/s, toggle), grouped by impl. Mode pill (Single-shot · Amortized) always visible. `.approximate` impls render dashed with "approx" badge.
2. **LatencyHistogramChart** — binned samples for a single `WorkloadID`. X=ns log, Y=count. Overlays at p50/p99/p999/max. Auto-flag annotation on bimodal distributions.
3. **LatencyPercentileChart** — line chart, X=size log, Y=ns log, series per (impl, percentile). The "P99 critical for real-time UI" view.
4. **RooflineChart** — log–log scatter. X=arithmetic intensity (`flops/bytesMoved`), Y=achieved GFLOP/s. Two reference lines: empirical peak compute (horizontal, measured via FMA microkernel) and empirical peak bandwidth (diagonal, STREAM-triad). Subtitle: "Empirical peaks measured on this device — not vendor spec; treat as upper bound."
5. **MemoryPressureChart** — area chart of RSS over wall time, per case. Annotations for thermal events. Leak detector.

### Navigation

```
ContentView
├── RunListSidebar           // index.json-backed; sortable by date/sha/wall-time/preset
├── RunDetail
│   ├── Summary              // hardware, build provenance, timer overhead, thermal summary, harness floor
│   ├── ChartsTabs           // five charts above, filtered by op/impl/size pickers
│   └── CaseTable            // sortable; per-selection CSV export
└── DiffPane                 // pair runs by canonical WorkloadID; Markdown export for PR descriptions
```

**Diff pane refuses to compare across hardware fingerprints** — surfaces a clear error rather than producing a misleading delta.

### Run presets (BenchKit, surfaced in UI)

Presets are **filters over the full registry** plus sampling-and-budget settings. Each preset's filter is pinned here so the wall-clock estimate is reproducible across runs.

```swift
public enum RunPreset: Codable, Sendable {
    case smoke      // ~30s budget; ~40 cases
    case standard   // ~5min budget; ~180 cases
    case full       // ~45min budget; ~600 cases (the full registry)
    case custom(WallClockBudget, SampleCount, [WorkloadID])
}

public struct WallClockBudget: Codable, Sendable {
    let total: Duration
    let perCase: Duration
    let abortPolicy: AbortPolicy   // .skipRemaining | .truncateSamples
}
```

**Smoke filter** (~40 cases, ~30s, single-shot only, 100 samples/case):
- Ops: dot (raw), l2dist, cosine.
- Impls: VectorCore (optimized flavor only), Accelerate, naïve.
- Vector sizes: 512 only.
- Batches: 1 only.
- Excludes all async workloads.

**Standard filter** (~180 cases, ~5min, both modes, 500 samples/case):
- All ops.
- All impls (VectorCore × 3 flavors + Accelerate + simd + naïve where applicable).
- Vector sizes: 256, 1536 (two representative sizes).
- Batches: 1, 100.
- `pairwiseDistances` and `distanceMatrix`: dim 768 only, M=N ∈ {64×64, 256×256}.
- **Standard excludes `distanceMatrix` at 1024×1024 and 4096×4096** — at those sizes a single case takes minutes (Float64 Kahan reference is the bottleneck), blowing the 5-min budget.

**Full filter** (~600 cases, ~45min, both modes, 1000+ samples/case):
- Entire registry. Includes the large `distanceMatrix` cases. This is the nightly / pre-release preset.

`Runner` honors the budget. Truncated cases are flagged (`flags.insert(.truncated)`) and visually marked in every chart. The estimator in the Run Config sheet (below) computes preset-specific case counts and wall-time predictions live from the registry, so the user sees what they're committing to before clicking Start.

### Run config sheet

Live estimate shown before user commits:

```
┌─ New Run ────────────────────────────────────────┐
│  Preset:   [ Smoke  Standard  Full  Custom ]      │
│  Ops/Impls/Sizes/Modes  (multi-select)           │
│  Verify:   ☑ require numerical pass               │
│  Budget:   [ 5 min ]   Abort: [ skip remaining ] │
│                                                    │
│  Estimated:  ~180 cases · ~4m 50s · ~6 MB JSON   │
│              [ Start Run ]                         │
└──────────────────────────────────────────────────┘
```

### What reporting deliberately does not do

- No mean anywhere.
- No automatic regression alarms. Diff is human-driven in Phase 1.
- No live chart updates mid-run; charts render on run completion/truncation.

---

## §4 — Persistence

### Directory layout

```
~/Library/Application Support/VectorSuiteBench/
├── index.json                                   # fast app-launch manifest
├── runs/
│   └── 2026-05-10T22-13-00Z__abc1234__standard/
│       ├── manifest.json                        # RunDocument header (no case data)
│       ├── cases/<workloadIDHash>.json          # one file per case
│       ├── memory/<workloadIDHash>.csv          # per-case memory traces
│       ├── samples.csv                          # human-eyeballable rollup
│       └── README.txt                           # auto-written hardware/build/preset summary
└── peaks/<hardwareFingerprint>.json             # cached empirical peak compute + bandwidth
```

**Why one file per case** (not one big run.json):
- Atomicity — a case finishes, write its file. A crash leaves a valid partial run, not a corrupt JSON.
- Diff view loads only the cases it needs.
- Per-case files are friendlier to git/vimdiff for spot-checking.

**Atomic write protocol:** temp file → `fsync` → `rename(2)`. APFS-atomic. Readers never see half-written cases.

### index.json

Sidebar-feeding manifest of all runs. Updated atomically (temp+rename) after each run completes. Schema includes `runID`, `timestamp`, `gitSha`, `branch`, `preset`, `caseCount`, `completedCaseCount`, `wallTimeNanos`, `thermalEscalations`, `hardwareFingerprint`.

### peaks/<fingerprint>.json

```json
{
  "schemaVersion": "1.0",
  "hardwareFingerprint": "M3Max-14C-30G-36GB",
  "measuredAt": "2026-05-09T18:02:11Z",
  "peakComputeGFLOPS": 380.4,         // single-P-core register-resident FMA microkernel, Float32
  "peakBandwidthGBPerSec": 312.0,     // STREAM-triad multi-thread
  "method": { "compute": "fma-microkernel-v1", "bandwidth": "stream-triad-v1" }
}
```

Method versions stored; stale-method peaks trigger a "Re-measure peaks?" prompt rather than silently changing the Roofline retroactively.

### RunMetadata — full build provenance (locked)

```swift
public struct RunMetadata: Codable {
    let runID: String
    let timestamp: Date
    let preset: RunPreset

    // Git
    let gitSha: String
    let gitBranch: String
    let gitDirty: Bool

    // Build
    let swiftVersion: String
    let swiftCompilerFlags: [String]
    let optimizationLevel: String         // must be "-O" or "-Ounchecked"; "-Onone" trips ReleaseGuard
    let xcodeVersion: String
    let sdkVersion: String
    let buildConfiguration: String        // Release-only enforced

    // Linked libraries (versions captured from Info.plist / Bundle)
    let linkedLibraryVersions: [String: String]

    // Environment
    let hardware: HardwareInventory       // canonical location — NOT duplicated per case
    let fpcrAtStart: UInt32               // FZ/DZ state recorded
    let lowPowerModeEnabled: Bool

    // Harness self-bench
    let timerOverheadNanos: Double
    let harnessOverheadNanos: Double      // from NullWorkload
    let seedTableVersion: Int
}
```

### Pruning

Off by default. When enabled: keep last N runs (default 50) plus last K-of-each-preset (default 10). Whole-run granularity only — partial deletes never. Pruned runs go to `~/.Trash` via `NSFileManager.trashItem`, recoverable.

### CSV export (one-way)

```
# schemaVersion: 1.0
# runID: 2026-05-10T22-13-00Z__abc1234__standard
# columns: op,impl,dtype,shape,params,mode,p50_ns,p99_ns,p999_ns,gflops,bandwidth_gb_s,verified,flags
dot,vectorCore,f32,vec_512,{},single_shot,118,142,389,26.0,104.1,true,
...
```

Self-identifying header. Export-only — no re-import path. JSON is the only round-trip format.

### Schema versioning & migration

```swift
public struct RunDocument: Codable {
    let schemaVersion: SchemaVersion        // .v1 today
    let runMetadata: RunMetadata
    let cases: [CaseResult]
}

public struct SchemaVersion: Codable, Comparable { let major: Int; let minor: Int }

public protocol RunMigration {
    var from: SchemaVersion { get }; var to: SchemaVersion { get }
    func migrate(_ json: Data) throws -> Data
}
```

- JSON on disk is the source of truth.
- Migrations operate on raw `Data` (we don't keep `RunDocumentV1`/`V2`/... `Codable` types forever).
- Minor versions add fields; old readers tolerate by ignoring unknown.
- Major versions = explicit migration. App offers a "Migrate" button per old run.
- **Recommended (not CI-gated):** golden-file tests per migration — old-version fixture → expected new-version output.
- CSV does not migrate.

---

## §5 — Verification

Every dense-FP workload **must** declare a `ReferenceOracle`. Workloads without one fail registry validation at startup.

### Ground truth — Float64 Kahan-Neumaier

```swift
// Reference dot product
func referenceDot(_ a: [Float], _ b: [Float]) -> Double {
    var sum = 0.0, c = 0.0
    for i in 0..<a.count {
        let y = Double(a[i]) * Double(b[i]) - c
        let t = sum + y
        c = (t - sum) - y          // Neumaier rearrangement
        sum = t
    }
    return sum
}
```

Why this is unambiguously the truth: Float32 SIMD dot of 1536 elements accumulates error ≈ √N·ε_f32 ≈ 5e-5; Float64 Kahan-Neumaier is bounded by ≈ 2·ε_f64 ≈ 4e-16 — five orders of magnitude tighter than any candidate could plausibly hit.

**Buffer convention.** The `ReferenceOracle` always operates on raw `[Float]` (or `UnsafeBufferPointer<Float>`) inputs, regardless of the candidate's vector flavor. The runner unwraps `Vector<DimN>`, `VectorNOptimized`, and `DynamicVector` to their underlying contiguous storage before invoking the oracle, and likewise unwraps the candidate's output before ULP-comparing against the reference's `Double` result. This keeps the oracle code flavor-agnostic and ensures `cblas_sdot` (which takes raw pointers) and VectorCore (which takes typed vectors) are verified by the same reference implementation.

### ULP windows — shape-dependent function (not a constant table)

Floating-point accumulation error scales with the summation depth. Naïve summation has a Wilkinson bound of O(N·ε); pairwise/tree reductions (Accelerate, vDSP, well-written SIMD) have O(log₂N · ε). A **static** ULP window false-fails for large N even when the implementation is textbook-correct. The window must grow with shape:

```swift
public enum ImplClass: String, Codable {
    case standard         // SIMD/Accelerate/BLAS or naïve — tree/pairwise summation; or any
                          // textbook-correct Float32 path. Verified within ULP windows below.
    case approximate      // fast-rsqrt, fast-math, reduced-precision intermediates
}

public func ulpTolerance(op: OpKind, implClass: ImplClass, shape: Shape) -> UInt32 {
    let n = shape.summationDepth          // vector dim, or inner dim for pairwise/matrix
    let logN = UInt32(max(1, Int(log2(Double(n)).rounded(.up))))

    switch (op, implClass) {
    case (.dot, .standard):                      return 4  + 2  * logN
    case (.dot, .approximate):                   return 64 + 16 * logN
    case (.l2dist, .standard):                   return 8  + 4  * logN
    case (.l2dist, .approximate):                return 128 + 32 * logN
    case (.cosine, .standard):                   return 16 + 8  * logN
    case (.cosine, .approximate):                return 256 + 64 * logN
    case (.normalize, .standard):                return 8  + 4  * logN
    case (.normalize, .approximate):             return 1024 + 64 * logN     // rsqrt approx is harsh
    case (.axpy, .standard):                     return 4  + 2  * logN
    case (.axpy, .approximate):                  return 64 + 16 * logN
    case (.pairwiseDistances, .standard):        return 8  + 4  * logN
    case (.pairwiseDistances, .approximate):     return 128 + 32 * logN
    case (.distanceMatrix, .standard):           return 8  + 4  * logN
    case (.distanceMatrix, .approximate):        return 128 + 32 * logN
    case (.topK, _):                             return 0     // see set-based verification below
    }
}
```

**Why no `.exact` class.** An earlier draft had an `.exact` class with `ULP = 0`, intended for naïve Float32 left-to-right summation. This is mathematically wrong against a Float64 Kahan-Neumaier oracle: Float32 cannot represent the answer to better than ~2⁻²³, so even a deterministic Float32 candidate drifts ~O(N·ε_f32) from the Float64 reference (≈500 ULPs at N=512). `.exact` would false-fail every dense op. The correct mental model is: **every Float32 candidate is `.standard`** unless it deliberately trades precision for speed (`.approximate`). Bit-stability across runs is a separate property, verified by running the candidate twice and bit-comparing — handled by `BenchKit`'s determinism self-test, not by the ULP-vs-oracle check.

`.approximate` impls **report perf**, but: dashed pattern on every chart, "approx" badge, excluded from default summaries. Opt-in toggle to include them in comparison views.

### Top-K verification — set-based, not index-identity-based

Strict "candidate indices == reference indices" verification breaks on legitimate implementations for **two** reasons:

1. **Sqrt-skipping.** VectorCore's Top-K for Euclidean returns *squared* distances — a valid ranking-preserving optimization, since `argmin sqrt(x) ≡ argmin x` for non-negative x. A Float64 Kahan-Neumaier reference computing true Euclidean distance would return the sqrt. Comparing the two as raw scores fails on every case.
2. **Tied distances.** Random datasets routinely produce equidistant neighbors. A min-heap and a partial sort and a quickselect will tie-break differently; all orderings are mathematically valid.

**Verification protocol for Top-K:**

```swift
// pseudo-code
let candidateResults: [(index: Int, score: Float)]       = candidate.invoke(...)
let referenceResults: [(index: Int, distance: Double)]   = reference.compute(...)

// 1. Sqrt-normalize so both sides live in the same distance space.
let candidateNorm = candidateResults.map { (idx, s) -> (Int, Double) in
    impl.returnsSquaredDistances ? (idx, sqrt(Double(s))) : (idx, Double(s))
}

// 2. Multiset equality on distances within the ULP window for the underlying op
//    (e.g., for l2dist with N = vectorDim, use ulpTolerance(.l2dist, implClass, .vector(N))).
guard multisetEqualWithinULPs(candidateNorm.map(\.1), referenceResults.map(\.1)) else { fail }

// 3. Index validity: every returned candidate index must, when re-evaluated against
//    the dataset using the impl's declared distance metric, produce a distance present
//    in the reference multiset.
for (idx, _) in candidateNorm {
    let recomputed = metric.distance(query, dataset[idx])
    guard distanceMatchesMultiset(recomputed, referenceResults.map(\.1), ulpWindow) else { fail }
}
```

This protocol accepts any valid Top-K result regardless of internal algorithm or tie-breaking strategy, while still catching genuinely wrong indices or wrong distances.

### Dot product — sign convention is API-dependent

VectorCore exposes **two public APIs** for computing dot products, and they have **opposite signs**:

- `Vector.dot(_:)` — the raw kernel. Returns `+a·b` (mathematical convention).
- `DotProductDistance.distance(_:_:)` — the distance-metric wrapper. Returns `−a·b`, **negated for min-search ordering** consumed by `findNearest` / Top-K.

Both are benchmarked separately. The two cases are distinguished in `WorkloadID` by `params["api"] = "raw" | "metric"` (see §2.2). The `ReferenceOracle` is **(op, params)-aware** about sign convention: when verifying `api: metric`, the oracle compares against `−referenceDot(...)`; when verifying `api: raw`, against `+referenceDot(...)`. Mis-wiring this is a guaranteed silent verification failure on correct implementations — covered by a unit test.

### When verification runs

Once per case, **before** warm-up. Failures abort the case before perf sampling — perf numbers never appear for incorrect implementations.

```swift
public enum VerificationResult: Codable {
    case verified(maxUlpObserved: UInt32)
    case unverifiable(reason: String)   // no oracle (e.g., topK with k > candidate count)
    case failed(maxUlpObserved: UInt32, window: UInt32, sampleIndex: Int)
}
```

- `verified` → green check + worst-observed ULP delta (telemetry: if standard impls routinely hit 90 % of window, the window is wrong).
- `unverifiable` → yellow info icon; perf shown with flag.
- `failed` → red X; **perf numbers withheld**; charts skip the case entirely.

### Verification cost

Vector ops: microseconds (negligible). `distanceMatrix` and `pairwiseDistances` at large M/N: seconds (Float64 Kahan-Neumaier triple loop over all pairs). Budget: one verification per `(op, impl, shape, params)` — cached across batch sizes. Adds ~1 minute to a full run.

---

## §6 — Methodology (defended in spec)

We are taking specific statistical positions that disagree with conventional benchmark tooling. The spec defends them explicitly so future contributors don't drift.

### Median + tail percentiles only — no mean, no trimming

| Tool | Conventional choice | Our choice |
|---|---|---|
| Apple `XCTMetric` | mean ± stddev | reject — encodes Gaussian assumption that doesn't hold |
| Google Benchmark | min + CV | partially agree — min is the cleanest CPU-only number but ignores the tail |
| Criterion (Rust) | bootstrapped CIs | reject — synthetic CI math on within-run jitter is misleading |

Position: latency distributions on multi-tasking OSes are non-Gaussian, frequently bimodal (P/E core migration), and right-skewed (OS preemption tail). Median is jitter-robust and assumption-free. Tail percentiles (p99/p999) are the actually-interesting numbers for real-time UI work. Mean encodes nothing useful and hides bimodality. Outlier trimming hides real OS-jitter facts.

### Reproducibility comes from runs-of-runs, not within-run statistics

The diff view + multi-run history is the empirical noise estimator. Two Standard runs back-to-back on a quiet machine show the actual run-to-run variance — pick your threshold from that, not from a CI computed inside one run.

### Anti-DCE is mandatory

Without `BlackHole.consume`, `-O` deletes unused results. A `cblas_sdot` whose result is unused folds to a constant. This is not a measurement of the library; it's a measurement of LLVM's constant folder. Cost (~2–5 ns/call) is part of the floor and recorded in `RunMetadata.harnessOverheadNanos`.

---

## §7 — Measurement Integrity (locked)

The bundle that makes results trustworthy across runs, days, machines.

### Release-build guard

`Runner.start()` calls `ReleaseGuard.assertReleaseConfiguration()` which checks `_isDebugAssertConfiguration()` and `optimizationLevel`. Debug or `-Onone` builds **refuse to measure**, surfacing a clear error in the UI. Standard test suite (unit tests) is exempt.

### RNG seed table

```swift
public struct SeedTable {
    static let version: Int = 1
    static func seed(for id: WorkloadID) -> UInt64 {
        // Deterministic hash: stable across runs/machines/Swift versions.
        // splitmix64 of a fixed salt + WorkloadID's canonical bytes.
    }
}
```

- Same `WorkloadID` → same `SplitMix64` seed → same input bytes everywhere, forever.
- `SeedTable.version` recorded in `RunMetadata`. Changing the hash → bump version → schema migration.
- Per-workload override permitted only via explicit `params["seedSalt"] = "..."` (which becomes part of the WorkloadID — so a re-salted variant is a *different* case, not a silent input change).

### FPCR / denormals state

```swift
public struct FPCRState {
    public static func enableFlushToZero()      // sets FZ + DZ on AArch64
    public static func current() -> UInt32      // snapshot for RunMetadata
}
```

Called at run start. Captured in `RunMetadata.fpcrAtStart`. Without this, a test that ran after some other code touched FPCR measures something different than a fresh test.

### Cross-machine diff refusal

Diff loader compares `RunMetadata.hardware.fingerprint`. Mismatch → surfaces a clear error, refuses to render delta. (Force-anyway is **not** an escape hatch in Phase 1 — punted to a future "advanced compare" if ever needed.)

### Input distribution declared per workload

`InputDistribution` enum is part of `WorkloadMetadata`. Phase 1 standard cases use `.uniform` for all; `.normal`, `.embeddingLike`, `.adversarial(...)` are available and serializable. Two cases differing only in distribution have different `WorkloadID`s.

### NullWorkload self-bench

A registered `Workload` whose `invoke` does nothing measurable (single integer increment + BlackHole). Its measured cost is the floor: clock read + BlackHole + Runner overhead. Recorded as `RunMetadata.harnessOverheadNanos`. If it grows >10 % run-over-run, BenchKit itself has regressed (not the library under test). Visible in every run's Summary view.

---

## §8 — Operability (locked)

### Cancellation semantics

```swift
public final class CancellationToken: @unchecked Sendable {
    public func cancel()
    public var isCancelled: Bool { get }
}
```

- Runner accepts an optional `CancellationToken`.
- Granularity: checked between cases (always) and between samples within a case (when batch size allows cheap re-entry).
- Mid-case cancellation truncates samples (`flags.insert(.truncated)`), writes the partial `CaseResult`, advances queue completion to current index, writes `RunDocument` normally.
- A cancelled run is a **valid run on disk**, openable in the UI like any other, just with partial coverage.

### First-launch UX

Empty-state view:
1. "Welcome — VectorSuiteBench needs to measure your hardware's empirical peaks before running the Roofline chart."
2. [ Measure Peaks (~30s) ]  →  runs FMA microkernel + STREAM-triad, writes `peaks/<fingerprint>.json`.
3. Once peaks are cached: "Run your first benchmark" → opens Run Config sheet with Smoke preset preselected.

Peak measurement also re-prompts whenever the hardware fingerprint changes (new Mac, dual-boot, etc.) or the peak-measurement method version differs from the cached one.

### Concurrency policy

(See §2.6 — single-page doc lives in `BenchKit/README.md`.)

---

## §9 — Phase 1 Deliverable: VectorCore vs Apple Accelerate

### Registered case matrix

VectorCore is a pure vector library — it does **not** contain matrix multiplication primitives. GEMV/GEMM belong to VectorAccelerate (Phase 2). VectorCore's O(N²) workloads are `BatchOperations.pairwiseDistances` and `Operations.distanceMatrix` — both async, both interesting tests of auto-parallelization.

Each vector-op row is multiplied by the **vector-flavor axis** (`optimized` / `generic` / `dynamic`) — those produce three distinct `WorkloadID`s for the VectorCore column. Other-impl columns sit at one flavor (their natural shape).

| Op | Protocol | Impls | Sizes (dim N) | Dataset / Batches | Notes |
|---|---|---|---|---|---|
| `dot` (`api: raw`) | Borrowing | VectorCore (×3 flavors) · vDSP `cblas_sdot` · Apple `simd_dot` · naïve | 64, 256, 512, 1536, 4096 | 1, 100, 10 000 | Returns +a·b |
| `dot` (`api: metric`) | Borrowing | VectorCore `DotProductDistance` · naïve negated | same | same | Returns −a·b for min-search ordering; oracle sign-aware |
| `l2dist²` | Borrowing | VectorCore (×3) · `vDSP_distancesq` · `simd_distance_squared` · naïve | same | same | |
| `cosine` | Borrowing | VectorCore (×3) · vDSP-composed · `simd`-composed · naïve | same | same | |
| `normalize` (L2, out-of-place) | Borrowing | VectorCore (×3) · `vDSP_vnrm2+vDSP_vsmul` · `simd_normalize` · naïve | same | same | |
| `normalize` (L2, in-place) | Mutating | VectorCore (×3) · `vDSP_*` in-place · naïve | same | same | K-input rotation in Amortized mode |
| `axpy` | Mutating | VectorCore (×3) · `cblas_saxpy` · naïve | same | same | K-input rotation in Amortized mode |
| `topK` (k=10, via `Operations.findNearest`) | Async | VectorCore · Accelerate-heap · naïve | candidate counts: 1 000, 10 000, 100 000 | 1, 100 queries | Set-based verification with sqrt-awareness |
| `pairwiseDistances` (`BatchOperations`) | Async | VectorCore · naïve nested loop | dim 384, 768, 1536 | M × N ∈ {64×64, 256×256, 1024×1024} | Exercises TaskGroup auto-parallel |
| `distanceMatrix` (`Operations`) | Async | VectorCore · Accelerate `cblas_sgemm`-trick · naïve | dim 384, 768, 1536 | M × N ∈ {256×256, 1024×1024, 4096×4096} | Auto-parallel; large refs are slow (budgeted) |

**Case counts** (precise definitions in §3 preset filters):
- Smoke: **~40 cases**, ~30s.
- Standard: **~180 cases**, ~5 min. Excludes `distanceMatrix` ≥ 1024² (the Float64 Kahan reference at that size is the wall-time bottleneck).
- Full (entire registry above): **~600 cases**, ~45 min.

Earlier drafts cited "~340 standard / ~1 200 full" — those numbers predated the matrix overhaul (vector-flavor axis, dot raw/metric split, GEMV/GEMM → pairwiseDistances/distanceMatrix). The numbers above are current.

### Critical files to be created

| File | Purpose |
|---|---|
| `Packages/BenchKit/Package.swift` | SwiftPM manifest, products: BenchKit |
| `Packages/BenchKit/Sources/BenchKit/Workload/Workload.swift` | BorrowingWorkload + MutatingWorkload + AsyncWorkload + WorkloadMetadata |
| `Packages/BenchKit/Sources/BenchKit/Workload/WorkloadID.swift` | Identity + CanonicalParams (incl. vectorflavor, api) + frozen wire-names |
| `Packages/BenchKit/Sources/BenchKit/Runner/Runner.swift` | Sync runner for Borrowing/Mutating; cancellation; budget honoring; K-input rotation for MutatingWorkload |
| `Packages/BenchKit/Sources/BenchKit/Runner/AsyncRunner.swift` | Async runner for AsyncWorkload; runs in Task tree with @TaskLocal bindings propagated |
| `Packages/BenchKit/Sources/BenchKit/Clock/*.swift` | mach_absolute_time + calibration (metadata only — not subtracted from single-shot samples) |
| `Packages/BenchKit/Sources/BenchKit/Stats/*.swift` | LatencyDistribution, AmortizedResult, BandwidthEstimator |
| `Packages/BenchKit/Sources/BenchKit/Probes/*.swift` | MemoryProbe, ThermalProbe, SignpostEmitter, NullWorkload |
| `Packages/BenchKit/Sources/BenchKit/IO/*.swift` | RunStore, RunDocument, SchemaVersion, MigrationRegistry, CSVExporter |
| `Packages/BenchKit/Sources/BenchKit/Verify/*.swift` | ReferenceOracle (sign-aware), ULPWindows (shape-dependent function), VerificationResult, TopKSetVerifier |
| `Packages/BenchKit/Sources/BenchKit/Hardware/*.swift` | HardwareInventory, PeakMeasurement (FMA + STREAM) |
| `Packages/BenchKit/Sources/BenchKit/Provenance/*.swift` | BuildProvenance, GitProvenance, FPCRState |
| `Packages/BenchKit/Sources/BenchKit/Seeds/*.swift` | SplitMix64, SeedTable, InputDistribution |
| `Packages/BenchKit/Sources/BenchKit/Util/*.swift` | BlackHole, ReleaseGuard |
| `Packages/BenchKit/README.md` | Concurrency policy + extension guide |
| `Packages/VSBCore/Package.swift` | Depends on BenchKit, VectorCore, Accelerate; uses Apple `simd` from system |
| `Packages/VSBCore/Sources/VSBCore/Ops/*.swift` | One file per op family: Dot, L2Distance, Cosine, Normalize, AXPY, TopK, PairwiseDistances, DistanceMatrix |
| `Packages/VSBCore/Sources/VSBCore/Implementations/*.swift` | VectorCoreImpl (×3 flavors: optimized/generic/dynamic), AccelerateImpl, NaiveImpl, SimdImpl |
| `Packages/VSBCore/Sources/VSBCore/Oracles/KahanFloat64Reference.swift` | All references for §9 ops |
| `Packages/VSBCore/Sources/VSBCore/Registry.swift` | Declarative case enumeration |
| `VectorSuiteBench/App.swift` | App entry; first-launch peak measurement |
| `VectorSuiteBench/Views/RunConfigView.swift` | New-run sheet with live estimates |
| `VectorSuiteBench/Views/RunListSidebar.swift` | index.json-backed |
| `VectorSuiteBench/Views/RunDetailView.swift` | Summary + tabs |
| `VectorSuiteBench/Views/DiffPaneView.swift` | Cross-run delta; refuses cross-fingerprint |
| `VectorSuiteBench/Charts/ThroughputBarChart.swift` | |
| `VectorSuiteBench/Charts/LatencyHistogramChart.swift` | |
| `VectorSuiteBench/Charts/LatencyPercentileChart.swift` | |
| `VectorSuiteBench/Charts/RooflineChart.swift` | |
| `VectorSuiteBench/Charts/MemoryPressureChart.swift` | |

### Existing utilities to reuse (do not re-implement)

- `VectorCore/Benchmarks/VectorCoreBench/Timing.swift` — patterns for mach-based timing (BenchKit's `Clock` is more rigorous but can borrow the API shape).
- `VectorCore/Benchmarks/VectorCoreBench/Random.swift` — seeded PRNG patterns; BenchKit's `SplitMix64` should match the algorithm so cross-validation against VectorCore's own bench results is straightforward.
- `VectorCore/Benchmarks/VectorCoreBench/BlackHole.swift` — anti-DCE; we should align our `BlackHole.consume` semantics with VectorCore's so VectorCore's published numbers and ours are directly comparable.
- `VectorCore/Benchmarks/VectorCoreBench/CSV.swift` — CSV column conventions; align where reasonable.

### Phase 1 design corrections (from spec review)

This spec was refined post-initial-draft against the actual VectorCore public surface. The following corrections are load-bearing — implementations that violate them will produce wrong measurements or fail to compile against the registry:

1. **AsyncWorkload is in Phase 1**, not deferred. `Operations.findNearest`, `Operations.distanceMatrix`, and `BatchOperations.*` are async-first; sync wrappers hide the auto-parallelization that's the whole point of measuring them.
2. **No GEMV/GEMM in Phase 1.** VectorCore has no matrix-multiplication primitives; those live in VectorAccelerate (Phase 2). Use `pairwiseDistances` and `distanceMatrix` for O(N²) workloads.
3. **Vector flavor is part of `WorkloadID`** via `params["vectorflavor"]`. `Vector<Dim512>` (generic), `Vector512Optimized` (SIMD4-fused), and `DynamicVector(dimension: 512)` (heap-backed) **must** appear as three distinct cases — they have different perf and the diff view must keep them separated.
4. **Top-K verification is set-based**, not index-identity-based. Distance-multiset equality with sqrt-awareness, plus index-validity re-check. Strict index identity fails on legitimate min-heap vs sort tie-breaking.
5. **Dot product has two APIs with opposite signs.** `Vector.dot()` returns `+a·b`; `DotProductDistance.distance(_:_:)` returns `−a·b`. Both are benchmarked, distinguished by `params["api"]`, oracle is sign-aware.
6. **ULP windows are shape-dependent functions**, not constants. Tree-reduction error scales O(log₂N · ε); a static window false-fails for large N. Window = `base + factor · log₂(N)`.
7. **Warm-up rule is "100 ms AND ≥50 iterations, whichever last"** — NOT "whichever first". Apple Silicon P-core migration + frequency ramp needs ~10–30 ms of sustained load.
8. **Timer overhead is never subtracted from single-shot raw samples.** At 41.6 ns timebase resolution, subtraction produces zero or negative latencies. Applied only at Amortized aggregate level.
9. **Mutating ops use `MutatingWorkload` with K-input rotation** in Amortized mode. Re-using one `inout` input across 10 000 iterations of AXPY drifts toward NaN, triggering microcode penalties.
10. **"Amortized" replaces "Batched" as the harness mode name.** Avoids collision with VectorCore's `BatchOperations` public namespace.
11. **Memory probe is snapshot-only during single-shot sampling.** 100 Hz continuous reads inject the exact OS jitter we're measuring against; continuous probe runs only during Amortized (where loop wall time amortizes the cost).
12. **Runner runs inside a Swift `Task` tree** so `@TaskLocal` bindings (`Operations.$simdProvider`, `ComputeProvider`) propagate. Raw pthreads silently fall back to defaults.
13. **`swift-numerics` is not a baseline.** It provides `Real`/`Complex` protocols and `Float16`, not BLAS. Replaced by Apple `simd` (`simd_dot`, `simd_length_squared`, `simd_normalize`, …).

A second self-review pass added these load-bearing corrections:

14. **`ImplClass.exact` removed.** ULP 0 against a Float64 oracle is mathematically wrong — every Float32 candidate has inherent O(N·ε_f32) drift from a Float64 reference, even when bit-stable across runs. Every Float32 path is `.standard` unless it deliberately trades precision (`.approximate`). Bit-stability is verified separately by a determinism self-test, not by the ULP-vs-oracle check.
15. **`vectorflavor` is required iff `impl == .vectorCore`.** Other impls (`cblas_sdot`, `simd_dot`, naïve) take raw `[Float]` buffers and have no flavor concept; canonicalizer rejects `vectorflavor` if present on non-VectorCore cases.
16. **`MutatingWorkload` single-shot mode pre-builds N fresh inputs** (one per sample) outside the timing window. Re-using one mutated input across N samples drifts toward NaN and corrupts the measurement.
17. **Preset filters are pinned in §3.** Smoke ≈40 cases, Standard ≈180 cases (excludes `distanceMatrix` ≥ 1024²), Full ≈600 cases. Earlier "~340 standard / ~1200 full" numbers predated the matrix overhaul.
18. **`ReferenceOracle` operates on raw `[Float]` buffers** regardless of candidate flavor. Runner unwraps `Vector<DimN>` / `VectorNOptimized` / `DynamicVector` to underlying storage before verification. Keeps oracle code flavor-agnostic.

### Acceptance criteria (Phase 1 closeout)

On an M-series Mac under macOS 26+, Release build:

1. **Standard run completes in ≤6 min** on a quiet machine, producing a valid `RunDocument` v1 with full build provenance and atomic on-disk format.
2. **All five charts render** from a Standard run; empirical-peak measurement has been executed for the device fingerprint.
3. **Diff view** compares two Standard runs of identical fingerprint and exports a Markdown table; refuses to diff across mismatched fingerprints.
4. **Verification passes** on every `.standard`-class impl for all dense ops (using shape-dependent ULP windows per §5); failures surface without leaking perf numbers. `.approximate` impls verify within their wider windows.
5. **NullWorkload self-bench** registered; floor recorded in `RunMetadata.harnessOverheadNanos`.
6. **Release-build guard** trips when launched from Debug.
7. **Cancellation**: a run cancelled mid-case produces an openable partial `RunDocument`; flagged cases render with the truncation badge.
8. **Human-interpretation gate**: a competent reviewer looking at the Roofline + Throughput charts can explain where VectorCore sits relative to compute/bandwidth peaks, where it has headroom, and which ops the naïve floor is closest to.

### Out of Phase 1 scope (named so they're not silently forgotten)

- MetricKit energy capture (Phase 2 alongside Metal).
- Metal Performance Counters / GPU timing (Phase 2).
- ANE occupancy (Phase 4 with EmbedKit).
- FAISS bridge / ANN recall benchmarking (Phase 3).
- Headless CLI executable target (any later phase — package layering supports it).
- iOS target (any later phase).
- Automatic regression alarms / CI integration (any later phase).
- API stability markers / OSLog policy / per-package user-docs guides (recommended best practice; not blocking).

---

## §10 — Verification (how to test the Phase 1 build end-to-end)

After implementation:

1. **Build**: `xcodebuild -project VectorSuiteBench/VectorSuiteBench.xcodeproj -scheme VectorSuiteBench -configuration Release build`. Confirms Release builds clean across all three packages.
2. **Run unit tests**: `swift test --package-path Packages/BenchKit` and `swift test --package-path Packages/VSBCore`. Tests cover: `LatencyDistribution` math, `BandwidthEstimator` derivation, `WorkloadID` round-trip canonicalization, schema migration golden files, every `ReferenceOracle` against an independent known-correct implementation, `BlackHole` actually prevents DCE (smoke test inspecting whether `cblas_sdot` is constant-folded with/without BlackHole — verifiable via Mach-O symbol presence or a counter overflow check).
3. **First-launch smoke**: delete `~/Library/Application Support/VectorSuiteBench`, launch app, verify the empty-state view + peak measurement flow runs and writes `peaks/<fingerprint>.json`.
4. **Run a Smoke preset**: triggered from the Run Config sheet. Verify it completes in ≈30 s and produces a `RunDocument` on disk with NullWorkload floor recorded.
5. **Run a Standard preset**: confirm wall-clock estimate matches reality within ±20 %, all five charts render from the result, verification badges appear correctly.
6. **Cancel mid-run**: start a Full preset, hit Stop after ~30 s. Verify the partial `RunDocument` opens, completed cases render normally, the next-uncompleted case is absent, no `.tmp` files left on disk.
7. **Diff**: run Standard twice. Open Diff Pane, confirm Markdown export populates with deltas. Move one of the two runs into a different `peaks/<fingerprint>` (simulating a hardware change) and confirm the diff is refused.
8. **Release-build guard**: launch from Xcode in Debug, attempt to start a run, confirm the guard error appears.
9. **Verification gate**: temporarily corrupt the naïve `dot` impl (e.g., `+=` → `-=`). Confirm the case is reported as `failed`, no perf numbers leak into any chart.
10. **Human-interpretation gate**: ask a competent reviewer to explain the suite's verdict on VectorCore from the rendered Roofline + Throughput charts. The verdict should be legible without external context.
