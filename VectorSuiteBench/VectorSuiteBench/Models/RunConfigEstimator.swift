import Foundation
import BenchKit

/// Pure-function estimator for the New Run modal's live footer. Lowers a
/// `RunConfig` to the trio displayed in design doc §05:
/// `~N cases · ~Mm Ss wall · ~K MB JSON` plus a small breakdown grid
/// (`"5 ops · 5 impls · 7 sizes · shot + loop"`).
///
/// **Cases** are exact — Cartesian product of `ops × impls × sizes × modes`.
/// Tests pin this number.
///
/// **Wall** is uniform-per-mode rough — Phase 2.0 only measured `dot`,
/// so we don't have real timings for the other 7 ops. Per locked
/// decision the estimator uses a uniform `samples × 100 ns` per SHOT
/// case + a flat `15 s` per LOOP case (warm-up + amortized loop
/// dominated by clock-resolution overhead). Plan §4 allows ±50 %.
/// Refined in a later phase once 4c provides actual new-run data
/// against which we can recalibrate.
///
/// **Bytes** ≈ cases × 32 KB per `CaseResult` JSON (Phase 2.0 average
/// measured size). Same refine-later disclaimer.
///
/// **Isolation.** The enum itself is `nonisolated` so the format
/// helpers (`formatCases`, `formatWall`, `formatBytes`,
/// `formatBytesUnit`, `makeBreakdown`, `plural`) and the value-taking
/// `estimate(inputs:)` overload stay callable from any context — tests
/// in particular. The `estimate(_ config:)` convenience that reads a
/// `@MainActor RunConfig` is itself `@MainActor` because it touches
/// MainActor-isolated state; same-actor calls from view bodies are
/// free.
nonisolated enum RunConfigEstimator {

    /// Result struct surfaced to the view. All four fields are
    /// presentation-ready: `cases` is the exact integer, `wallSeconds`
    /// is the raw double for any future use, `bytes` is the raw byte
    /// count, and `breakdown` is the already-formatted right-side
    /// caption string.
    struct Estimate: Equatable, Sendable {
        let cases: Int
        let wallSeconds: Double
        let bytes: Int
        let breakdown: String
    }

    // MARK: - Constants (refine when 4c provides recalibration data)

    /// SHOT per-sample time at the **`dot` baseline**. Multiplied by
    /// `Inputs.opWeightAverage` so per-op cost differences are reflected
    /// when the user's selection mixes vector ops with the (much pricier)
    /// async families. 100 ns is the order of magnitude observed in
    /// Phase 2.0's `dot` smoke run.
    static let shotNanosPerSample: Double = 100

    /// LOOP per-case wall time at the **`dot` baseline**. Same per-op
    /// scaling caveat as above. The K-iteration loop runs ≥100 µs to
    /// clear clock resolution; ~100 loops + warm-up + thermal pauses
    /// land in the ~10–20 s range. 15 s is the midpoint.
    static let loopSecondsPerCase: Double = 15.0

    /// Per-case JSON file size. Phase 2.0 measured average; the actual
    /// bytes scale with the latency-distribution sample count + the
    /// length of any memory trace, but the 32 KB constant covers the
    /// dot case at default sample count comfortably.
    static let bytesPerCase: Int = 32 * 1024

    /// Per-op cost multiplier relative to `dot`. Used to inflate the
    /// otherwise-uniform SHOT and LOOP estimates when async ops like
    /// `distanceMatrix` dominate the selection. ±50 % accuracy per
    /// plan §4 (Phase 1 design §3). Values are rough order-of-magnitude
    /// guesses keyed off spec §9 cycles-per-case arithmetic:
    /// - Borrowing-family vector ops (`dot`, `l2dist`, `cosine`,
    ///   `normalize`, `axpy`) share `dot`'s arithmetic intensity to
    ///   within a factor of ~2; weights stay near 1.
    /// - `topK` partial-sorts across 1 K – 100 K candidates per call,
    ///   so per-case cost is ~50× dot.
    /// - `pairwiseDistances` and `distanceMatrix` compute M × N × D
    ///   inner products per call; at spec §9 sizes those reach 3 M
    ///   (Standard pairwise 64×64×768) up to 25 G ops
    ///   (Full distanceMatrix 4096² × 1536). Picked to roughly match
    ///   the ratio at Standard sizes.
    /// - `null` (NullWorkload self-bench) is the harness floor and never
    ///   appears in user-selected `OpKind` sets; included for
    ///   completeness so an exhaustive switch on OpKind has a value.
    static let opWeights: [OpKind: Double] = [
        .dot:               1.0,
        .l2dist:            1.0,
        .cosine:            1.5,
        .normalize:         0.8,
        .axpy:              0.8,
        .topK:              50.0,
        .pairwiseDistances: 200.0,
        .distanceMatrix:    500.0,
        .null:              0.01,
    ]

    /// Mean weight across an arbitrary `OpKind` set. Defaults to 1.0
    /// for an empty set so the wrapper's calculation doesn't divide by
    /// zero (and so an empty-ops UI state produces the same wall as
    /// dot-only — visually consistent with "you selected nothing,
    /// the estimate is the baseline").
    static func averageOpWeight(_ ops: Set<OpKind>) -> Double {
        guard !ops.isEmpty else { return 1.0 }
        let sum = ops.reduce(0.0) { $0 + (opWeights[$1] ?? 1.0) }
        return sum / Double(ops.count)
    }

    // MARK: - Estimate

    /// Plain-value inputs the pure estimator consumes. The
    /// `@MainActor` wrapper that takes a full `RunConfig` reads
    /// individual properties and packs them into this struct;
    /// nonisolated tests bypass `RunConfig` and pass values directly.
    struct Inputs: Equatable, Sendable {
        let opsCount: Int
        let implsCount: Int
        let sizesCount: Int
        let modes: ModesSelection
        let sampleCount: Int
        /// Mean `OpKind` cost weight (vs `dot` baseline). The MainActor
        /// wrapper derives it via `RunConfigEstimator.averageOpWeight(_:)`
        /// over `config.ops`; tests hitting the pure overload leave it
        /// at the 1.0 default unless asserting per-op scaling.
        let opWeightAverage: Double

        init(
            opsCount: Int,
            implsCount: Int,
            sizesCount: Int,
            modes: ModesSelection,
            sampleCount: Int,
            opWeightAverage: Double = 1.0
        ) {
            self.opsCount = opsCount
            self.implsCount = implsCount
            self.sizesCount = sizesCount
            self.modes = modes
            self.sampleCount = sampleCount
            self.opWeightAverage = opWeightAverage
        }
    }

    /// Pure-function estimator over plain values. `nonisolated` — same
    /// pattern as `CaseTableFilterLogic.apply(...)`. Tests target this
    /// overload directly so they don't need to construct a `RunConfig`
    /// for every case.
    static func estimate(inputs: Inputs) -> Estimate {
        let cases = inputs.opsCount * inputs.implsCount * inputs.sizesCount * inputs.modes.asModes.count
        let casesPerMode = inputs.opsCount * inputs.implsCount * inputs.sizesCount

        // SHOT contribution: every SHOT case takes `samples × per-sample
        // ns`. LOOP contribution: every LOOP case takes a fixed wall
        // time independent of `samples` (the K-iteration loop's
        // sample-count is auto-tuned by the harness, not by the modal's
        // samples picker).
        let modesActive = inputs.modes.asModes
        let shotCases = modesActive.contains(.singleShot) ? casesPerMode : 0
        let loopCases = modesActive.contains(.amortized) ? casesPerMode : 0
        let shotWall = Double(shotCases) * Double(inputs.sampleCount) * shotNanosPerSample * inputs.opWeightAverage * 1e-9
        let loopWall = Double(loopCases) * loopSecondsPerCase * inputs.opWeightAverage
        let wallSeconds = shotWall + loopWall

        let bytes = cases * bytesPerCase
        let breakdown = makeBreakdown(
            ops: inputs.opsCount,
            impls: inputs.implsCount,
            sizes: inputs.sizesCount,
            modes: inputs.modes
        )

        return Estimate(
            cases: cases,
            wallSeconds: wallSeconds,
            bytes: bytes,
            breakdown: breakdown
        )
    }

    /// MainActor convenience that reads a `RunConfig` and delegates to
    /// the pure-function `estimate(inputs:)` overload. View bodies
    /// call this; tests use the `Inputs`-taking overload.
    @MainActor
    static func estimate(_ config: RunConfig) -> Estimate {
        estimate(inputs: Inputs(
            opsCount: config.ops.count,
            implsCount: config.impls.count,
            sizesCount: config.sizes.count,
            modes: config.modes,
            sampleCount: config.sampleCount.count,
            opWeightAverage: averageOpWeight(config.ops)
        ))
    }

    // MARK: - Breakdown copy

    /// `"5 ops · 5 impls · 7 sizes · shot + loop"`. Per locked decision
    /// we drop the dtypes term (Phase 2.1 has no dtype selector, so the
    /// implicit `× 1` would just read as noise). When Phase 2.2 adds
    /// dtypes, the term re-appears here naturally.
    static func makeBreakdown(
        ops: Int, impls: Int, sizes: Int, modes: ModesSelection
    ) -> String {
        let modesText: String
        switch modes {
        case .shotOnly: modesText = "shot"
        case .loopOnly: modesText = "loop"
        case .both:     modesText = "shot + loop"
        }
        return "\(plural(ops, "op")) · \(plural(impls, "impl")) · \(plural(sizes, "size")) · \(modesText)"
    }

    /// `"1 op"` / `"5 ops"`. Singular form when n == 1.
    static func plural(_ n: Int, _ singular: String) -> String {
        "\(n) \(singular)\(n == 1 ? "" : "s")"
    }

    // MARK: - Formatters for the footer cells

    /// Footer "cases" cell value. `"342"` for small counts, `"1.2K"`
    /// for ≥ 1000 so the number doesn't blow the cell width on a Full
    /// preset with 1500+ cases. The "cases" label is rendered
    /// separately by the cell.
    static func formatCases(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }

    /// Footer "wall" cell — composite duration string with units baked
    /// in: `"30s"`, `"4m 50s"`, `"2h 15m"`. Mirrors
    /// `RunSummaryGrouping.formatDuration(nanos:)` from the sidebar so
    /// run-config and run-summary durations read identically.
    static func formatWall(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            return "\(total)s"
        }
        let mins = total / 60
        if mins < 60 {
            let secs = total - mins * 60
            return "\(mins)m \(secs)s"
        }
        let hours = mins / 60
        let remainingMins = mins - hours * 60
        return "\(hours)h \(remainingMins)m"
    }

    /// Footer "bytes" cell value. `"12"` for MB-scale, `"512"` for
    /// KB-scale. Pair with `formatBytesUnit(_:)` to render
    /// `"12 MB JSON"` or `"512 KB JSON"`.
    static func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1.0 {
            return "\(Int(mb.rounded()))"
        }
        let kb = Double(bytes) / 1024
        return "\(Int(kb.rounded()))"
    }

    /// `"MB JSON"` or `"KB JSON"` depending on scale. The cell renders
    /// these as a separate `vsbMonoSha` trailing label so the unit sits
    /// at `text-lo` while the number sits at accent.
    static func formatBytesUnit(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1.0 ? "MB JSON" : "KB JSON"
    }
}
