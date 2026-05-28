import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// Tests for the live-footer estimator. The pure-function overload
/// (`estimate(inputs:)`) is nonisolated, so most tests run without
/// MainActor ceremony — they construct `Inputs` directly and pin the
/// expected `Estimate`. A small @MainActor smoke test confirms the
/// `estimate(_ config:)` convenience wires through to the same logic.
///
/// Coverage focus:
/// - **Cases must be exact** (plan §4 — the case count is the
///   load-bearing number engineers commit to).
/// - **Wall direction**: more selections → more wall; SHOT cases scale
///   with sample count, LOOP cases don't.
/// - **Bytes scales linearly** with case count.
/// - **Breakdown** copy uses singular/plural correctly and renders the
///   three mode variants.
/// - **Format helpers**: cases (small vs K), wall (s / m+s / h+m),
///   bytes (KB vs MB scale).
@Suite("RunConfigEstimator")
struct RunConfigEstimatorTests {

    // MARK: - Case count (exact)

    @Test("Smoke preset shape: 3 ops × 3 impls × 1 size × 1 mode = 9 cases")
    func smokeShape() {
        let inputs = RunConfigEstimator.Inputs(
            opsCount: 3,           // dot, l2dist, cosine
            implsCount: 3,         // VectorCore, Accelerate, naïve
            sizesCount: 1,         // n=512
            modes: .shotOnly,      // single-shot only
            sampleCount: 100
        )
        let e = RunConfigEstimator.estimate(inputs: inputs)
        #expect(e.cases == 9, Comment(rawValue: "smoke = 3·3·1·1 = 9"))
    }

    @Test("Standard preset shape: all ops × all impls × 2 sizes × 2 modes")
    func standardShape() {
        // OpKind has 9 cases (8 user-facing + .null); standard excludes .null.
        // ImplKind has 4 cases. Standard preset uses sizes {256, 1536} and
        // both modes.
        let inputs = RunConfigEstimator.Inputs(
            opsCount: 8,           // all OpKind except .null
            implsCount: 4,         // all ImplKind
            sizesCount: 2,         // 256, 1536
            modes: .both,
            sampleCount: 500
        )
        let e = RunConfigEstimator.estimate(inputs: inputs)
        #expect(e.cases == 8 * 4 * 2 * 2, Comment(rawValue: "standard = 8·4·2·2 = 128"))
    }

    @Test("Full preset shape: 8 ops × 4 impls × 6 sizes × 2 modes")
    func fullShape() {
        let inputs = RunConfigEstimator.Inputs(
            opsCount: 8,
            implsCount: 4,
            sizesCount: 6,         // {64, 256, 512, 1024, 1536, 4096}
            modes: .both,
            sampleCount: 1000
        )
        let e = RunConfigEstimator.estimate(inputs: inputs)
        #expect(e.cases == 8 * 4 * 6 * 2, Comment(rawValue: "full = 8·4·6·2 = 384"))
    }

    @Test("Zero on any axis → zero cases")
    func zeroAxis() {
        for inputs in [
            RunConfigEstimator.Inputs(opsCount: 0, implsCount: 4, sizesCount: 6, modes: .both, sampleCount: 500),
            RunConfigEstimator.Inputs(opsCount: 8, implsCount: 0, sizesCount: 6, modes: .both, sampleCount: 500),
            RunConfigEstimator.Inputs(opsCount: 8, implsCount: 4, sizesCount: 0, modes: .both, sampleCount: 500),
            // `modes` is an enum so can't be "empty" in the same way;
            // but `.asModes.count == 0` is impossible since each variant
            // has ≥1 mode. Covered by enum exhaustiveness.
        ] {
            let e = RunConfigEstimator.estimate(inputs: inputs)
            #expect(e.cases == 0, Comment(rawValue: "any empty axis collapses cases to 0"))
            #expect(e.bytes == 0, Comment(rawValue: "0 cases means 0 bytes"))
        }
    }

    // MARK: - Cases scale with each axis

    @Test("Adding one op increases cases by (impls × sizes × modes)")
    func opsScaling() {
        let base = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let plusOne = RunConfigEstimator.Inputs(
            opsCount: 4, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let delta = RunConfigEstimator.estimate(inputs: plusOne).cases
                  - RunConfigEstimator.estimate(inputs: base).cases
        #expect(delta == 4 * 2 * 2, Comment(rawValue: "adding 1 op adds impls·sizes·modes cases"))
    }

    @Test("Adding one impl increases cases by (ops × sizes × modes)")
    func implsScaling() {
        let base = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let plusOne = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 5, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let delta = RunConfigEstimator.estimate(inputs: plusOne).cases
                  - RunConfigEstimator.estimate(inputs: base).cases
        #expect(delta == 3 * 2 * 2)
    }

    @Test("Adding one size increases cases by (ops × impls × modes)")
    func sizesScaling() {
        let base = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let plusOne = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 3, modes: .both, sampleCount: 500
        )
        let delta = RunConfigEstimator.estimate(inputs: plusOne).cases
                  - RunConfigEstimator.estimate(inputs: base).cases
        #expect(delta == 3 * 4 * 2)
    }

    @Test("Switching from one mode to both doubles the case count")
    func modesScaling() {
        let oneMode = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .shotOnly, sampleCount: 500
        )
        let twoModes = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let single = RunConfigEstimator.estimate(inputs: oneMode).cases
        let both = RunConfigEstimator.estimate(inputs: twoModes).cases
        #expect(both == single * 2)
    }

    // MARK: - Wall (uniform per-mode model)

    @Test("SHOT wall scales with sample count")
    func shotWallScalesWithSamples() {
        let lowSamples = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .shotOnly, sampleCount: 100
        )
        let highSamples = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .shotOnly, sampleCount: 1000
        )
        let lo = RunConfigEstimator.estimate(inputs: lowSamples).wallSeconds
        let hi = RunConfigEstimator.estimate(inputs: highSamples).wallSeconds
        // 10× sample count → 10× wall in SHOT mode.
        #expect(hi.isApproximatelyEqual(to: lo * 10, relativeTolerance: 0.001),
                Comment(rawValue: "got SHOT wall low=\(lo)s, high=\(hi)s — expected 10× scaling"))
    }

    @Test("LOOP wall is independent of sample count")
    func loopWallIgnoresSamples() {
        let lowSamples = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .loopOnly, sampleCount: 100
        )
        let highSamples = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .loopOnly, sampleCount: 1000
        )
        let lo = RunConfigEstimator.estimate(inputs: lowSamples).wallSeconds
        let hi = RunConfigEstimator.estimate(inputs: highSamples).wallSeconds
        // LOOP wall depends on case count only, not on samples (the
        // harness auto-tunes K to clear clock resolution).
        #expect(lo == hi,
                Comment(rawValue: "LOOP wall must not depend on samples; got lo=\(lo) hi=\(hi)"))
    }

    @Test("Both modes have non-zero wall and total = SHOT + LOOP contributions")
    func bothModesWallAdds() {
        let inputs = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let bothWall = RunConfigEstimator.estimate(inputs: inputs).wallSeconds
        let shotOnly = RunConfigEstimator.estimate(inputs:
            RunConfigEstimator.Inputs(opsCount: 3, implsCount: 4, sizesCount: 2, modes: .shotOnly, sampleCount: 500)
        ).wallSeconds
        let loopOnly = RunConfigEstimator.estimate(inputs:
            RunConfigEstimator.Inputs(opsCount: 3, implsCount: 4, sizesCount: 2, modes: .loopOnly, sampleCount: 500)
        ).wallSeconds
        #expect(bothWall.isApproximatelyEqual(to: shotOnly + loopOnly, relativeTolerance: 0.001),
                Comment(rawValue: "both=\(bothWall) ≠ shot(\(shotOnly)) + loop(\(loopOnly))"))
    }

    // MARK: - Bytes

    @Test("Bytes = cases × 32 KB")
    func bytesLinearInCases() {
        let inputs = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let e = RunConfigEstimator.estimate(inputs: inputs)
        #expect(e.bytes == e.cases * RunConfigEstimator.bytesPerCase)
    }

    // MARK: - Breakdown copy

    @Test("Breakdown renders all three mode variants")
    func breakdownModes() {
        #expect(RunConfigEstimator.makeBreakdown(ops: 5, impls: 4, sizes: 3, modes: .shotOnly)
                == "5 ops · 4 impls · 3 sizes · shot")
        #expect(RunConfigEstimator.makeBreakdown(ops: 5, impls: 4, sizes: 3, modes: .loopOnly)
                == "5 ops · 4 impls · 3 sizes · loop")
        #expect(RunConfigEstimator.makeBreakdown(ops: 5, impls: 4, sizes: 3, modes: .both)
                == "5 ops · 4 impls · 3 sizes · shot + loop")
    }

    @Test("Breakdown singular/plural toggles at 1")
    func breakdownPlural() {
        #expect(RunConfigEstimator.makeBreakdown(ops: 1, impls: 1, sizes: 1, modes: .shotOnly)
                == "1 op · 1 impl · 1 size · shot")
        #expect(RunConfigEstimator.plural(0, "op") == "0 ops",
                Comment(rawValue: "zero is plural — '0 cases' reads naturally, '0 case' doesn't"))
    }

    // MARK: - Format helpers

    @Test("formatCases — integer for <1K, fractional K for ≥1K")
    func formatCases() {
        #expect(RunConfigEstimator.formatCases(0) == "0")
        #expect(RunConfigEstimator.formatCases(342) == "342")
        #expect(RunConfigEstimator.formatCases(999) == "999")
        #expect(RunConfigEstimator.formatCases(1000) == "1.0K")
        #expect(RunConfigEstimator.formatCases(1234) == "1.2K")
        #expect(RunConfigEstimator.formatCases(12_000) == "12.0K")
    }

    @Test("formatWall — seconds, minutes+seconds, hours+minutes")
    func formatWall() {
        #expect(RunConfigEstimator.formatWall(0) == "0s")
        #expect(RunConfigEstimator.formatWall(30) == "30s")
        #expect(RunConfigEstimator.formatWall(59.4) == "59s")     // rounds to 59
        #expect(RunConfigEstimator.formatWall(60) == "1m 0s")
        #expect(RunConfigEstimator.formatWall(290) == "4m 50s")
        #expect(RunConfigEstimator.formatWall(3600) == "1h 0m")
        #expect(RunConfigEstimator.formatWall(8100) == "2h 15m")
    }

    @Test("formatBytes — KB scale below 1MB, MB scale above")
    func formatBytes() {
        #expect(RunConfigEstimator.formatBytes(0) == "0")
        #expect(RunConfigEstimator.formatBytes(32 * 1024) == "32")
        #expect(RunConfigEstimator.formatBytesUnit(32 * 1024) == "KB JSON")
        let oneMB = 1024 * 1024
        #expect(RunConfigEstimator.formatBytes(oneMB) == "1")
        #expect(RunConfigEstimator.formatBytesUnit(oneMB) == "MB JSON")
        #expect(RunConfigEstimator.formatBytes(12 * oneMB) == "12")
        #expect(RunConfigEstimator.formatBytesUnit(12 * oneMB) == "MB JSON")
    }

    // MARK: - MainActor RunConfig wrapper

    @MainActor
    @Test("estimate(_ config:) wrapper produces the same shape as estimate(inputs:)")
    func mainActorWrapperRoundtrip() {
        let config = RunConfig()  // smoke defaults
        let viaConfig = RunConfigEstimator.estimate(config)
        let viaInputs = RunConfigEstimator.estimate(inputs:
            RunConfigEstimator.Inputs(
                opsCount: config.ops.count,
                implsCount: config.impls.count,
                sizesCount: config.sizes.count,
                modes: config.modes,
                sampleCount: config.sampleCount.count,
                opWeightAverage: RunConfigEstimator.averageOpWeight(config.ops)
            )
        )
        #expect(viaConfig == viaInputs)
    }

    // MARK: - Per-op weight scaling

    @Test("opWeightAverage = 1.0 default preserves baseline (dot-only equivalent)")
    func opWeightDefaultMatchesBaseline() {
        // Two identical inputs — one with implicit default opWeightAverage,
        // one with explicit 1.0. Identical estimates confirm the default
        // matches the dot-only baseline.
        let implicitDefault = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500
        )
        let explicitBaseline = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500,
            opWeightAverage: 1.0
        )
        #expect(RunConfigEstimator.estimate(inputs: implicitDefault)
                == RunConfigEstimator.estimate(inputs: explicitBaseline))
    }

    @Test("Higher opWeightAverage scales wall (SHOT + LOOP) proportionally")
    func opWeightScalesWall() {
        let baseline = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500,
            opWeightAverage: 1.0
        )
        let heavy = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500,
            opWeightAverage: 10.0
        )
        let baseWall = RunConfigEstimator.estimate(inputs: baseline).wallSeconds
        let heavyWall = RunConfigEstimator.estimate(inputs: heavy).wallSeconds
        // 10× weight → 10× wall. Both SHOT and LOOP contributions scale.
        #expect(heavyWall.isApproximatelyEqual(to: baseWall * 10, relativeTolerance: 0.001),
                Comment(rawValue: "10× weight should yield 10× wall; base=\(baseWall) heavy=\(heavyWall)"))
    }

    @Test("opWeightAverage does NOT affect case count or bytes")
    func opWeightLeavesCasesAndBytesAlone() {
        let baseline = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500,
            opWeightAverage: 1.0
        )
        let heavy = RunConfigEstimator.Inputs(
            opsCount: 3, implsCount: 4, sizesCount: 2, modes: .both, sampleCount: 500,
            opWeightAverage: 100.0
        )
        let base = RunConfigEstimator.estimate(inputs: baseline)
        let hi = RunConfigEstimator.estimate(inputs: heavy)
        #expect(base.cases == hi.cases, Comment(rawValue: "opWeight is a wall multiplier; case count is structural"))
        #expect(base.bytes == hi.bytes, Comment(rawValue: "opWeight does not change per-case JSON size"))
    }

    @Test("opWeights table covers every OpKind (registry-completeness)")
    func opWeightsCoverEveryOpKind() {
        // Each OpKind must have an entry in the weight table; otherwise
        // a user selecting a newly-added op silently falls back to the
        // averageOpWeight default and the estimator silently mis-predicts.
        // A missing entry is a registry bug we want to catch at test time.
        for op in OpKind.allCases {
            #expect(RunConfigEstimator.opWeights[op] != nil,
                    Comment(rawValue: "OpKind.\(op.rawValue) missing from RunConfigEstimator.opWeights"))
        }
    }

    @Test("averageOpWeight of empty set returns the 1.0 baseline (no divide-by-zero)")
    func averageOpWeightOfEmptySetIsBaseline() {
        let empty: Set<OpKind> = []
        #expect(RunConfigEstimator.averageOpWeight(empty) == 1.0)
    }

    @Test("averageOpWeight of dot-only matches the dot weight exactly")
    func averageOpWeightOfDotOnly() {
        let dotOnly: Set<OpKind> = [.dot]
        let avg = RunConfigEstimator.averageOpWeight(dotOnly)
        #expect(avg == RunConfigEstimator.opWeights[.dot])
    }

    @Test("averageOpWeight of mixed selection produces the arithmetic mean")
    func averageOpWeightOfMixedSelection() {
        // Pick a heavy op (distanceMatrix=500) and a light op (axpy=0.8).
        // Mean = (500 + 0.8) / 2 = 250.4.
        let mixed: Set<OpKind> = [.distanceMatrix, .axpy]
        let expected = (RunConfigEstimator.opWeights[.distanceMatrix]! +
                        RunConfigEstimator.opWeights[.axpy]!) / 2.0
        let actual = RunConfigEstimator.averageOpWeight(mixed)
        #expect(actual.isApproximatelyEqual(to: expected, relativeTolerance: 1e-12),
                Comment(rawValue: "expected mean \(expected); got \(actual)"))
    }
}

// MARK: - Test helpers

private extension Double {
    /// Approximate-equality with relative tolerance — `abs(self - other)
    /// / abs(other) ≤ tolerance`. Used by the wall-time tests because
    /// floating-point arithmetic on the same expression structure
    /// shouldn't drift, but a relative tolerance is defensive against
    /// future formula changes that introduce tiny rounding error.
    func isApproximatelyEqual(to other: Double, relativeTolerance: Double) -> Bool {
        if self == other { return true }
        if other == 0 { return abs(self) <= relativeTolerance }
        return abs(self - other) / abs(other) <= relativeTolerance
    }
}
