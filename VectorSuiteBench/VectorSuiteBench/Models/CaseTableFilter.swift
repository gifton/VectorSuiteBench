import Foundation
import BenchKit

/// Filter state for the data table. Held as `@MainActor @Observable` so the
/// table and (in Item 3c) the throughput chart can both observe the same
/// instance — the design seam keeps the two surfaces in lockstep so the
/// chart and the table always show the same cohort.
///
/// **Empty axis = "no filter on this axis"**, applied per-axis. The
/// alternative ("empty = no results") would make the freshly-constructed
/// filter (every axis empty) display nothing, which is the wrong default
/// state for the data-first surface. With "empty = no filter", a freshly
/// constructed filter is an identity transform — exactly what callers
/// want before any chip is toggled.
///
/// The filter logic itself is split into `nonisolated enum
/// CaseTableFilterLogic` so test suites can apply filters as pure
/// functions without spinning up a MainActor context.
@MainActor
@Observable
final class CaseTableFilter {

    /// Selected ops. Empty = all ops pass.
    var ops: Set<OpKind> = []

    /// Selected impls. Empty = all impls pass.
    var impls: Set<ImplKind> = []

    /// Selected verification display states. Empty = all states pass.
    /// (`.inflight` is included so the in-flight row treatment from
    /// Item 4c is filterable when it lands.)
    var verifications: Set<VerificationDisplayState> = []

    /// Selected modes. Empty = both modes pass.
    var modes: Set<Mode> = []

    init(
        ops: Set<OpKind> = [],
        impls: Set<ImplKind> = [],
        verifications: Set<VerificationDisplayState> = [],
        modes: Set<Mode> = []
    ) {
        self.ops = ops
        self.impls = impls
        self.verifications = verifications
        self.modes = modes
    }

    /// `true` when every axis is empty — i.e., the filter is an identity
    /// transform. Useful for empty-state messaging in the table footer.
    var isUnfiltered: Bool {
        ops.isEmpty && impls.isEmpty && verifications.isEmpty && modes.isEmpty
    }

    /// Apply the filter to a row list. Thin delegate to the pure-function
    /// `CaseTableFilterLogic.apply(...)` so tests can target the logic
    /// directly without instantiating the `@Observable`.
    func apply(to rows: [CaseRow]) -> [CaseRow] {
        CaseTableFilterLogic.apply(
            rows,
            ops: ops,
            impls: impls,
            verifications: verifications,
            modes: modes
        )
    }

    /// Reset every axis to "no filter" in one call. Wired to the table's
    /// future "Clear filters" affordance.
    func clearAll() {
        ops.removeAll()
        impls.removeAll()
        verifications.removeAll()
        modes.removeAll()
    }
}

/// Pure-function filter logic. `nonisolated` so test suites — which run
/// outside MainActor in the app target's default-isolation regime — can
/// call `apply(...)` directly.
nonisolated enum CaseTableFilterLogic {

    /// Apply the filter axes as an **AND** across axes and an **OR** within
    /// each axis: a row passes iff it matches at least one of every
    /// non-empty axis's selections. An empty axis is an unconditional pass
    /// per the "empty = no filter" convention.
    ///
    /// Preserves input order — useful because the caller hands us rows
    /// already ordered by `CaseRowBuilder.build(from:)`, and the SwiftUI
    /// Table can then layer a column-header sort on top.
    static func apply(
        _ rows: [CaseRow],
        ops: Set<OpKind>,
        impls: Set<ImplKind>,
        verifications: Set<VerificationDisplayState>,
        modes: Set<Mode>
    ) -> [CaseRow] {
        rows.filter { row in
            (ops.isEmpty           || ops.contains(row.workloadID.op))
            && (impls.isEmpty      || impls.contains(row.workloadID.impl))
            && (verifications.isEmpty || verifications.contains(row.verification))
            && (modes.isEmpty      || modes.contains(row.mode))
        }
    }
}
