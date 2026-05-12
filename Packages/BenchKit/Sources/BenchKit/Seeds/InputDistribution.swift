import Foundation

/// Declared input distribution for a workload. Phase 1 standard cases use
/// `.uniform` exclusively, but the seam is real so later phases (especially
/// VectorIndex / EmbedKit, where embedding distributions matter) can land
/// without retrofitting.
public enum InputDistribution: Hashable, Codable, Sendable {
    /// Uniform in [0, 1) — the default for dense SIMD micro-benchmarks.
    case uniform

    /// Standard normal N(0, 1).
    case normal

    /// Embedding-like: zero-mean Gaussian with per-component σ. Real
    /// embeddings have wildly different statistical properties from uniform
    /// random; relevant for VectorIndex search (Phase 3).
    case embeddingLike(sigma: Double)

    /// Adversarial input class for robustness checks.
    case adversarial(AdversarialClass)

    public enum AdversarialClass: String, Hashable, Codable, Sendable {
        case denormals    // values near Float.leastNormalMagnitude
        case zeros        // all-zero input (catches branch-on-zero fastpaths)
        case nans         // NaN injection (verifies NaN propagation)
        case infinities
    }
}
