import SwiftUI

/// Typography tokens for VectorSuiteBench.
///
/// Two families, three roles:
/// - **SF Pro Text** (system UI) carries labels, titles, and prose.
/// - **SF Mono with `monospacedDigit()`** is *strictly required* for every
///   number, every Git SHA, every axis label. A P99 number jittering by
///   half a character across rows is the kind of cognitive tax that erodes
///   trust in a benchmarking tool.
///
/// Apply via the `View` modifiers at the bottom of this file
/// (`.vsbBody()`, `.vsbMonoNumber()`, etc.) — they bundle font + foreground
/// + (where applicable) text-case so the call sites stay one line.
enum VSBFont {
    /// Canvas / artboard titles. Rare; used only for hero empty states.
    static let display     = Font.system(size: 22, weight: .semibold)
    /// Section headers, modal titles.
    static let title       = Font.system(size: 15, weight: .semibold)
    /// App default — paragraph copy, default UI text.
    static let body        = Font.system(size: 12.5, weight: .regular)
    /// Column heads, eyebrow labels. Used with `.textCase(.uppercase)` +
    /// extra tracking; see `.vsbCaption()` modifier below.
    static let caption     = Font.system(size: 10, weight: .semibold)

    /// **Every number cell in the app uses this font.** SF Mono with
    /// `monospacedDigit()` so digits sit on a tabular grid — a P99 cell
    /// at 1234 ns and one at 142 ns align vertically without flicker
    /// when sorting.
    static let monoNumber  = Font.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit()

    /// Smaller mono variant — git SHAs, chart axis labels, footer status,
    /// in-cell unit suffixes (`ns`, `GB/s`).
    static let monoShaAxis = Font.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit()

    /// Smallest mono — pill / badge text. Always paired with `.tracking(0.4)`
    /// at minimum so the all-caps reads cleanly at 10pt.
    static let monoBadge   = Font.system(size: 10, weight: .heavy, design: .monospaced).monospacedDigit()
}

// MARK: - View modifiers

extension View {
    /// Default app body text. SF Pro 12.5 regular at `text.hi`.
    func vsbBody(color: Color = VSB.Text.hi) -> some View {
        self.font(VSBFont.body).foregroundStyle(color)
    }

    /// Section / modal titles. SF Pro 15 semibold at `text.hi`.
    func vsbTitle() -> some View {
        self.font(VSBFont.title).foregroundStyle(VSB.Text.hi)
    }

    /// Eyebrow / column-head labels. Uppercase, tracked, demoted color —
    /// supports the data, never competes with it.
    func vsbCaption(color: Color = VSB.Text.lo) -> some View {
        self.font(VSBFont.caption)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(color)
    }

    /// Number cell. SF Mono 13 medium with tabular digits at `text.hi`.
    /// Pass `isAccent: true` to render VectorCore numbers in the accent
    /// hue (design principle P-02: VectorCore owns the saturated color).
    func vsbMonoNumber(color: Color = VSB.Text.hi) -> some View {
        self.font(VSBFont.monoNumber).foregroundStyle(color)
    }

    /// Git SHA + chart axis label + unit suffix. SF Mono 11 at `text.lo`.
    func vsbMonoSha(color: Color = VSB.Text.lo) -> some View {
        self.font(VSBFont.monoShaAxis).foregroundStyle(color)
    }
}
