import Foundation

/// Outcome of a single workload's verification pass against its
/// `ReferenceOracle`. A `.failed` result causes the case to be aborted before
/// perf sampling — perf numbers never accompany incorrect implementations.
public enum VerificationResult: Codable, Sendable, Equatable {
    /// Verified within the resolved ULP window. The `maxUlpObserved` field is
    /// telemetry: if `.standard` impls routinely consume >90 % of the window,
    /// the window is too tight (or too loose) and worth re-tuning.
    case verified(maxUlpObserved: UInt32)

    /// The workload's `referenceOracle` is `nil` (allowed only for ops where
    /// a numeric reference does not apply — e.g., a topK whose k exceeds the
    /// candidate count). Perf is shown with a yellow info badge.
    case unverifiable(reason: String)

    /// Candidate diverged from the reference beyond the allowed window. Perf
    /// numbers are withheld; the case renders only the failure metadata.
    case failed(maxUlpObserved: UInt32, window: UInt32, sampleIndex: Int)

    public var isVerified: Bool {
        if case .verified = self { return true } else { return false }
    }
}
