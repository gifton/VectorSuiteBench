# Phase 2.0 — Make it runnable

**Status when this doc was written:** Phase 1.5 plus post-review fixes are complete (HEAD `104323a`). 68 tests pass across BenchKit + VSBCore. The harness is verified end-to-end inside unit tests but nothing orchestrates the *whole registry* through the runner and writes a `RunDocument` on disk.

Phase 2.0 closes that gap. **Six items, no UI, no new op families, no Metal.** Once 2.0 lands, you can run `swift run vsb-run --preset smoke` and get a real JSON report + CSV. Subsequent slices (2.1 = first UI + charts; 2.2 = a second op family; 2.3+ = Metal, MetricKit) build on it.

This doc is the handoff. Assume the next agent has no prior context.

---

## 1. State at start of Phase 2.0

**Repo:** `/Users/goftin/dev/gsuite/VectorSuiteBench` · `main` · GitHub: `gifton/VectorSuiteBench` (push authorized).

**Read first:**
- `docs/phase-1-design.md` (~800 lines, the approved spec — §3 Reporting, §4 Persistence, §7 Measurement Integrity, §8 Operability, §9 corrections list are most relevant here).
- `docs/phase-1.5-plan.md` (Phase 1.5 history; §6 enumerates Phase 2 territory).

**What's built that 2.0 will compose:**

```
Packages/BenchKit/
├── Sources/BenchKit/
│   ├── Workload/   WorkloadID, CanonicalParams, WorkloadMetadata,
│   │               BorrowingWorkload, MutatingWorkload, AsyncWorkload,
│   │               WorkloadFamily (new in 1.5)
│   ├── Runner/     Runner (sync, async-entry), AsyncRunner, RunPreset,
│   │               WallClockBudget, CancellationToken
│   ├── Verify/     ReferenceOracle<Input,Output> (generic post-1.5),
│   │               VerificationResult, ulpTolerance(op:implClass:shape:)
│   ├── Probes/     NullWorkload (self-bench)
│   ├── Provenance/ BuildProvenance.probe(), GitProvenance.probe(),
│   │               FPCRState (real C-bridge in BenchKitC)
│   ├── Hardware/   HardwareInventory.probe() — note: gpuCoreCount always 0
│   ├── Clock/      BenchClock (mach_absolute_time), TimerCalibration
│   ├── Stats/      LatencyDistribution, AmortizedResult, BandwidthEstimator
│   ├── IO/         CaseResult, CaseFlag, RunDocument, RunMetadata,
│   │               RunStore (atomic temp+rename), SchemaVersion (1.1),
│   │               MigrationRegistry
│   ├── Diff/       RunDiff (refuses cross-fingerprint; markdown export)
│   ├── Util/       BlackHole (per-thread sink), ReleaseGuard
│   └── Seeds/      SplitMix64, SeedTable, InputDistribution
└── Sources/BenchKitC/  FPCRBridge.c (mrs/msr on AArch64)

Packages/VSBCore/
├── Sources/VSBCore/
│   ├── Ops/             DotShared, OptimizedVectorType (1.5)
│   ├── Oracles/         KahanFloat64DotReference (generic makeDotOracle)
│   ├── Implementations/ Naive/Accelerate/Simd/VectorCoreOptimized<V>/
│   │                    VectorCoreGeneric<D>/VectorCoreDynamic + Metric
│   └── Registry.swift   VSBCoreRegistry.workloads = families.flatMap(...)
│                        DotFamily contributes 27 Dot cases
└── Tests/VSBCoreTests/
```

**What's NOT built** (Phase 2.0 fills the operational gaps):
- Nothing orchestrates `[any WorkloadMetadata]` → `[CaseResult]`.
- No CLI / no executable target.
- `RunStore.beginRun → writeCase → finalizeRun` works but no caller drives it.
- `HardwareInventory.probe()` / `GitProvenance.probe()` / `FPCRState` exist but aren't wired into a `RunMetadata` constructor.
- `NullWorkload` exists but its measured floor isn't fed into `RunMetadata.harnessOverheadNanos`.
- No `PeakMeasurement` (FMA microkernel + STREAM-triad).
- No `CSVExporter`.
- `MemoryProbe` is snapshot-only; the continuous 100 Hz path during Amortized isn't wired (we have the `MemorySample` type and `CaseResult.memoryTrace` field, just no producer).

---

## 2. Phase 2.0 scope — six items

### Item 1 — `RunController`

The connective tissue. New file: `Packages/BenchKit/Sources/BenchKit/Runner/RunController.swift`.

**Responsibilities:**
1. Probe environment: `HardwareInventory.probe()`, `BuildProvenance.probe()`, `GitProvenance.probe(workingDirectory:)`, `FPCRState.enableFlushToZero()` (and capture the prior value).
2. Self-bench: run `NullWorkload` through `Runner` to derive `harnessOverheadNanos`.
3. Build `RunMetadata` with everything assembled.
4. `RunStore.beginRun(metadata:)` to create the run directory + manifest.
5. For each `any WorkloadMetadata` in the registry: dispatch to the right runner (sync `Runner` for `BorrowingWorkload`/`MutatingWorkload`, async `AsyncRunner` for `AsyncWorkload`), call `RunStore.writeCase(_:)`, honor `WallClockBudget.total` and the `CancellationToken`.
6. `RunStore.finalizeRun(runID:)` to write `samples.csv` (via CSVExporter from Item 3) and update `index.json`.

**The tricky bit — existential → concrete dispatch.** The registry holds `[any WorkloadMetadata]` but `Runner.run<W>` is generic over the concrete protocol. We need a protocol witness that knows how to run itself. Recommended approach:

```swift
// In BenchKit/Workload/Workload.swift, add a new protocol that the three
// typed protocols all refine. The witness lives on each typed protocol via
// a default implementation that dispatches to the right runner.
public protocol RunnableWorkload: WorkloadMetadata {
    func runVia(
        runner: Runner,
        asyncRunner: AsyncRunner,
        cancellation: CancellationToken?
    ) async -> CaseResult
}

public protocol BorrowingWorkload: RunnableWorkload { ... }
public protocol MutatingWorkload: RunnableWorkload { ... }
public protocol AsyncWorkload: RunnableWorkload { ... }

extension BorrowingWorkload {
    public func runVia(runner: Runner, asyncRunner: AsyncRunner,
                       cancellation: CancellationToken?) async -> CaseResult {
        await runner.run(self, cancellation: cancellation)
    }
}
extension MutatingWorkload {
    public func runVia(runner: Runner, asyncRunner: AsyncRunner,
                       cancellation: CancellationToken?) async -> CaseResult {
        await runner.run(self, cancellation: cancellation)
    }
}
extension AsyncWorkload {
    public func runVia(runner: Runner, asyncRunner: AsyncRunner,
                       cancellation: CancellationToken?) async -> CaseResult {
        await asyncRunner.run(self, cancellation: cancellation)
    }
}
```

The registry then becomes `[any RunnableWorkload]` instead of `[any WorkloadMetadata]`. `WorkloadFamily.workloads` returns `[any RunnableWorkload]`. RunController iterates and calls `workload.runVia(...)` — protocol witness dispatch lands in the right specialization at the call site (since `runVia` is itself generic in context).

**Budget enforcement:** RunController tracks total elapsed against `budget.total`. On overrun: `.skipRemaining` skips the rest of the queue; `.truncateSamples` is already honored inside the runners.

**Files:**
- `Packages/BenchKit/Sources/BenchKit/Workload/Workload.swift` — add `RunnableWorkload`; conform the three typed protocols.
- `Packages/BenchKit/Sources/BenchKit/Workload/WorkloadFamily.swift` — change `workloads` type to `[any RunnableWorkload]`.
- `Packages/VSBCore/Sources/VSBCore/Registry.swift` + `DotFamily` — type-only update.
- `Packages/BenchKit/Sources/BenchKit/Runner/RunController.swift` — new.

**Acceptance:** `RunController(runID:, registry:, store:, preset:).run()` produces a `RunDocument` on disk. Cancellation mid-queue produces a valid partial document. Budget overrun truncates per policy.

---

### Item 2 — `PeakMeasurement`

New: `Packages/BenchKit/Sources/BenchKit/Hardware/PeakMeasurement.swift`.

Two micro-benchmarks producing the Roofline chart's reference lines:

**Peak compute (single-P-core, register-resident FMA):**
```swift
// A tight loop of K register-resident SIMD4<Float> FMAs (no memory loads).
// Time M iterations; FLOPs = K * 4 (lanes) * 2 (mul+add) * M; GFLOPS = FLOPs / nanoseconds.
// K = 8–16 (fits in registers). M tuned so total ≥ 100ms.
```

**Peak bandwidth (STREAM-triad, multi-thread saturating):**
```swift
// Classic STREAM: a[i] = b[i] + alpha * c[i] over N-element arrays.
// N sized to exceed last-level cache (~32MB on M-series). Multi-thread
// via Task fan-out to saturate the memory subsystem. Bandwidth =
// 24 bytes/element (read b, read c, write a) * N / nanoseconds.
```

**Caching:** writes/reads `peaks/<hardwareFingerprint>.json` per the spec §4. Method-version tags so a future improvement to the microkernel doesn't silently change every roofline retroactively.

**First-launch hook:** RunController calls `PeakMeasurement.ensureCached(for: hardware, in: store)`; if absent or method version mismatch, runs the measurement and writes the file.

**Acceptance:** `peaks/<fingerprint>.json` written on first run; subsequent runs read from cache; numbers are plausible (M3 Max ≈ 350–400 GFLOPS single P-core, ≈ 300 GB/s peak bandwidth).

---

### Item 3 — `CSVExporter`

New: `Packages/BenchKit/Sources/BenchKit/IO/CSVExporter.swift`.

Per spec §4 — one-way export of a `RunDocument` to CSV with versioned header:

```
# schemaVersion: 1.1
# runID: 2026-05-15T14-30-00Z__abc1234__standard
# columns: op,impl,implClass,dtype,shape,params,mode,p50_ns,p99_ns,p999_ns,gflops,bandwidth_gb_s,verified,flags
dot,naive,naive,f32,vec_64,{},single_shot,1850,2104,2980,0.069,0.276,true,
dot,naive,naive,f32,vec_64,{},amortized,1832,1900,1920,0.070,0.279,true,
dot,accelerate,standard,f32,vec_64,{},single_shot,118,142,389,1.084,4.336,true,
...
```

One row per `(case, mode)` — so a case with both single-shot and amortized data produces two rows. `nil` bandwidth/gflops render as empty cells. CSV is write-only; no re-import path.

Called from `RunStore.finalizeRun` to produce the per-run `samples.csv`.

**Acceptance:** `samples.csv` exists in every finalized run directory; column count matches header; comment header includes `schemaVersion` and `runID`.

---

### Item 4 — Continuous `MemoryProbe`

New: `Packages/BenchKit/Sources/BenchKit/Probes/MemoryProbe.swift`.

The Runner already has snapshot-only memory tracking (pre/post RSS). For Amortized mode, the spec mandates **continuous 100 Hz probe**: a background `DispatchQueue` reading `mach_task_basic_info().resident_size` every 10 ms during the sampling loop, producing `[MemorySample]` that lands in `CaseResult.memoryTrace`.

```swift
public final class MemoryProbe: @unchecked Sendable {
    public init(intervalMillis: Int = 10) { ... }
    public func start() -> ContinuationHandle  // begins sampling
    public func stop(_ handle: ContinuationHandle) -> [MemorySample]
}
```

`Runner.sampleAmortized*` calls `probe.start()` before the timed loop and `probe.stop()` after. Single-shot stays snapshot-only.

**Acceptance:** Amortized cases produce non-empty `memoryTrace` arrays; single-shot stays empty. Probe cost stays under 1% wall (verifiable via `looksBimodal`-style histogram check on a no-op workload).

---

### Item 5 — `vsb-run` CLI executable

New: `Packages/BenchKit/Sources/vsb-run/main.swift` (and Package.swift target declaration).

Add to `Packages/BenchKit/Package.swift`:

```swift
.executableTarget(
    name: "vsb-run",
    dependencies: [
        "BenchKit",
        .product(name: "VSBCore", package: "VSBCore"),
    ]
)
```

Wait — BenchKit can't depend on VSBCore (VSBCore depends on BenchKit; reverse dependency would cycle). **Resolution:** put the executable in VSBCore's package instead, OR create a third package `VSBRun` that depends on both. Cleanest: `Packages/VSBRun/Package.swift` as a sibling — minimal SwiftPM ceremony, no cycle.

**CLI surface:**

```
vsb-run --preset smoke|standard|full          # required
        [--output <dir>]                       # default: ~/Library/Application Support/VectorSuiteBench
        [--filter <op>]                        # only run cases where identifier.op == this
        [--filter <impl>]                      # only run cases where identifier.impl == this
        [--dry-run]                            # print plan, don't measure
        [--quiet]                              # only progress + final summary
```

Uses `swift-argument-parser` (single dep, well-maintained). On exit, prints the `runID`, total wall time, completed/failed case counts, and the location of `manifest.json` and `samples.csv`.

**Acceptance:** `swift run vsb-run --preset smoke` exits 0 in <60s on a quiet M-series Mac, producing a valid `RunDocument` + CSV + index.json update.

---

### Item 6 — End-to-end smoke test

New: `Packages/VSBRun/Tests/VSBRunTests/EndToEndTests.swift` (or wherever the CLI lives).

```swift
@Test("vsb-run smoke produces a valid RunDocument")
func smokeRun() async throws {
    let tmp = makeTempDir()
    let result = try await Process.run(
        executableURL: cliPath(),
        arguments: ["--preset", "smoke", "--output", tmp.path, "--filter", "dot"]
    )
    #expect(result.terminationStatus == 0)
    // Locate the run directory, load via RunStore, validate.
    let store = RunStore(rootURL: tmp)
    let index = try store.loadIndex()
    #expect(!index.runs.isEmpty)
    let run = try store.loadRun(runID: index.runs.first!.runID)
    #expect(run.cases.count > 0)
    #expect(run.cases.allSatisfy { $0.verification.isVerified || $0.verification.isUnverifiable })
}
```

Closes the loop from CLI → RunController → registry → Runner → RunStore.

**Acceptance:** test passes; CSV + JSON shapes validate; cancellation behavior is exercised by a second test that kills the process mid-run and confirms the partial RunDocument loads.

---

## 3. Validation

```bash
# All existing tests still pass
cd Packages/BenchKit && swift test
cd Packages/VSBCore && swift test

# New: CLI builds and runs
cd Packages/VSBRun && swift build
swift run vsb-run --preset smoke

# New: e2e test passes
swift test --package-path Packages/VSBRun
```

Expected test count at 2.0 close: ~72 (68 carried + 4-5 new for RunController, PeakMeasurement, CSVExporter, MemoryProbe, e2e).

---

## 4. Conventions to follow

(Reaffirming from the 1.5 doc plus new items.)

- **Plan mode is OFF.** Edit directly.
- **Swift Testing** (`import Testing`), not XCTest.
- **`borrowing Input` requires struct, not tuple.**
- **`BenchClock`, not `Clock`** (Swift stdlib protocol collision).
- **No SourceKit pre-resolution** — diagnostics about "Cannot find type X" are stale; `swift build` is truth.
- **WorkloadID identity rules are sacred.** Adding a new enum case = additive schema change = bump `SchemaVersion.minor` AND add a wire-name test.
- **`ImplClass` is algorithm shape, not library identity** — don't couple to `ImplKind` in the canonicalizer.
- **`WorkloadFamily`-pattern for any new registry** — `families.flatMap(\.workloads)`. Don't add to a monolithic `makeWorkloads()`.
- **`RunnableWorkload` (new in 2.0):** every concrete Workload protocol gets default `runVia(...)` so `[any RunnableWorkload]` is dispatchable through protocol witness.
- **Sendable everywhere.** `OSAllocatedUnfairLock<T>` for mutable state in `@unchecked Sendable` classes. No swift-atomics dep.
- **Auto-classifier may block `git push` to main** — user has authorized direct pushes; if blocked, ask.

---

## 5. What Phase 2.0 explicitly does NOT include

**Phase 2.1 territory:**
- SwiftUI app shell (`RunConfigView`, `RunListSidebar`, `RunDetailView`, `DiffPaneView`).
- First Swift Charts composition (likely `ThroughputBarChart`).
- The current `VectorSuiteBench/` Xcode app target stays as the empty default template until 2.1.

**Phase 2.2 territory:**
- Additional op families: L2 distance², cosine, normalize-OOP, normalize-IP (Mutating), AXPY (Mutating), Top-K (Async), pairwiseDistances (Async), distanceMatrix (Async).
- Each new family is its own `WorkloadFamily` implementation.
- The Top-K family will exercise the set-based verification protocol drafted in spec §5.

**Phase 2.3+ territory** (original-spec Phase 2/3/4):
- VectorAccelerate (Metal kernels), Metal Performance Counters, GPU timing via `MTLCommandBuffer.gpuStartTime`.
- MetricKit energy + PMC memory bandwidth.
- VectorIndex vs FAISS (C++ bridge).
- EmbedKit end-to-end.

Out forever (not just deferred):
- iOS target — design works there but no current need.
- Auto-regression alarms / CI integration of perf gates — human-driven diff stays the model.

**Stop and ask if you find yourself starting any of the above before 2.0 closes.**

---

## 6. Carried-over known follow-ups

From the Phase 1 and Phase 1.5 reviews. Non-blocking for 2.0; flag if you touch the affected code:

- **m5 (Phase 1.5 review)** — `ReferenceOracle<Input, Output>` could become `<Input, Output, Reference>` to remove the remaining enum-erasure on `ReferenceValue`. Defer unless a new oracle's shape demands it.
- **m4 (Phase 1 review)** — `HardwareInventory.gpuCoreCount` always `0`. Probe via IORegistry if you need GPU-aware fingerprints in 2.3+; otherwise leave.
- **m11 (Phase 1 review)** — `try!` on every workload's `identifier`. Cosmetic; could become `static let` per workload. Skip unless you're already touching the workload.
- **`m1` (Phase 1.5 review)** — Smoke fixtures still use `.standard` for naïve patterns. Update if/when you touch the fixtures; else leave for consistency.

---

## 7. How to start

1. Read `docs/phase-1-design.md` end-to-end (especially §3, §4, §7, §8).
2. Read this doc.
3. `cd Packages/BenchKit && swift test` — confirm 53 BenchKit tests pass.
4. `cd Packages/VSBCore && swift test` — confirm 15 VSBCore tests pass.
5. Implement Items 1–4 in BenchKit; commit each. After Item 1 (RunController), write a unit test that drives `VSBCoreRegistry.workloads` through it and produces a `RunDocument` — closes the existential-dispatch question before downstream items depend on it.
6. Create `Packages/VSBRun/` (new SwiftPM package depending on BenchKit + VSBCore + `swift-argument-parser`). Implement Item 5.
7. Add the e2e smoke test (Item 6). Confirm `swift run vsb-run --preset smoke` exits 0 and produces real on-disk output.
8. Push to `main`. Update this doc's "State at end" section with the commit list. Announce 2.0 complete.

Estimated time: 3–5 focused sessions. Item 1 is the largest; Items 2–4 are isolated; Items 5–6 are mostly plumbing once 1 works.

If anything reads ambiguous, **stop and ask** before guessing — the Phase 1 review revealed that one round of explicit-prioritization conversation saves many rounds of rework.

---

## 8. State at end of Phase 2.0

*(To be filled in by the agent that completes 2.0. Include commit hashes, final test count, and any in-flight follow-ups that should flow to 2.1.)*
