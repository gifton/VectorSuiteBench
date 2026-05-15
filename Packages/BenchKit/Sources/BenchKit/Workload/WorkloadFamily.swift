import Foundation

/// A family of related workloads — typically all variants of one operation
/// across impls, sizes, and flavors (e.g., "all Dot variants"). Suite-level
/// registries organize their workloads via families so the top-level
/// `workloads` array is the `flatMap` of per-family contributions.
///
/// **Why this matters as the suite grows:** without families, every new
/// op gets appended into a single `makeWorkloads()` function that drifts
/// toward hundreds of lines. With families, each op family owns its own
/// enumeration logic; the registry is a tiny aggregator.
///
/// Implementations should be stateless and cheap to invoke — registries are
/// expected to cache the resulting array.
public protocol WorkloadFamily: Sendable {
    /// Display name (used in UI / CSV exports). Stable identifier; treat
    /// as a wire-name once published.
    var name: String { get }

    /// All workloads contributed by this family, type-erased to the
    /// `RunnableWorkload` existential so RunController can dispatch each
    /// through the right runner without knowing its concrete shape.
    /// `RunnableWorkload` itself refines `WorkloadMetadata`, so callers that
    /// only need identifier/bytes/flops/inputDistribution can still treat
    /// the elements as metadata.
    var workloads: [any RunnableWorkload] { get }
}
