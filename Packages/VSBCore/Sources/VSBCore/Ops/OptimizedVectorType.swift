import Foundation
import VectorCore

/// Bridging protocol that VectorCore's `Vector{N}Optimized` types retro-
/// conform to (via the extensions below). Lets a single
/// `VectorCoreOptimizedDotWorkload<V>` cover every dim VectorCore ships
/// without one workload type per dim.
///
/// VectorCore declares fixed-dim Optimized types at **384, 512, 768, 1536**
/// (per `Sources/VectorCore/Vector{N}Optimized.swift`). The retro-conformance
/// below covers all four so Phase 2 can register 384 and 768 cases by
/// changing only the registry, not introducing new workload types.
///
/// **Why retro-conform here rather than upstream:** VectorCore does not
/// expose a `staticDim`-bearing protocol over its Optimized types — they
/// are independent struct types with identical-shape `dotProduct(_:)`
/// methods. We bridge in VSBCore to keep VectorCore free of harness-driven
/// protocol additions.
public protocol OptimizedVectorType: Sendable {
    /// Compile-time dimension of this Optimized type.
    static var dim: Int { get }

    /// Construct from a Float buffer of exactly `dim` elements. Throws
    /// `VectorError.dimensionMismatch` otherwise.
    init(_ array: [Float]) throws

    /// Dot product. Returns `+a·b` (raw kernel sign convention).
    func dotProduct(_ other: Self) -> Float
}

extension Vector384Optimized: OptimizedVectorType {
    public static var dim: Int { 384 }
}
extension Vector512Optimized: OptimizedVectorType {
    public static var dim: Int { 512 }
}
extension Vector768Optimized: OptimizedVectorType {
    public static var dim: Int { 768 }
}
extension Vector1536Optimized: OptimizedVectorType {
    public static var dim: Int { 1536 }
}

// MARK: - L2 squared-distance refinement

/// Per-op refinement of `OptimizedVectorType` that adds the squared
/// Euclidean distance method. Phase 2.2 Item 1a — only the Optimized
/// vector types expose a typed `euclideanDistanceSquared(to:)` API
/// (Vector<D> and DynamicVector do not), so the L2DistanceFamily ships
/// the Optimized flavor only via this refinement; the Generic and
/// Dynamic flavors are deliberately omitted.
///
/// Future per-op refinements (cosine, normalize, axpy, ...) follow the
/// same pattern: a marker-protocol refinement plus retroconformances
/// over whatever subset of VectorCore's Optimized types exposes the
/// underlying kernel.
public protocol OptimizedL2VectorType: OptimizedVectorType {
    /// Squared Euclidean distance to another vector of the same type.
    /// Wraps VectorCore's `euclideanDistanceSquared(to:)`.
    func euclideanDistanceSquared(to other: Self) -> Float
}

extension Vector384Optimized: OptimizedL2VectorType {}
extension Vector512Optimized: OptimizedL2VectorType {}
extension Vector768Optimized: OptimizedL2VectorType {}
extension Vector1536Optimized: OptimizedL2VectorType {}
