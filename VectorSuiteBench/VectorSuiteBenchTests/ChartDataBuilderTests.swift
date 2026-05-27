import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// Tests for the pure-function chart data builder. Builder is `nonisolated`
/// so we can invoke it directly without a MainActor context — same pattern
/// as `CaseRowBuilder` and `CaseTableFilterLogic`.
///
/// Coverage focus:
/// - SHOT rows produce no bars (no derived throughput per `CaseResult`).
/// - LOOP rows with neither gflops nor bandwidth produce no bars
///   (defensive — the builder must not emit phantom zero-height bars).
/// - LOOP rows with throughput data carry the right metadata onto the bar.
/// - Category labels match the table's representation
///   (`"<op> <dtype-glyph> <shape-label>"`) so the chart bar and the
///   table row read as the same case.
/// - Approximate / VectorCore flags propagate.
/// - `ThroughputMetric.value(in:)` returns the right side of the bar.
@Suite("ChartDataBuilder")
struct ChartDataBuilderTests {

    // MARK: - Mode filter

    @Test("SHOT-only row produces no bar")
    func shotOnlyDrops() {
        let row = makeRow(op: .dot, impl: .vectorCore, mode: .singleShot,
                          shape: .vector(n: 512), gflops: nil, bandwidth: nil)
        #expect(ChartDataBuilder.bar(from: row) == nil)
    }

    @Test("LOOP row with no throughput data produces no bar")
    func loopWithoutThroughputDrops() {
        // LOOP row but gflops + bandwidth both nil — happens when the
        // oracle failed before the builder could derive throughput.
        let row = makeRow(op: .dot, impl: .vectorCore, mode: .amortized,
                          shape: .vector(n: 512), gflops: nil, bandwidth: nil)
        #expect(ChartDataBuilder.bar(from: row) == nil)
    }

    @Test("LOOP row with only gflops produces a bar")
    func loopWithGflopsOnly() throws {
        let row = makeRow(op: .dot, impl: .vectorCore, mode: .amortized,
                          shape: .vector(n: 512), gflops: 26.04, bandwidth: nil)
        let bar = try #require(ChartDataBuilder.bar(from: row))
        #expect(bar.gflops == 26.04)
        #expect(bar.bandwidthGBPerSec == nil)
    }

    @Test("LOOP row with both metrics produces a bar carrying both")
    func loopWithBoth() throws {
        let row = makeRow(op: .dot, impl: .vectorCore, mode: .amortized,
                          shape: .vector(n: 512), gflops: 26.04, bandwidth: 104.1)
        let bar = try #require(ChartDataBuilder.bar(from: row))
        #expect(bar.gflops == 26.04)
        #expect(bar.bandwidthGBPerSec == 104.1)
    }

    // MARK: - Category label

    @Test("Category label format: op + dtype glyph + shape label")
    func categoryLabelFormat() {
        let id = makeID(op: .dot, impl: .vectorCore, shape: .vector(n: 512), flavor: "optimized")
        #expect(ChartDataBuilder.categoryLabel(for: id) == "dot ƒ32 n=512")
    }

    @Test("Category label uses pairwise shape rendering")
    func categoryLabelPairwise() {
        // pairwise/matrix shapes are rejected when paired with vectorflavor,
        // so don't include the flavor param.
        let id = makeID(op: .pairwiseDistances, impl: .naive,
                        shape: .pairwise(b: 64, n: 768), flavor: nil,
                        implClass: .naive)
        #expect(ChartDataBuilder.categoryLabel(for: id) == "pairwiseDistances ƒ32 b=64·n=768")
    }

    // MARK: - Metadata propagation

    @Test("VectorCore flag propagates to bar")
    func vectorCoreFlag() throws {
        let row = makeRow(op: .dot, impl: .vectorCore, mode: .amortized,
                          shape: .vector(n: 512), gflops: 26.04, bandwidth: 104.1)
        let bar = try #require(ChartDataBuilder.bar(from: row))
        #expect(bar.isVectorCore)
        #expect(!bar.isApproximate)
    }

    @Test("Approximate flag propagates to bar")
    func approximateFlag() throws {
        let row = makeRow(op: .dot, impl: .vectorCore, implClass: .approximate,
                          mode: .amortized, shape: .vector(n: 512),
                          gflops: 60.0, bandwidth: 200.0, flavor: "optimized")
        let bar = try #require(ChartDataBuilder.bar(from: row))
        #expect(bar.isApproximate)
        #expect(bar.isVectorCore)
    }

    @Test("Impl label uses the BenchKit→display adapter")
    func implLabel() throws {
        let row = makeRow(op: .dot, impl: .accelerate, mode: .amortized,
                          shape: .vector(n: 512), gflops: 22.0, bandwidth: 90.0,
                          flavor: nil)
        let bar = try #require(ChartDataBuilder.bar(from: row))
        #expect(bar.implLabel == ImplDisplayKind.accelerate.label)
        #expect(bar.impl == .accelerate)
    }

    // MARK: - Build pipeline

    @Test("build(from:) drops SHOT and emits bars in input order for LOOP")
    func buildOrder() {
        let rows = [
            makeRow(op: .dot, impl: .vectorCore, mode: .singleShot,  // dropped
                    shape: .vector(n: 512), gflops: nil, bandwidth: nil),
            makeRow(op: .dot, impl: .vectorCore, mode: .amortized,
                    shape: .vector(n: 512), gflops: 26.04, bandwidth: 104.1),
            makeRow(op: .dot, impl: .accelerate, mode: .amortized,
                    shape: .vector(n: 512), gflops: 22.0, bandwidth: 90.0,
                    flavor: nil),
            makeRow(op: .l2dist, impl: .naive, implClass: .naive,
                    mode: .amortized, shape: .vector(n: 512),
                    gflops: nil, bandwidth: nil, flavor: nil),  // dropped (no throughput)
        ]
        let bars = ChartDataBuilder.build(from: rows)
        #expect(bars.count == 2)
        #expect(bars[0].impl == .vectorCore)
        #expect(bars[1].impl == .accelerate)
    }

    // MARK: - ThroughputMetric

    @Test("ThroughputMetric.value extracts the right side of the bar")
    func metricValueExtraction() throws {
        let bar = try #require(ChartDataBuilder.bar(from:
            makeRow(op: .dot, impl: .vectorCore, mode: .amortized,
                    shape: .vector(n: 512), gflops: 26.04, bandwidth: 104.1)))
        #expect(ThroughputMetric.gflops.value(in: bar) == 26.04)
        #expect(ThroughputMetric.bandwidth.value(in: bar) == 104.1)
    }

    @Test("ThroughputMetric.unit matches display label")
    func metricUnit() {
        #expect(ThroughputMetric.gflops.unit == "GFLOP/s")
        #expect(ThroughputMetric.bandwidth.unit == "GB/s")
    }

    // MARK: - Fixtures

    private func makeRow(
        op: OpKind,
        impl: ImplKind,
        implClass: ImplClass = .standard,
        mode: Mode,
        shape: Shape,
        gflops: Double?,
        bandwidth: Double?,
        flavor: String? = "optimized"
    ) -> CaseRow {
        let workloadID = makeID(op: op, impl: impl, shape: shape,
                                flavor: flavor, implClass: implClass)
        return CaseRow(
            workloadID: workloadID,
            mode: mode,
            medianNanos: 1_000, p99Nanos: 1_100, p999Nanos: 1_400,
            gflops: gflops,
            bandwidthGBPerSec: bandwidth,
            verification: .verified,
            verificationNote: nil,
            flags: [],
            isVectorCore: (impl == .vectorCore),
            isApproximate: (implClass == .approximate),
            isBimodal: false,
            isTruncated: false
        )
    }

    private func makeID(
        op: OpKind,
        impl: ImplKind,
        shape: Shape,
        flavor: String?,
        implClass: ImplClass = .standard
    ) -> WorkloadID {
        var raw: [String: String] = [:]
        // vectorflavor is required for VectorCore on vector shapes only.
        let isVectorShape: Bool
        switch shape {
        case .vector: isVectorShape = true
        default:      isVectorShape = false
        }
        if let flavor, impl == .vectorCore, isVectorShape {
            raw["vectorflavor"] = flavor
        }
        let params = try! CanonicalParams(raw, impl: impl, op: op, shape: shape)
        return WorkloadID(op: op, impl: impl, implClass: implClass,
                          dtype: .f32, shape: shape, params: params)
    }
}
