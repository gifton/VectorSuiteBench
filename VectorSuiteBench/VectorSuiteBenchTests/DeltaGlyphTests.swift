import Testing
@testable import VectorSuiteBench

/// `DeltaGlyph` is a SwiftUI view, which makes its color decisions hard to
/// inspect without a render path. The polarity decision is split out as
/// `DeltaPolarity.isGood(delta:)` so the load-bearing logic — "is this
/// delta an improvement?" — can be tested directly. The visual
/// (`▼` / `▲` placement, color application) is reviewed via the SwiftUI
/// Preview in `DeltaGlyph.swift`.
@Suite("DeltaPolarity.isGood")
struct DeltaGlyphTests {

    @Test("Latency (lower is better): negative delta improves, positive regresses")
    func lowerIsBetterSignFlip() {
        #expect(DeltaPolarity.lowerIsBetter.isGood(delta: -12.0) == true,
                "−12% latency is a 12% speedup — should read good")
        #expect(DeltaPolarity.lowerIsBetter.isGood(delta:  +8.0) == false,
                "+8% latency is a regression — should read bad")
    }

    @Test("Throughput (higher is better): positive delta improves, negative regresses")
    func higherIsBetterSignFlip() {
        #expect(DeltaPolarity.higherIsBetter.isGood(delta: +12.0) == true,
                "+12% throughput is an improvement")
        #expect(DeltaPolarity.higherIsBetter.isGood(delta:  -8.0) == false,
                "−8% throughput is a regression")
    }

    @Test("Zero delta is never 'good' under either polarity")
    func zeroIsNeverGood() {
        // The visual renders `·` at zero (no directional glyph) and uses
        // text.lo color — neither pass nor fail. The logical contract is
        // that `isGood(0) == false` so colored emphasis is reserved for
        // real movements.
        #expect(DeltaPolarity.lowerIsBetter.isGood(delta: 0)  == false)
        #expect(DeltaPolarity.higherIsBetter.isGood(delta: 0) == false)
    }

    @Test("Same numeric delta flips meaning under opposite polarity")
    func polarityFlipsMeaning() {
        // The locked decision §1.5/6 in the plan: the same `-12 %` reads
        // green for latency and red for throughput. This test pins that
        // contract — change it and the diff table's accessibility
        // story breaks.
        let delta = -12.0
        #expect(DeltaPolarity.lowerIsBetter.isGood(delta: delta)  == true)
        #expect(DeltaPolarity.higherIsBetter.isGood(delta: delta) == false)
    }
}
