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

    @Test("NaN and Inf yield 'not good' under either polarity")
    func nonFiniteInputs() {
        // Comparison against NaN is always false in Swift, so isGood
        // returns false. Inf has well-defined comparison so it CAN be
        // "good" (e.g., +Inf > 0 → good under higherIsBetter), but in
        // practice the diff pipeline should never feed Inf in — pin
        // both cases here so the contract is explicit.
        #expect(DeltaPolarity.lowerIsBetter.isGood(delta: .nan)  == false)
        #expect(DeltaPolarity.higherIsBetter.isGood(delta: .nan) == false)

        // +Inf is technically > 0; this test pins that we accept it as
        // "good" under higherIsBetter (the alternative would be to guard
        // explicitly, which adds runtime cost for an input that should
        // never appear).
        #expect(DeltaPolarity.higherIsBetter.isGood(delta: .infinity)  == true)
        #expect(DeltaPolarity.lowerIsBetter.isGood(delta:  -.infinity) == true)
    }
}

/// `NumberCell.sanitize(_:)` is the pure-function piece that turns a
/// non-finite `Double` into `.missing` so the cell never prints `"nan"`
/// or `"inf"` in a number-styled font. Visual rendering is reviewed via
/// the SwiftUI Preview in `NumberCell.swift`.
@Suite("NumberCell.sanitize")
struct NumberCellSanitizeTests {

    @Test("NaN collapses to .missing")
    func nanCollapses() {
        #expect(NumberCell.sanitize(.value(.nan)) == .missing)
    }

    @Test("+Inf and -Inf collapse to .missing")
    func infinityCollapses() {
        #expect(NumberCell.sanitize(.value(.infinity))  == .missing)
        #expect(NumberCell.sanitize(.value(-.infinity)) == .missing)
    }

    @Test("Finite values pass through unchanged")
    func finiteValuesPassThrough() {
        #expect(NumberCell.sanitize(.value(0))      == .value(0))
        #expect(NumberCell.sanitize(.value(42.5))   == .value(42.5))
        #expect(NumberCell.sanitize(.value(-7))     == .value(-7))
        // Subnormals are finite — they pass through. (FPCR FZ flushes
        // these to zero in measurement, but the *display* layer doesn't
        // need to know about FPCR.)
        #expect(NumberCell.sanitize(.value(.leastNormalMagnitude / 2))
                == .value(.leastNormalMagnitude / 2))
    }

    @Test(".missing and .error are idempotent")
    func nonValueStatesAreIdempotent() {
        #expect(NumberCell.sanitize(.missing) == .missing)
        #expect(NumberCell.sanitize(.error)   == .error)
    }
}
