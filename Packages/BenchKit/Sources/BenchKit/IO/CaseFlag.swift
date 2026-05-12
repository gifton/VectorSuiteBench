import Foundation

/// Flags attached to a `CaseResult` that callers (charts, diff view) should
/// surface to the user. Wire-names are frozen; renaming a case is a major
/// schema change.
public enum CaseFlag: String, Codable, Sendable, CaseIterable, Hashable {
    /// Sample collection was cut short by a wall-clock budget overrun.
    case truncated
    /// Sample histogram has two distinct modes (likely P/E-core migration).
    case bimodal
    /// Impl class is `.approximate` — visually flagged on every chart.
    case approximate
    /// Thermal state escalated during sampling.
    case thermalEscalation
    /// Memory growth observed pre/post sampling exceeds heuristic threshold.
    case memoryGrowth
}
