import SwiftUI

/// 10×10 colored square that identifies an implementation. Used in the
/// data table's Implementation column, in chart legends, and beside any
/// label that needs to telegraph "this is VectorCore" / "this is naïve"
/// at a glance.
///
/// `ImplDisplayKind` is a local enum that **mirrors `BenchKit.ImplKind`**
/// — kept local so this file compiles before the BenchKit SwiftPM
/// dependency is added in Item 1b. Once the dep lands, add an adapter:
/// ```
/// extension ImplKind { var display: ImplDisplayKind { ... } }
/// ```
/// at the seam (Item 3b) — do not re-export this enum from BenchKit.
struct ImplSwatch: View {
    let impl: ImplDisplayKind
    let isApproximate: Bool

    init(_ impl: ImplDisplayKind, isApproximate: Bool = false) {
        self.impl = impl
        self.isApproximate = isApproximate
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(impl.color)
            .frame(width: 10, height: 10)
            .modifier(HatchedFillModifier(active: isApproximate))
            .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
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
enum ImplDisplayKind: String, CaseIterable, Hashable, Sendable {
    case vectorCore
    case accelerate
    case vDSP
    case metal
    case naive
    case simd

    var color: Color {
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
