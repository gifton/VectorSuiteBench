import SwiftUI

/// 4-column grid chip for the Operations section of the New Run modal
/// (design doc §05). Carries the op name + a math-shorthand subline
/// (`dot · ∑ aᵢbᵢ`). Tap-to-toggle.
///
/// **Selected state treatment** (per design doc §05): 6 % cyan fill,
/// 0.5 px cyan border, checkbox glyph fills with accent. The fill +
/// border live in `.selectableChip(isSelected:)` (the shared modifier
/// also used by `ImplChip`, the preset segmented control, and the
/// size-pill grid) so a future design-doc adjustment to chip styling
/// changes once.
///
/// The chip is fully self-contained: it takes `title`, `subtitle`,
/// `isSelected`, and an action closure. Re-usable for any future
/// 4-col-grid checkbox surface (e.g. a dtype picker once Phase 2.2+
/// adds ƒ16/ƒ64).
struct CheckboxChip: View {

    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                checkbox
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .vsbBody(color: isSelected ? VSB.Text.hi : VSB.Text.md)
                    Text(subtitle)
                        .vsbMonoSha()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectableChip(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(subtitle)"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Filled-square glyph when selected, hollow when not. Native SF
    /// Symbol so it picks up the system's checkmark rendering across
    /// accessibility settings (high-contrast, increased-size).
    private var checkbox: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .imageScale(.medium)
            .foregroundStyle(isSelected ? VSB.Impl.vectorCore : VSB.Text.lo)
            .accessibilityHidden(true)
    }
}

#Preview("CheckboxChip — selected + unselected") {
    VStack(spacing: 8) {
        HStack(spacing: 8) {
            CheckboxChip(title: "dot", subtitle: "∑ aᵢbᵢ",
                         isSelected: true, action: {})
            CheckboxChip(title: "l2dist", subtitle: "√Σ(aᵢ−bᵢ)²",
                         isSelected: false, action: {})
        }
        HStack(spacing: 8) {
            CheckboxChip(title: "cosine", subtitle: "a·b / ‖a‖‖b‖",
                         isSelected: true, action: {})
            CheckboxChip(title: "axpy", subtitle: "y ← αx + y",
                         isSelected: false, action: {})
        }
    }
    .padding(24)
    .frame(width: 480)
    .background(VSB.Surface.bg)
}
