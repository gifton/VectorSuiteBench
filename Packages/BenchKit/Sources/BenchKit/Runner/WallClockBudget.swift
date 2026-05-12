import Foundation

/// Wall-clock budgeting for a run. Honored by `Runner`; on overrun the
/// runner truncates the current case (`.truncated` flag) or skips remaining
/// cases (`.skipRemaining`), per the abort policy.
public struct WallClockBudget: Codable, Sendable, Equatable {
    public let total: Duration
    public let perCase: Duration
    public let abortPolicy: AbortPolicy

    public init(total: Duration, perCase: Duration, abortPolicy: AbortPolicy) {
        self.total = total
        self.perCase = perCase
        self.abortPolicy = abortPolicy
    }

    public enum AbortPolicy: String, Codable, Sendable {
        /// On overrun, finish the current case's sampling (or stop early) and
        /// skip the remaining queue. Preserves honest sample counts on
        /// completed cases.
        case skipRemaining

        /// On overrun, truncate the current case's samples to whatever has
        /// been collected so far. The case gets a `.truncated` flag.
        case truncateSamples
    }

    public static let smoke = WallClockBudget(
        total: .seconds(30),
        perCase: .seconds(5),
        abortPolicy: .skipRemaining
    )

    public static let standard = WallClockBudget(
        total: .seconds(360),         // 6 min ceiling for the ~5 min preset
        perCase: .seconds(30),
        abortPolicy: .skipRemaining
    )

    public static let full = WallClockBudget(
        total: .seconds(3600),        // 60 min ceiling for the ~45 min preset
        perCase: .seconds(120),
        abortPolicy: .truncateSamples
    )
}
