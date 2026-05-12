import Foundation

/// Shape-dependent ULP tolerance for the (op, implClass) pair. The window
/// must grow with summation depth: tree/pairwise summation has O(log₂N · ε)
/// error, naïve summation has O(N · ε), so a static window false-fails on
/// large N even when the implementation is textbook-correct.
///
/// See §5 of the design spec for the derivation and the rationale for
/// dropping `.exact` (every Float32 candidate has inherent O(N·ε_f32) drift
/// from a Float64 Kahan-Neumaier oracle).
public func ulpTolerance(op: OpKind, implClass: ImplClass, shape: Shape) -> UInt32 {
    let n = shape.summationDepth
    let logN = UInt32(max(1, Int(Foundation.log2(Double(n)).rounded(.up))))

    switch (op, implClass) {
    case (.dot, .standard):                  return 4   + 2  * logN
    case (.dot, .approximate):               return 64  + 16 * logN
    case (.l2dist, .standard):               return 8   + 4  * logN
    case (.l2dist, .approximate):            return 128 + 32 * logN
    case (.cosine, .standard):               return 16  + 8  * logN
    case (.cosine, .approximate):            return 256 + 64 * logN
    case (.normalize, .standard):            return 8   + 4  * logN
    case (.normalize, .approximate):         return 1024 + 64 * logN  // rsqrt approx is harsh
    case (.axpy, .standard):                 return 4   + 2  * logN
    case (.axpy, .approximate):              return 64  + 16 * logN
    case (.pairwiseDistances, .standard):    return 8   + 4  * logN
    case (.pairwiseDistances, .approximate): return 128 + 32 * logN
    case (.distanceMatrix, .standard):       return 8   + 4  * logN
    case (.distanceMatrix, .approximate):    return 128 + 32 * logN
    case (.topK, _):                         return 0  // set-based verification; no ULP window
    case (.null, _):                         return 0  // NullWorkload self-bench has no semantic output
    }
}
