import SwiftUI

/// Background + border + clip treatment for "selectable chip" surfaces.
/// Per design doc §05: **6 % cyan fill + 0.5 px cyan border** when
/// selected; **2 % white + hair-line border** when not. The dashed-vs-solid
/// distinction (e.g. `~ APPROX`) lives on the `Pill` atom, not here —
/// this modifier is strictly the chip-fill/chip-border layer.
///
/// **Four consumers** today:
/// - `CheckboxChip` (ops grid in the New Run modal)
/// - `ImplChip`     (impls grid in the New Run modal)
/// - The preset segmented control inside `RunConfigView`
/// - The vector-size pill grid inside `RunConfigView`
///
/// Each lived as an inline copy of the same logic before this modifier;
/// extracting it here means a future design-doc adjustment to the
/// selected-fill opacity / border weight changes once and not four times.
///
/// `cornerRadius` is configurable because the design doc uses **4** for
/// the larger grid chips (Ops / Impls / Preset) and **3** for the
/// smaller size pills (matches the `Pill` atom's pill-radius). Default
/// is `4` — the more common case.
struct SelectableChipBackground: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var background: Color {
        isSelected
            ? VSB.Impl.vectorCore.opacity(0.06)
            : Color.white.opacity(0.02)
    }

    private var border: Color {
        isSelected ? VSB.Impl.vectorCore.opacity(0.5) : VSB.Surface.hair2
    }
}

extension View {
    /// Apply the selectable-chip fill + border treatment from design
    /// doc §05. Pair with a containing `Button` for tap-toggle behavior;
    /// callers own the click target and the contents.
    ///
    /// - Parameters:
    ///   - isSelected: whether the chip is in the on state.
    ///   - cornerRadius: corner radius of the chip — defaults to
    ///     `VSB.Radius.chip` (4) for grid chips. Pass `VSB.Radius.pill`
    ///     (3) for size-pill consumers.
    func selectableChip(isSelected: Bool, cornerRadius: CGFloat = VSB.Radius.chip) -> some View {
        modifier(SelectableChipBackground(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}
