import Foundation

/// The harness's self-bench. `invoke` does nothing measurable — its cost is
/// the floor for the entire measurement stack: clock read + BlackHole
/// consume + Runner per-iteration overhead.
///
/// Recorded as `RunMetadata.harnessOverheadNanos`. If this number grows
/// >10 % run-over-run, **BenchKit itself has regressed** — not the library
/// under test. Visible in every run's Summary view.
///
/// **Verification**: declares no `referenceOracle`. The verification step
/// returns `.unverifiable(reason: "self-bench has no semantic output")` and
/// the runner proceeds to sample normally.
public struct NullWorkload: BorrowingWorkload {
    public struct Input {
        public var counter: UInt64
        public init(counter: UInt64 = 0) { self.counter = counter }
    }
    public typealias Output = UInt64

    public init() {}

    public var identifier: WorkloadID {
        // Synthesize a stable WorkloadID. `op` reuses .dot as a sentinel
        // (the closed enum doesn't have a `.null` case and adding one would
        // ripple through ULP tables); `impl == .naive` and a distinguishing
        // param ("benchmark:self") keep it dedup-able from real dot ops.
        let params = try! CanonicalParams(
            ["benchmark": "self"],
            impl: .naive,
            op: .dot,
            shape: .vector(n: 1)
        )
        return WorkloadID(
            op: .dot,
            impl: .naive,
            implClass: .standard,
            dtype: .f32,
            shape: .vector(n: 1),
            params: params
        )
    }

    public var bytesMoved: Int { 0 }
    public var flops: Int { 1 }    // one integer add — keeps GFLOP/s derivation honest (sentinel)
    public var inputDistribution: InputDistribution { .uniform }

    /// No oracle. Self-bench is unverifiable by design.
    public var referenceOracle: ReferenceOracle? { nil }

    public func makeInput(rng: inout SplitMix64) -> Input {
        Input(counter: rng.next())
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        // Minimum work: one integer add. Anything less and the optimizer
        // collapses the entire call chain (BlackHole still saves us, but
        // the floor measurement becomes meaningless).
        return input.counter &+ 1
    }
}
