import SwiftUI

/// 4-column grid chip for the Operations section of the New Run modal
/// (design doc §05). Carries the op name + a math-shorthand subline
/// (`dot · ∑ aᵢbᵢ`). Tap-to-toggle.
///
/// **Selected state treatment** (per design doc §05): 6 % cyan fill,
/// 0.5 px cyan border, checkbox glyph fills with accent. **Unselected**:
/// 2 % white + hair-line border — quiet by default, so a half-configured
/// run reads as half-configured.
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
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(border, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(subtitle)"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Parts

    /// Filled-square glyph when selected, hollow when not. Native SF
    /// Symbol so it picks up the system's checkmark rendering across
    /// accessibility settings (high-contrast, increased-size).
    private var checkbox: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .imageScale(.medium)
            .foregroundStyle(isSelected ? VSB.Impl.vectorCore : VSB.Text.lo)
            .accessibilityHidden(true)
    }

    /// Backgrounds match the design doc spec: 6 % cyan when selected,
    /// 2 % white otherwise. Kept inline (not a token) because the chip
    /// is the only consumer of these specific opacities; tokenizing
    /// would over-generalize.
    private var background: Color {
        isSelected
            ? VSB.Impl.vectorCore.opacity(0.06)
            : Color.white.opacity(0.02)
    }

    private var border: Color {
        isSelected ? VSB.Impl.vectorCore.opacity(0.5) : VSB.Surface.hair2
    }

    private var borderWidth: CGFloat {
        isSelected ? 0.5 : 0.5
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
