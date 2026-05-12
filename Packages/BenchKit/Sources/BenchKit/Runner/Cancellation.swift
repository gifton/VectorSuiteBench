import Foundation
import os

/// A cooperative cancellation token honored by `Runner` between cases and
/// (where cheap) between samples. A cancelled run produces a **valid run on
/// disk** with completed cases plus a `.truncated` flag on the in-flight case
/// — never a half-written record.
public final class CancellationToken: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock<Bool>(initialState: false)

    public init() {}

    public func cancel() {
        cancelled.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        cancelled.withLock { $0 }
    }
}
