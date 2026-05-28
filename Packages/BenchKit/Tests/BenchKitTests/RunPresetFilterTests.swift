import Testing
import Foundation
@testable import BenchKit

/// Unit tests for `RunPreset.filter(_:)`. Uses synthetic `WorkloadID`-shaped
/// fixtures wrapped in a tiny `RunnableWorkload` shell so the test exercises
/// the filter without depending on VSBCore's real workload types (BenchKit
/// must remain independent of any suite package).
@Suite("RunPreset filter")
struct RunPresetFilterTests {

    // MARK: - Smoke

    @Test("Smoke keeps dot/l2dist/cosine × {VC-optimized, Accelerate, naive} × vector(512)")
    func smokeKeepsSpecAllowed() throws {
        let registry: [any RunnableWorkload] = [
            // Keepers — match spec §3 Smoke allow-list exactly.
            try fixture(op: .dot,    impl: .accelerate, shape: .vector(n: 512)),
            try fixture(op: .dot,    impl: .naive,      shape: .vector(n: 512)),
            try fixture(op: .dot,    impl: .vectorCore, shape: .vector(n: 512),
                        params: ["vectorflavor": "optimized"]),
            try fixture(op: .l2dist, impl: .accelerate, shape: .vector(n: 512)),
            try fixture(op: .cosine, impl: .naive,      shape: .vector(n: 512)),
        ]
        let filtered = RunPreset.smoke.filter(registry)
        #expect(filtered.count == 5, Comment(rawValue: "expected all 5 Smoke-allowed cases to pass; got \(filtered.count)"))
    }

    @Test("Smoke rejects simd impl, off-allow-list ops, off-allow-list sizes, non-optimized VC flavors")
    func smokeRejectsOutsiders() throws {
        let registry: [any RunnableWorkload] = [
            try fixture(op: .dot,    impl: .simd,       shape: .vector(n: 512)),                          // simd impl
            try fixture(op: .axpy,   impl: .naive,      shape: .vector(n: 512)),                          // axpy not in Smoke ops
            try fixture(op: .normalize, impl: .naive,   shape: .vector(n: 512)),                          // normalize not in Smoke ops
            try fixture(op: .dot,    impl: .naive,      shape: .vector(n: 256)),                          // size 256 not 512
            try fixture(op: .dot,    impl: .naive,      shape: .vector(n: 1024)),                         // size 1024 not 512
            try fixture(op: .dot,    impl: .vectorCore, shape: .vector(n: 512), params: ["vectorflavor": "generic"]),  // VC generic, not optimized
            try fixture(op: .dot,    impl: .vectorCore, shape: .vector(n: 512), params: ["vectorflavor": "dynamic"]),  // VC dynamic
        ]
        let filtered = RunPreset.smoke.filter(registry)
        #expect(filtered.isEmpty, Comment(rawValue: "Smoke should reject all 7 mismatches; kept: \(filtered.map { $0.identifier.canonicalString })"))
    }

    @Test("Smoke excludes async ops (topK, pairwise, distanceMatrix)")
    func smokeExcludesAsyncOps() throws {
        let registry: [any RunnableWorkload] = [
            try fixture(op: .topK,              impl: .vectorCore, shape: .vector(n: 512), params: ["vectorflavor": "optimized"]),
            try fixture(op: .pairwiseDistances, impl: .vectorCore, shape: .pairwise(b: 64, n: 768)),
            try fixture(op: .distanceMatrix,    impl: .vectorCore, shape: .matrix(b: 256, n: 768)),
        ]
        let filtered = RunPreset.smoke.filter(registry)
        #expect(filtered.isEmpty)
    }

    @Test("Smoke drops dot api=metric while keeping api=raw")
    func smokeDropsDotMetricKeepsRaw() throws {
        let raw = try fixture(op: .dot, impl: .vectorCore, shape: .vector(n: 512),
                              params: ["vectorflavor": "optimized", "api": "raw"])
        let metric = try fixture(op: .dot, impl: .vectorCore, shape: .vector(n: 512),
                                 params: ["vectorflavor": "optimized", "api": "metric"])
        let filtered = RunPreset.smoke.filter([raw, metric])
        #expect(filtered.count == 1)
        #expect(filtered.first?.identifier.params["api"] == "raw")
    }

    // MARK: - Standard

    @Test("Standard drops VectorCore optimized; keeps generic + dynamic + non-VectorCore")
    func standardDropsVectorCoreOptimized() throws {
        let optimized = try fixture(op: .dot, impl: .vectorCore, shape: .vector(n: 1536),
                                    params: ["vectorflavor": "optimized"])
        let generic = try fixture(op: .dot, impl: .vectorCore, shape: .vector(n: 1536),
                                  params: ["vectorflavor": "generic"])
        let dynamic = try fixture(op: .dot, impl: .vectorCore, shape: .vector(n: 1536),
                                  params: ["vectorflavor": "dynamic"])
        let baseline = try fixture(op: .dot, impl: .accelerate, shape: .vector(n: 1536))
        let filtered = RunPreset.standard.filter([optimized, generic, dynamic, baseline])
        #expect(filtered.count == 3, Comment(rawValue: "Standard should keep generic+dynamic+baseline (3) and drop optimized (1); got \(filtered.count)"))
        let kept = Set(filtered.map { $0.identifier.params["vectorflavor"] ?? "<none>" })
        #expect(!kept.contains("optimized"))
    }

    @Test("Standard pins vector dims to {256, 1536}")
    func standardPinsVectorSizes() throws {
        let sizes = [64, 256, 512, 1024, 1536, 4096]
        let registry: [any RunnableWorkload] = try sizes.map { n in
            try fixture(op: .dot, impl: .accelerate, shape: .vector(n: n))
        }
        let filtered = RunPreset.standard.filter(registry)
        let keptSizes = Set(filtered.compactMap { workload -> Int? in
            if case .vector(let n) = workload.identifier.shape { return n }
            return nil
        })
        #expect(keptSizes == [256, 1536], Comment(rawValue: "expected sizes {256, 1536}; got \(keptSizes.sorted())"))
    }

    @Test("Standard pins pairwise/matrix to inner-dim 768 with batch-dim ∈ {64, 256}")
    func standardPinsPairwiseAndMatrixShapes() throws {
        let registry: [any RunnableWorkload] = [
            // Keepers (batch 64 or 256 × inner dim 768).
            try fixture(op: .pairwiseDistances, impl: .naive, shape: .pairwise(b: 64,  n: 768)),
            try fixture(op: .pairwiseDistances, impl: .naive, shape: .pairwise(b: 256, n: 768)),
            try fixture(op: .distanceMatrix,    impl: .naive, shape: .matrix(b: 64,    n: 768)),
            try fixture(op: .distanceMatrix,    impl: .naive, shape: .matrix(b: 256,   n: 768)),
            // Drops — wrong inner dim.
            try fixture(op: .pairwiseDistances, impl: .naive, shape: .pairwise(b: 64,  n: 384)),
            try fixture(op: .distanceMatrix,    impl: .naive, shape: .matrix(b: 256,   n: 1536)),
            // Drops — wrong batch dim (excludes 1024² and 4096² per spec).
            try fixture(op: .distanceMatrix,    impl: .naive, shape: .matrix(b: 1024,  n: 768)),
            try fixture(op: .distanceMatrix,    impl: .naive, shape: .matrix(b: 4096,  n: 768)),
        ]
        let filtered = RunPreset.standard.filter(registry)
        #expect(filtered.count == 4, Comment(rawValue: "expected 4 keepers; got \(filtered.count): \(filtered.map { $0.identifier.canonicalString })"))
    }

    // MARK: - Full + Custom

    @Test("Full is identity over any registry")
    func fullIsIdentity() throws {
        let registry: [any RunnableWorkload] = [
            try fixture(op: .dot,                impl: .vectorCore, shape: .vector(n: 64),    params: ["vectorflavor": "optimized"]),
            try fixture(op: .axpy,               impl: .naive,      shape: .vector(n: 1024)),
            try fixture(op: .distanceMatrix,     impl: .naive,      shape: .matrix(b: 4096,  n: 1536)),
        ]
        let filtered = RunPreset.full.filter(registry)
        #expect(filtered.count == registry.count, Comment(rawValue: "Full should be identity; in=\(registry.count) out=\(filtered.count)"))
    }

    @Test("Custom is identity over any registry (caller has supplied explicit IDs)")
    func customIsIdentity() throws {
        let registry: [any RunnableWorkload] = [
            try fixture(op: .dot,  impl: .simd,  shape: .vector(n: 64)),
            try fixture(op: .axpy, impl: .naive, shape: .vector(n: 999)),  // pathological size — should still pass
        ]
        let custom = RunPreset.custom(
            budget: .standard,
            sampleCount: .standard,
            ids: registry.map(\.identifier)
        )
        let filtered = custom.filter(registry)
        #expect(filtered.count == registry.count)
    }

    // MARK: - Fixtures

    /// Build a minimal `RunnableWorkload` carrying just enough metadata for
    /// the filter to interrogate. The runner-dispatch surface
    /// (`runVia(...)`) is stubbed because tests never call it — the filter
    /// reads `identifier` only.
    private func fixture(
        op: OpKind,
        impl: ImplKind,
        shape: Shape,
        implClass: ImplClass = .standard,
        params extra: [String: String] = [:]
    ) throws -> any RunnableWorkload {
        var p = extra
        // VectorCore vector ops require `vectorflavor` per the CanonicalParams
        // contract. Tests that don't pass one get `generic` as a safe default.
        if impl == .vectorCore, case .vector = shape, p["vectorflavor"] == nil {
            p["vectorflavor"] = "generic"
        }
        let canonical = try CanonicalParams(p, impl: impl, op: op, shape: shape)
        let id = WorkloadID(
            op: op, impl: impl, implClass: implClass,
            dtype: .f32, shape: shape, params: canonical
        )
        return FixtureWorkload(identifier: id)
    }

    /// Inert workload — never run; only its `identifier` matters for filter
    /// tests. The protocol's other requirements get safe defaults.
    private struct FixtureWorkload: RunnableWorkload {
        let identifier: WorkloadID
        var bytesMoved: Int { 0 }
        var flops: Int { 0 }
        var inputDistribution: InputDistribution { .uniform }
        func runVia(
            runner: Runner,
            asyncRunner: AsyncRunner,
            cancellation: CancellationToken?
        ) async -> CaseResult {
            fatalError("FixtureWorkload is filter-only; runVia must not be called from filter tests")
        }
    }
}
