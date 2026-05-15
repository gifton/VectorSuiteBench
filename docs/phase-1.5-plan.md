# Phase 1.5 — Continuation Plan

**Status when this doc was written:** Phase 1 of `VectorSuiteBench` is complete and post-review-hardened. Phase 1.5 (the next slice, scoped below) is planned but not yet started. After 1.5 lands, a larger Phase 2 will tackle the app UI, the rest of the op families, and Metal/energy work.

This doc is the handoff to whichever agent picks up next. Assume it has zero prior context.

---

## 1. Repository layout (current state)

```
/Users/goftin/dev/gsuite/VectorSuiteBench/
├── docs/
│   ├── phase-1-design.md       # The approved Phase 1 design spec (~800 lines). READ FIRST.
│   ├── phase-1.5-plan.md       # This file.
│   └── libraries/              # (Empty subdir — not used yet.)
├── Packages/
│   ├── BenchKit/               # The harness package (library-under-test agnostic).
│   │   ├── Package.swift       # Targets: BenchKitC (C bridge), BenchKit (Swift library), BenchKitTests.
│   │   ├── Sources/
│   │   │   ├── BenchKitC/      # C shim for inline asm we can't write in Swift.
│   │   │   │   ├── include/BenchKitC.h
│   │   │   │   └── FPCRBridge.c    # mrs/msr fpcr on AArch64.
│   │   │   └── BenchKit/
│   │   │       ├── Clock/      # BenchClock (mach_absolute_time) + TimerCalibration.
│   │   │       ├── Diff/       # RunDiff (cross-fingerprint refusal + markdown export).
│   │   │       ├── Hardware/   # HardwareInventory.probe() via sysctlbyname.
│   │   │       ├── IO/         # CaseResult, CaseFlag, RunDocument, RunStore, SchemaVersion, MigrationRegistry.
│   │   │       ├── Probes/     # NullWorkload (self-bench). Continuous MemoryProbe not yet implemented.
│   │   │       ├── Provenance/ # BuildProvenance, GitProvenance, FPCRState.
│   │   │       ├── Runner/     # Runner (sync, async-entry), AsyncRunner, RunPreset, WallClockBudget, Cancellation.
│   │   │       ├── Seeds/      # SplitMix64, SeedTable, InputDistribution.
│   │   │       ├── Stats/      # LatencyDistribution, AmortizedResult, BandwidthEstimator.
│   │   │       ├── Util/       # BlackHole (per-thread sink anti-DCE), ReleaseGuard.
│   │   │       ├── Verify/     # ReferenceOracle (Any-typed today — Phase 1.5 item 1 generifies this),
│   │   │       │               # VerificationResult, ULPWindows (shape-dependent function).
│   │   │       └── Workload/   # WorkloadID, CanonicalParams, WorkloadMetadata, BorrowingWorkload,
│   │   │                       # MutatingWorkload, AsyncWorkload.
│   │   └── Tests/BenchKitTests/
│   │       ├── Fixtures/       # DotSmokeWorkload, NormalizeInPlaceSmokeWorkload, AsyncDotSmokeWorkload,
│   │       │                   # CountingWorkload (used by MeasurementProtocolTests).
│   │       ├── BlackHoleTests.swift
│   │       ├── FPCRTests.swift
│   │       ├── LatencyDistributionTests.swift
│   │       ├── MeasurementProtocolTests.swift     # The §2.4 invariants (warm-up, no-overhead-subtract, etc.)
│   │       ├── MutatingRunnerSmokeTests.swift
│   │       ├── NullWorkloadTests.swift
│   │       ├── RunDiffTests.swift
│   │       ├── RunnerSmokeTests.swift
│   │       ├── RunStoreTests.swift
│   │       ├── SplitMix64Tests.swift
│   │       ├── ULPWindowsTests.swift
│   │       └── WorkloadIDTests.swift
│   └── VSBCore/                # First library-target suite. Depends on BenchKit + VectorCore + Accelerate.
│       ├── Package.swift       # `.package(path: "../../../VSK/VectorCore")`
│       ├── Sources/VSBCore/
│       │   ├── Implementations/   # NaiveDotWorkload, AccelerateDotWorkload, SimdDotWorkload,
│       │   │                      # VectorCoreOptimizedDotWorkload, VectorCoreMetricDotWorkload.
│       │   │                      # All currently at dim 512 only.
│       │   ├── Ops/DotShared.swift    # RawFloatDotInput, DotMetadata (bytes/flops formulas).
│       │   ├── Oracles/KahanFloat64DotReference.swift   # kahanFloat64Dot + makeDotOracle factory.
│       │   └── Registry.swift  # VSBCoreRegistry.workloads (5 entries).
│       └── Tests/VSBCoreTests/DotWorkloadTests.swift
└── VectorSuiteBench/           # The Xcode app target shell (still the empty default template — Phase 2).
```

External dependency on **VectorCore** at `/Users/goftin/dev/gsuite/VSK/VectorCore`. Used via SwiftPM local path. The other Phase-N libraries (VectorAccelerate, EmbedKit, VectorIndex) are NOT used yet.

---

## 2. State of play

**53 tests passing** (46 BenchKit + 7 VSBCore). Build from each package dir with `swift test`.

What's working end-to-end today:
- All three Workload protocols compile and run through their respective Runners.
- The Runner is `async` so callers must invoke from a `Task` tree — `@TaskLocal` bindings propagate to `invoke` (load-bearing for VectorCore's `Operations.$simdProvider` etc.).
- `WallClockBudget.perCase` is enforced at every sample/iter boundary; cancellation works mid-warm-up.
- `BlackHole.consume` uses per-thread `pthread_key_t` storage. A `BlackHoleTests` suite verifies the sink advances under realistic candidate-style workloads.
- `MeasurementProtocolTests` verifies the §2.4 invariants: warm-up runs ≥100ms AND ≥50 iters (whichever last); single-shot samples are raw nanos (timer overhead is metadata only); cancellation produces a partial `RunDocument`; per-case budget truncates a runaway workload; bandwidth/GFLOP/s are `nil` when no Amortized samples.
- `RunStore` round-trips runs through `manifest.json` + per-case `cases/<hash>.json` files with atomic temp+rename writes; `index.json` aggregates the sidebar.
- `RunDiff.compare(a:b:)` refuses cross-fingerprint diffs and emits PR-ready markdown.
- `FPCRState` actually reads/writes the AArch64 FPCR via the C bridge.
- VSBCore: 5 Dot workloads at dim 512 (naïve, Accelerate, Apple `simd`, VectorCore-optimized raw, VectorCore-metric). All verify against the Kahan-Float64 oracle.

**Git state:** all work pushed to `main` on `https://github.com/gifton/VectorSuiteBench.git`. Recent commits:
```
0cae571 fix(BenchKit): M1, M2, M3, M6, M8, M9 — anti-DCE hardening, diff, tests
75a1b88 fix(BenchKit): C2 — real FPCR via C bridge target
9ab365d fix(BenchKit): C3, C5, M4, M5, M7 — async runner, budget, rotation, warmup
1ee9e70 fix(BenchKit): C1, C4, C6 — schema/identity/integrity hardening
99086be feat(VSBCore): first concrete workloads — 5 Dot impls verifying via Kahan oracle
dfda493 feat(BenchKit): NullWorkload self-bench (30 tests passing)
00fbac3 feat(BenchKit): IO persistence + Hardware + Provenance, 29 tests passing
1105c78 feat(BenchKit): MutatingWorkload + AsyncRunner paths, 23 tests passing
ad74ef4 feat(BenchKit): scaffold harness package — protocols, runner, 21 passing tests
6a7a07e docs: add Phase 1 design spec (approved)
7b5e494 Initial commit: empty VectorSuiteBench Xcode project
```

User has authorized direct pushes to `main`. Auto-mode classifier may still block them depending on harness config — if it does, ask.

---

## 3. Phase 1.5 — the three items

The user explicitly chose "polish only" for Phase 1.5 — no new runnable surface (no CLI, no RunController, no new op families, no UI). The goal is to tighten the foundation before Phase 2 piles workloads on top.

### Item 1 — Generic `ReferenceOracle<Input, Output>`

**Why now:** today `ReferenceOracle` is `Any`-typed. A workload's oracle takes `Any` as input and returns `ReferenceValue` (which is an enum that includes `.scalar(Double)` etc.). The Workload's metadata exposes `referenceOracle: ReferenceOracle?` via `WorkloadMetadata`.

This was a deliberate compromise during Phase 1 because the registry holds `[any WorkloadMetadata]` for enumeration and the existential demanded type erasure on the oracle. The cost is: a future Workload whose `Input` shape changes silently makes its oracle return `.unverifiable` (after Phase 1's M2 fix) — but the type-mismatch is a runtime trap regardless. Doing this refactor BEFORE more workloads land means each new workload type-checks against a typed oracle at compile time.

**Concrete changes:**

```swift
// BenchKit/Verify/ReferenceOracle.swift
public struct ReferenceOracle<Input, Output>: Sendable {
    public let compute: @Sendable (Input) -> ReferenceValue
    public let compare: @Sendable (Output, ReferenceValue, UInt32) -> VerificationResult
    public init(...) { ... }
}

// BenchKit/Workload/WorkloadMetadata.swift — REMOVE referenceOracle from here
public protocol WorkloadMetadata: Sendable {
    var identifier: WorkloadID { get }
    var bytesMoved: Int { get }
    var flops: Int { get }
    var inputDistribution: InputDistribution { get }
    // referenceOracle MOVES OFF this protocol — see Workload below.
}

// BenchKit/Workload/Workload.swift — typed oracle on each variant
public protocol BorrowingWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output
    var referenceOracle: ReferenceOracle<Input, Output>? { get }
    func makeInput(rng: inout SplitMix64) -> Input
    func invoke(_ input: borrowing Input) -> Output
}

public protocol MutatingWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output
    var referenceOracle: ReferenceOracle<Input, Output>? { get }
    func makeInputs(count K: Int, rng: inout SplitMix64) -> [Input]
    func invoke(_ input: inout Input) -> Output
}

public protocol AsyncWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output
    var referenceOracle: ReferenceOracle<Input, Output>? { get }
    func makeInput(rng: inout SplitMix64) async -> Input
    func invoke(_ input: inout Input) async throws -> Output
}
```

Runner's `verifyBorrowing` / `verifyMutating` / `verifyAsync` now call the typed oracle directly — no `as? Input` / `as? Output` casts.

`makeDotOracle` returns `ReferenceOracle<Input, Float>` (typed). Drops the `extractInput: (Input) -> (a: [Float], b: [Float])?` parameter in favor of the typed `Input`. Each workload's oracle is constructed at the call site with the concrete types in scope. The pragmatic `.unverifiable("oracle type mismatch")` branches added in Phase 1 disappear — they were band-aids for the `Any` erasure.

**Files that need updating:**
- `Packages/BenchKit/Sources/BenchKit/Verify/ReferenceOracle.swift` — generify the struct.
- `Packages/BenchKit/Sources/BenchKit/Workload/WorkloadMetadata.swift` — remove `referenceOracle`.
- `Packages/BenchKit/Sources/BenchKit/Workload/Workload.swift` — add typed oracle to all three protocols.
- `Packages/BenchKit/Sources/BenchKit/Runner/Runner.swift` — `verifyBorrowing` + `verifyMutating` no longer `Any`-cast.
- `Packages/BenchKit/Sources/BenchKit/Runner/AsyncRunner.swift` — `verifyAsync` no longer `Any`-cast.
- `Packages/BenchKit/Sources/BenchKit/Probes/NullWorkload.swift` — `referenceOracle: ReferenceOracle<Input, UInt64>? { nil }`.
- `Packages/BenchKit/Tests/BenchKitTests/Fixtures/DotSmokeWorkload.swift` — inline-build the typed oracle.
- `Packages/BenchKit/Tests/BenchKitTests/Fixtures/NormalizeInPlaceSmokeWorkload.swift` — same.
- `Packages/BenchKit/Tests/BenchKitTests/Fixtures/AsyncDotSmokeWorkload.swift` — same.
- `Packages/BenchKit/Tests/BenchKitTests/Fixtures/CountingWorkload.swift` — same (oracle is `nil` here).
- `Packages/VSBCore/Sources/VSBCore/Oracles/KahanFloat64DotReference.swift` — `makeDotOracle<Input>(...)` returns `ReferenceOracle<Input, Float>`.
- `Packages/VSBCore/Sources/VSBCore/Implementations/*.swift` (all 5 Dot workloads) — typed oracle.

**Acceptance:**
1. `swift test` passes in both packages, with no `as?` casts remaining in Runner verification code paths.
2. `ReferenceOracle` is `<Input, Output>`-parameterized; `WorkloadMetadata` does not mention it.
3. The "type mismatch" `.unverifiable` branches added in Phase 1 M2 are deleted (no longer reachable).

---

### Item 2 — Multi-size Dot for non-VectorCore impls

The three non-VectorCore Dot workloads (`NaiveDotWorkload`, `AccelerateDotWorkload`, `SimdDotWorkload`) are already parameterized by `n`. The registry just stops hard-coding `n: 512` and enumerates them at **64, 256, 512, 1536, 4096**.

**Concrete changes:**
- `Packages/VSBCore/Sources/VSBCore/Registry.swift` — replace the five `n: 512` entries with a Cartesian product. New workloads:
  - `NaiveDotWorkload(n:)` × 5 sizes
  - `AccelerateDotWorkload(n:)` × 5 sizes
  - `SimdDotWorkload(n:)` × 5 sizes
- Typed accessors (`VSBCoreRegistry.naiveDot512` etc.) — keep `*Dot512` for backwards compat with tests; add `naiveDot(n:)` factory.
- `Packages/VSBCore/Tests/VSBCoreTests/DotWorkloadTests.swift` — parameterize the verification test across all sizes for at least naïve + Accelerate. (Per-size test cases via `@Test(arguments:)` if Swift Testing's parameterized form is in scope; otherwise loop in the test body.)

**Acceptance:**
1. `VSBCoreRegistry.workloads` count grows by 12 (5×3 baselines minus the existing 3 at dim 512 already there).
2. All baseline impls verify at every size (no false-negative ULP failures).
3. Sanity-check that naïve at N=4096 still fits the ULP window — left-to-right Float32 summation has O(N·ε) error which at 4096 is ~500 ULPs; the `.standard` formula `4 + 2·log2(N)` gives 28 ULPs. **The naïve impl may exceed this**, in which case the right fix is to either (a) widen the `.standard` window with an additive constant, or (b) add a new `ImplClass` (`.naive`?) with a wider window, or (c) accept the verification failure and document it. The reviewer noted this in their original M-tier items. **Decide and document** before declaring acceptance.

---

### Item 3 — All three VectorCore flavors for Dot

VectorCore exposes three flavors of dot-supporting type at dim N:
- `VectorN`Optimized — fused SIMD4 kernel, only at the dims VectorCore specialized (per Phase 1 exploration: 384, 512, 768, 1024, 1536). Of our size set, that's **512 and 1536**.
- `Vector<DimN>` — generic over a static dimension via `D: StaticDimension`. Available at any static dim VectorCore declares (`Dim64`, `Dim256`, `Dim512`, etc. — verify the actual set in VectorCore/Sources/VectorCore/).
- `DynamicVector(dimension:)` — runtime-dimension heap-backed type. Any N.

**Concrete changes:**

```swift
// Packages/VSBCore/Sources/VSBCore/Implementations/VectorCoreGenericDotWorkload.swift
public struct VectorCoreGenericDotWorkload<D: StaticDimension>: BorrowingWorkload {
    public struct Input {
        public var a: Vector<D>
        public var b: Vector<D>
        public var aRaw: [Float]
        public var bRaw: [Float]
    }
    public typealias Output = Float

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "generic", "api": "raw"],
            impl: .vectorCore, op: .dot, shape: .vector(n: D.value)
        )
        return WorkloadID(op: .dot, impl: .vectorCore, implClass: .standard,
                          dtype: .f32, shape: .vector(n: D.value), params: params)
    }
    // ... bytesMoved/flops/inputDistribution/referenceOracle (typed; see Item 1) ...
    // ... makeInput builds Vector<D> from a [Float] of length D.value ...
    // ... invoke returns input.a.dotProduct(input.b)
}

// Packages/VSBCore/Sources/VSBCore/Implementations/VectorCoreDynamicDotWorkload.swift
public struct VectorCoreDynamicDotWorkload: BorrowingWorkload {
    // Same shape; Input wraps DynamicVector(dimension: n). n is stored.
    public let n: Int
    // ...
}
```

Registry adds:
- `VectorCoreOptimizedDotWorkload` at dim 1536 (the existing one stays at 512).
- `VectorCoreGenericDotWorkload<Dim64>`, `<Dim256>`, `<Dim512>`, `<Dim1536>`, `<Dim4096>` (verify these StaticDimension types exist in VectorCore; if not, only the ones that do).
- `VectorCoreDynamicDotWorkload(n: 64)`, `(n: 256)`, `(n: 512)`, `(n: 1536)`, `(n: 4096)`.

**Important:** VectorCore-metric (`VectorCoreMetricDotWorkload`) stays at dim 512 only. User chose this explicitly — its job is to demonstrate sign-convention handling, not characterize DotProductDistance across sizes. Phase 2 can expand if/when DotProductDistance perf becomes its own focus.

**Files:**
- `Packages/VSBCore/Sources/VSBCore/Implementations/VectorCoreGenericDotWorkload.swift` (new).
- `Packages/VSBCore/Sources/VSBCore/Implementations/VectorCoreDynamicDotWorkload.swift` (new).
- `Packages/VSBCore/Sources/VSBCore/Implementations/VectorCoreOptimizedDotWorkload.swift` — add `n: Int` parameter (currently hard-coded to 512); registry instantiates at 512 and 1536. Or keep two distinct types (one per dim) — whatever's cleanest given VectorCore's `Vector512Optimized` vs `Vector1536Optimized` being distinct types. (Almost certainly two distinct types; `Vector512Optimized` is not generic.)
- `Packages/VSBCore/Sources/VSBCore/Registry.swift` — full expansion.
- `Packages/VSBCore/Tests/VSBCoreTests/DotWorkloadTests.swift` — extend coverage. Test that all three VectorCore flavors at dim 512 produce the same +a·b value (within their ULP windows) given the same seeded input.

**Acceptance:**
1. Registry grows to ≈28 Dot cases (see breakdown in Item 3 of the plan summary above).
2. Generic and Dynamic flavors verify at every size.
3. Optimized flavor verifies at 512 and 1536.
4. WorkloadID `params["vectorflavor"]` correctly distinguishes the three flavors — round-trip canonicalization still passes for every registered workload.

---

## 4. Validation

Run from each package dir:

```bash
cd Packages/BenchKit && swift test
cd Packages/VSBCore && swift test
```

Both should pass before declaring Phase 1.5 done. Combined: should be ≥53 tests passing (current count) plus a handful of new ones from the size/flavor expansion.

**No CLI exists yet** (Phase 2 deliverable). To exercise the runner manually, write a tiny Swift test that runs `VSBCoreRegistry.workloads` through `Runner.run` and prints the results. Don't ship this as a target — Phase 2 will do this properly with a `RunController`.

---

## 5. Conventions to follow

- **Plan file mode is OFF.** Edit any file directly; no special permission needed.
- **Test framework:** Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`, `Comment(rawValue:)` for failure messages — not strings). XCTest is NOT used here.
- **No SourceKit pre-resolution:** SwiftPM cross-file references show as "Cannot find type X" in LSP until `swift build` runs. Ignore those diagnostics; run `swift test` to validate.
- **`borrowing Input` requires Input to be a struct, not a tuple.** Swift 6 borrow checker rejects tuple field access in a borrowing context as "consumed."
- **`Clock` is `BenchClock` in our namespace** — Swift stdlib's `Clock` protocol collides if we use the bare name.
- **Concurrency:** `Sendable` everywhere. `CancellationToken` uses `OSAllocatedUnfairLock<Bool>` (no swift-atomics dep).
- **WorkloadID identity rules are sacred.** Renaming an enum case is a breaking schema change. Use `@CodableKey` aliasing if you must.
- **`params["vectorflavor"]` is required iff `impl == .vectorCore`.** Canonicalizer enforces this. Don't put `vectorflavor` on non-VectorCore workloads.
- **CSV/JSON schema:** wire-names of every enum case are frozen. `SchemaVersion` decodes from `"major.minor"`.

---

## 6. What Phase 1.5 explicitly does NOT include (Phase 2 territory)

- **`RunController`** (orchestrate registry → CaseResult → RunDocument). Phase 2.
- **Headless CLI executable** (`vsb-run`). Phase 2.
- **`PeakMeasurement`** (FMA microkernel + STREAM-triad). Phase 2.
- **`CSVExporter`**. Phase 2.
- **Continuous `MemoryProbe`** (100 Hz background sampling during Amortized). Phase 2.
- **New op families** (L2 distance, cosine, normalize, AXPY, Top-K, pairwiseDistances, distanceMatrix). Phase 2 picks an order.
- **App target wiring** (RunConfigView, RunListSidebar, RunDetailView, DiffPaneView, the five Swift Charts compositions). Phase 2 likely splits this into its own slice.
- **MetricKit energy, Metal Performance Counters, ANE, FAISS bridge, iOS target.** Out of scope until Phases 3–5.

If the next agent finds themselves writing any of those, they're outside the locked scope of 1.5. Stop and re-confirm with the user.

---

## 7. Known follow-ups / minor items left after 1.5

(Carried from the Phase 1 code review. None are blocking 1.5; all can land in Phase 2 alongside the bigger work.)

- **m4** — `HardwareInventory.gpuCoreCount` is always `0` (no IORegistry probe). The `fingerprint` still works for cross-machine diff because chip + core counts uniquely identify, but the field is uninformative.
- **m6** — `LatencyDistribution.looksBimodal` uses a fixed 1.5× heuristic. Should be a named constant with citation, or learned from data.
- **m8** — `NaiveDotWorkload`'s `.standard` ImplClass may exceed the standard ULP window at N=4096 (its O(N·ε) drift). See Item 2 acceptance criterion 3. If the fix is "widen the window," do it during Item 2.
- **m11** — `try!` on every workload's `identifier` could be replaced with a top-level `static let`. Cosmetic.
- **Removed**: the `extractInput: (Input) -> (a: [Float], b: [Float])?` parameter on `makeDotOracle` — Item 1 obsoletes this entirely.

---

## 8. How to start

1. Read `docs/phase-1-design.md` end-to-end. Especially §2.1, §2.2, §5, §9. The spec is the truth.
2. Read this doc (you are here).
3. Run `swift test` in both packages. Confirm 53 tests pass before touching anything.
4. Implement Item 1 (generic `ReferenceOracle`). Commit. `swift test` should still show 53+ passing.
5. Implement Item 2 (multi-size baseline Dots). Commit. Confirm any verification-failure edge cases are resolved per the acceptance criterion.
6. Implement Item 3 (VectorCore flavors). Commit. Final test count should be in the 60s.
7. Push to `main`. Update this doc's "State of play" section with the new commit list and announce Phase 1.5 complete.

Estimated time: 3–4 focused sessions. Item 1 is the biggest (touches every workload); Items 2 and 3 are mostly additive enumeration.

If anything in this doc reads as ambiguous or you hit a real architectural decision, **stop and ask the user before guessing**. The Phase 1 review revealed that one round of explicit-prioritization conversation up front saves many rounds of fix-and-revert later.
