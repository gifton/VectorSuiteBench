import Foundation
import BenchKit
import VectorCore

/// Shared input + oracle helpers for in-place L2 normalize workloads.
///
/// **Why a separately-named Input struct.** The OOP family already has
/// `RawFloatNormalizeInput` and IP could reuse it verbatim (same shape:
/// one `var a: [Float]`). A distinct type makes the intent visible at
/// the workload site — "this is the IP variant, not OOP".
///
/// **Verification strategy.** Returning the post-mutation buffer as
/// `Output = [Float]` would either (a) cost a fresh allocation per
/// iteration for VC Generic (`Array(input.v)` → 2 KB at N=512), or
/// (b) require maintaining a `[Float]` mirror inside the Input struct
/// that's kept in sync at every invoke — extra N writes per call,
/// doubling the work we're trying to measure.
///
/// The IP-family workloads instead return the post-normalize **first
/// element** as `Output = Float`. Returning a single Float is free,
/// symmetric across all three impls, and catches the bug class that
/// matters: any "I computed the wrong magnitude" or "I forgot to
/// divide" defect manifests at element[0] just like at every other
/// index, because L2 normalize scales every element by the same
/// `1/mag`. Tail-of-buffer-only bugs aren't caught — the spec accepts
/// this for IP per `NormalizeInPlaceSmokeWorkload`'s precedent (which
/// verifies the magnitude scalar only, an even weaker check). The OOP
/// family (Item 1c) still does per-element verification; that's where
/// rigorous bit-for-bit checking lives.
public struct RawFloatNormalizeIPInput {
    public var a: [Float]

    public init(n: Int, rng: inout SplitMix64) {
        var aBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            // Same `+ 0.01` lower-bound as BenchKit's
            // NormalizeInPlaceSmokeWorkload — keeps the magnitude
            // strictly > 0 so the 1/mag path is well-defined for
            // verification.
            aBuf[i] = rng.nextFloat() + 0.01
        }
        self.a = aBuf
    }
}

// MARK: - Scalar oracle helper

/// Per-element-0 verification oracle for in-place normalize.
///
/// `compute(input)`: Float64 Kahan-Neumaier normalize over the
/// pre-state buffer, returns `.scalar(refDoubles[0])`.
///
/// `compare(candidate, reference, window)`: ULP-distance between
/// the candidate Float (post-normalize input[0]) and the reference's
/// expected element 0 (cast back to Float). Uses the standard
/// `floatULPDistance` helper.
///
/// **`extractInput`** isolates this helper from the workload's
/// Input shape — `RawFloatNormalizeIPInput` extracts `.a`,
/// VectorCoreGenericNormalizeInPlaceWorkload extracts `.raw` from
/// its (Vector<D>, [Float]) wrapper, etc. Same indirection pattern
/// as `makeNormalizeOracle` in `Ops/NormalizeShared.swift`.
public func makeNormalizeInPlaceFirstElementOracle<Input>(
    extractInput: @Sendable @escaping (Input) -> [Float]
) -> ReferenceOracle<Input, Float> {
    ReferenceOracle(
        compute: { input in
            let raw = extractInput(input)
            let refDoubles = kahanFloat64Normalize(raw)
            // Empty buffers can't be normalized; defensive — registry
            // never registers an n=0 case, but return a stable .scalar
            // so verifyMutating doesn't trap.
            guard let head = refDoubles.first else { return .scalar(0) }
            return .scalar(head)
        },
        compare: { candidate, reference, window in
            guard case .scalar(let refD) = reference else {
                return .failed(maxUlpObserved: .max, window: window, sampleIndex: 0)
            }
            let refF = Float(refD)
            let diff = floatULPDistance(candidate, refF)
            if diff <= window {
                return .verified(maxUlpObserved: diff)
            } else {
                return .failed(maxUlpObserved: diff, window: window, sampleIndex: 0)
            }
        }
    )
}

// MARK: - Family

/// In-place L2 normalize — `aᵢ ← aᵢ / ‖a‖₂`. Phase 2.2 Item 3a; first
/// `MutatingWorkload` family in the VSBCore registry.
///
/// **Flavor coverage (locked via Item 3a user Q&A — honest-to-API):**
/// Only `Vector<D>` (Generic) ships a true mutating normalize
/// (`normalizeFast()`). `Vector{384,512,768,1536}Optimized` and
/// `DynamicVector` expose only Result-returning OOP `normalized()`;
/// wrapping them as `v = try! v.normalized().get()` would measure
/// an out-of-place + assign, not a true in-place mutation —
/// dishonest. Those flavors are SKIPPED here; the OOP family
/// (Item 1c) covers them with the matching semantics.
///
/// **Apple `simd_normalize` skipped** per spec §9: `simd_normalize`
/// returns a fresh value (OOP). The OOP family already covers it;
/// re-using it as IP would be the same dishonest wrap as above.
///
/// **WorkloadID disambiguation.** OOP and IP both use
/// `OpKind.normalize`; the IP cases carry `params["inplace"] = "true"`
/// so canonical strings (and dedup keys) stay distinct from the OOP
/// family. The OOP cases carry no such key (absence reads as the
/// out-of-place default — consistent with existing Item 1c cases
/// already in the registry).
///
/// **Case count: 2 baselines × 5 sizes + 1 VC × 4 sizes = 14.**
/// Naïve + Accelerate-vDSP in-place at every baseline size, VC
/// Generic at {64, 256, 512, 1536}. VC Generic skips N=4096 because
/// VectorCore declares no `Dim4096` static type — same exclusion the
/// OOP family applies to its Generic flavor.
public struct NormalizeInPlaceFamily: WorkloadFamily {
    public init() {}
    public var name: String { "normalizeInPlace" }

    public var workloads: [any RunnableWorkload] {
        var all: [any RunnableWorkload] = []

        // 1. Baseline (non-VectorCore) impls × 5 sizes = 10
        for n in VSBCoreRegistry.baselineDotSizes {
            all.append(NaiveNormalizeInPlaceWorkload(n: n))
            all.append(AccelerateNormalizeInPlaceWorkload(n: n))
        }

        // 2. VectorCore-generic at every static Dim VectorCore declares
        //    of our 5-size set: 64, 256, 512, 1536 (no Dim4096) = 4
        all.append(VectorCoreGenericNormalizeInPlaceWorkload<Dim64>())
        all.append(VectorCoreGenericNormalizeInPlaceWorkload<Dim256>())
        all.append(VectorCoreGenericNormalizeInPlaceWorkload<Dim512>())
        all.append(VectorCoreGenericNormalizeInPlaceWorkload<Dim1536>())

        return all
        // Total: 10 + 4 = 14 NormalizeInPlace cases.
    }
}
