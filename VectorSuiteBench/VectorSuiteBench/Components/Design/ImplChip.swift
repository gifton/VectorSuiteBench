import SwiftUI

/// 2-column grid chip for the Implementations section of the New Run
/// modal (design doc §05). Wider than `CheckboxChip` because impls
/// carry richer metadata: a 10×10 color swatch + the library name + an
/// optional `APPROX` pill on the right for fast-math impls.
///
/// **Selected-state treatment matches `CheckboxChip`** (6 % cyan fill,
/// 0.5 px cyan border) so the two grids feel like one surface even
/// though they have different cell shapes. Unselected: 2 % white +
/// hair-line border.
///
/// **Approximate impls** (`isApproximate: true`) render the swatch
/// hatched via `HatchedFillModifier` — the same pattern the data table
/// uses, so the visual language is consistent between configuration
/// and result-surface.
struct ImplChip: View {

    let implDisplay: ImplDisplayKind
    let isApproximate: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                checkbox
                ImplSwatch(implDisplay, isApproximate: isApproximate)
                Text(implDisplay.label)
                    .vsbBody(color: isSelected ? VSB.Text.hi : VSB.Text.md)
                Spacer(minLength: 0)
                if isApproximate {
                    Pill("APPROX", style: .approx, icon: "~")
                }
            }
            // Padding matches `CheckboxChip` (10/8). Earlier 10/10
            // padding was unforced inconsistency — the impl chip has a
            // single-line content shape (checkbox + swatch + label +
            // optional pill), so the same vertical breathing room as
            // the two-line CheckboxChip reads cleanly here too.
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectableChip(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Same checkmark glyph as `CheckboxChip` so the two chip families
    /// share the click affordance. Fill + border treatment lives in the
    /// shared `.selectableChip(...)` modifier.
    private var checkbox: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .imageScale(.medium)
            .foregroundStyle(isSelected ? VSB.Impl.vectorCore : VSB.Text.lo)
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        if isApproximate {
            return "\(implDisplay.label), approximate-math variant"
        }
        return implDisplay.label
    }
}

#Preview("ImplChip — every variant") {
    VStack(spacing: 8) {
        HStack(spacing: 8) {
            ImplChip(implDisplay: .vectorCore, isApproximate: false,
                     isSelected: true, action: {})
            ImplChip(implDisplay: .accelerate, isApproximate: false,
                     isSelected: false, action: {})
        }
        HStack(spacing: 8) {
            ImplChip(implDisplay: .vectorCore, isApproximate: true,
                     isSelected: true, action: {})
            ImplChip(implDisplay: .naive, isApproximate: false,
                     isSelected: false, action: {})
        }
        HStack(spacing: 8) {
            ImplChip(implDisplay: .simd, isApproximate: false,
                     isSelected: true, action: {})
            ImplChip(implDisplay: .metal, isApproximate: false,
                     isSelected: false, action: {})
        }
    }
    .padding(24)
    .frame(width: 580)
    .background(VSB.Surface.bg)
}
