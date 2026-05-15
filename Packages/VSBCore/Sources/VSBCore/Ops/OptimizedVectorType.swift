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
