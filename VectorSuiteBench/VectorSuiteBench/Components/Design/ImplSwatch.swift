import SwiftUI

/// 10×10 colored square that identifies an implementation. Used in the
/// data table's Implementation column, in chart legends, and beside any
/// label that needs to telegraph "this is VectorCore" / "this is naïve"
/// at a glance.
///
/// `ImplDisplayKind` is a local enum that **mirrors `BenchKit.ImplKind`**
/// — kept local so this file compiles before the BenchKit SwiftPM
/// dependency is added in Item 1b. The adapter is documented at the
/// bottom of this file; write it (with its test) at the seam in Item 3b.
struct ImplSwatch: View {
    let impl: ImplDisplayKind
    let isApproximate: Bool

    init(_ impl: ImplDisplayKind, isApproximate: Bool = false) {
        self.impl = impl
        self.isApproximate = isApproximate
    }

    var body: some View {
        RoundedRectangle(cornerRadius: VSB.Radius.swatch, style: .continuous)
            .fill(impl.color)
            .frame(width: 10, height: 10)
            .modifier(HatchedFillModifier(active: isApproximate))
            // The `clipShape` is NOT redundant — `HatchedFillModifier`
            // overlays a Canvas that draws across the full 10×10 bounding
            // box; without this clip, the diagonal lines stick out past
            // the rounded corners on approximate swatches.
            .clipShape(RoundedRectangle(cornerRadius: VSB.Radius.swatch, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VSB.Radius.swatch, style: .continuous)
                    .strokeBorder(
                        isApproximate ? Color.white.opacity(0.35) : Color.clear,
                        style: isApproximate
                            ? StrokeStyle(lineWidth: 1, dash: [1.5, 1])
                            : StrokeStyle(lineWidth: 0)
                    )
            )
    }
}

/// Local mirror of `BenchKit.ImplKind`. Includes `vDSP` and `metal` even
/// though they aren't current `ImplKind` cases — the design tokens for
/// them exist; the mapping will be filled in when Phase 2.2 / 2.3 adds
/// real impls.
/// **`nonisolated`** — same rationale as `VerificationDisplayState` (sibling
/// in this folder). The enum is a pure value; the only MainActor-bound
/// member is `color`, which reads `VSB.Impl.*` tokens — that one keeps
/// `@MainActor` explicitly. `label` is a static string switch and is
/// callable from nonisolated builders (`ChartDataBuilder`, `CaseRowBuilder`).
nonisolated enum ImplDisplayKind: String, CaseIterable, Hashable, Sendable {
    case vectorCore
    case accelerate
    case vDSP
    case metal
    case naive
    case simd

    /// MainActor-isolated because it reads `VSB.Impl.*` tokens. Consumers
    /// are SwiftUI body blocks (also MainActor) so the isolation is free.
    @MainActor var color: Color {
        switch self {
        case .vectorCore: return VSB.Impl.vectorCore
        case .accelerate: return VSB.Impl.accelerate
        case .vDSP:       return VSB.Impl.vDSP
        case .metal:      return VSB.Impl.metal
        case .naive:      return VSB.Impl.naive
        case .simd:       return VSB.Impl.simd
        }
    }

    /// Display label for table cells. Matches the on-disk wire-names
    /// where they exist; otherwise the human-readable form.
    var label: String {
        switch self {
        case .vectorCore: return "VectorCore"
        case .accelerate: return "Accelerate"
        case .vDSP:       return "vDSP"
        case .metal:      return "Metal"
        case .naive:      return "naïve"
        case .simd:       return "simd"
        }
    }
}

// MARK: - BenchKit adapter contract (write in Item 3b)
//
// Once BenchKit is added as a SwiftPM dependency (Item 1b), write this
// adapter at the data seam (Item 3b — wherever the table's data builder
// maps `WorkloadID` into row models):
//
//     import BenchKit
//
//     extension ImplKind {
//         var display: ImplDisplayKind {
//             switch self {
//             case .vectorCore: return .vectorCore
//             case .accelerate: return .accelerate
//             case .naive:      return .naive
//             case .simd:       return .simd
//             }
//         }
//     }
//
// **Mapping decisions (pinned — do not alter without raising):**
// - `accelerate` (BenchKit's `cblas_sdot` path, which lives in
//   Accelerate.framework's BLAS sub-API) maps to `.accelerate`, NOT
//   `.vDSP`. vDSP is a sibling sub-API; BenchKit uses BLAS, so the
//   "Accelerate" graphite is the right baseline color.
// - `.vDSP` and `.metal` in `ImplDisplayKind` are reserved for Phase 2.2 /
//   2.3+ when corresponding `ImplKind` cases land. They are intentionally
//   present in the display layer so the design tokens stay stable across
//   phases.
//
// **Required test** (write alongside the adapter; this prevents drift
// when BenchKit adds a new `ImplKind` case without updating the design
// layer):
//
//     import Testing
//     @testable import VectorSuiteBench
//     import BenchKit
//
//     @Test("Every BenchKit ImplKind has a display mapping")
//     func adapterIsTotal() {
//         for kind in ImplKind.allCases {
//             _ = kind.display   // Compiler enforces exhaustiveness on the
//                                // switch above; this loop ensures any new
//                                // case shows up as a runtime miss too.
//         }
//     }
//
// The `for kind in ImplKind.allCases { _ = kind.display }` form is the
// drift guard. Adding a new `ImplKind` without updating the switch
// breaks the build (exhaustive switch), not the runtime — that's the
// design contract.

#Preview("ImplSwatch — all kinds, exact + approximate") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(ImplDisplayKind.allCases, id: \.self) { impl in
            HStack(spacing: 10) {
                ImplSwatch(impl, isApproximate: false)
                ImplSwatch(impl, isApproximate: true)
                Text(impl.label)
                    .vsbBody()
            }
        }
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
