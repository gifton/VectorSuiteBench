import SwiftUI

/// Small badge/chip used everywhere in the app — table row status, chart
/// headers, sidebar entries, modal section labels. SF Mono 700 with
/// 0.4–0.6 tracking, 3 px rounded chip, matched chroma per design doc §02.
///
/// Seven semantic variants (the design doc enumerates these explicitly):
/// `pass / fail / warn / info / neutral / approx / accent`. `approx`
/// is the only variant with a *dashed* border — it visually demotes
/// approximate-math rows without changing the hue (color alone is too
/// quiet at this size).
///
/// **Two initializers** for the optional leading icon:
/// - `Pill(_, style:, icon: Character?)` — character glyphs (`✓ ✕ ! ⌇ ⏱ ~`).
/// - `Pill(_, style:, systemImage: String)` — SF Symbols (used by toolbar
///   chrome and chart headers where the icon is a real Apple glyph).
struct Pill: View {
    let text: String
    let style: PillStyle
    let icon: Icon

    enum Icon {
        case none
        case character(Character)
        case systemImage(String)
    }

    /// Character-glyph initializer. Pass a single Unicode character (or `nil`
    /// for no icon). Use this for the SF-Mono native glyphs in the design
    /// doc (`✓ ✕ ! ⌇ ⏱ ~`).
    init(_ text: String, style: PillStyle, icon: Character? = nil) {
        self.text = text
        self.style = style
        self.icon = icon.map(Icon.character) ?? .none
    }

    /// SF Symbol initializer. Use this when the icon is a real Apple glyph
    /// (`plus`, `chevron.left.forwardslash.chevron.right`, etc.) — the
    /// symbol is rendered at the pill's font size with `.heavy` weight.
    init(_ text: String, style: PillStyle, systemImage: String) {
        self.text = text
        self.style = style
        self.icon = .systemImage(systemImage)
    }

    var body: some View {
        HStack(spacing: 3) {
            iconView
            Text(text)
        }
        .vsbMonoBadge(color: style.foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(style.background)
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(style.border, style: style.borderStyle)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .none:
            EmptyView()
        case .character(let c):
            Text(String(c))
        case .systemImage(let name):
            // Inherit pill foreground via the `vsbMonoBadge` cascade.
            Image(systemName: name)
                .imageScale(.small)
        }
    }
}

enum PillStyle {
    case pass
    case fail
    case warn
    case info
    case neutral
    case approx
    case accent
}

private extension PillStyle {
    var foreground: Color {
        switch self {
        case .pass:    return VSB.Status.pass
        case .fail:    return VSB.Status.fail
        case .warn:    return VSB.Status.warn
        case .info:    return VSB.Status.info
        case .neutral: return VSB.Text.md
        case .approx:  return VSB.Text.lo
        case .accent:  return VSB.Impl.vectorCore
        }
    }
    var background: Color {
        switch self {
        case .pass:    return VSB.Status.pass.opacity(0.10)
        case .fail:    return VSB.Status.fail.opacity(0.12)
        case .warn:    return VSB.Status.warn.opacity(0.10)
        case .info:    return VSB.Status.info.opacity(0.10)
        case .neutral: return Color.white.opacity(0.05)
        case .approx:  return Color.clear
        case .accent:  return VSB.accentSoft
        }
    }
    var border: Color {
        switch self {
        case .pass:    return VSB.Status.pass.opacity(0.33)
        case .fail:    return VSB.Status.fail.opacity(0.33)
        case .warn:    return VSB.Status.warn.opacity(0.33)
        case .info:    return VSB.Status.info.opacity(0.33)
        case .neutral: return VSB.Surface.hair2
        case .approx:  return VSB.Text.lo
        case .accent:  return VSB.Impl.vectorCore.opacity(0.4)
        }
    }
    var borderStyle: StrokeStyle {
        switch self {
        case .approx:
            // The `~ APPROX` pill must remain identifiable even at small
            // sizes where hue alone is too quiet — dashed border is the
            // load-bearing signal.
            return StrokeStyle(lineWidth: 1, dash: [2, 2])
        default:
            return StrokeStyle(lineWidth: 0.5)
        }
    }
}

#Preview("Pill — every variant") {
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
            Pill("VERIFIED", style: .pass, icon: "✓")
            Pill("FAILED",   style: .fail, icon: "✕")
            Pill("UNVERIFIABLE", style: .warn, icon: "!")
            Pill("BIMODAL", style: .info, icon: "⌇")
        }
        HStack(spacing: 6) {
            Pill("SINGLE-SHOT", style: .neutral)
            Pill("LOOPED",      style: .neutral)
            Pill("TRUNCATED",   style: .warn, icon: "⏱")
            Pill("APPROX",      style: .approx, icon: "~")
            Pill("STANDARD",    style: .accent)
        }
        HStack(spacing: 6) {
            Pill("NEW RUN",     style: .accent,  systemImage: "plus")
            Pill("COMPARE",     style: .neutral, systemImage: "rectangle.split.2x1")
            Pill("EXPORT",      style: .neutral, systemImage: "square.and.arrow.down")
            Pill("CALIBRATE",   style: .neutral, systemImage: "scope")
        }
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
