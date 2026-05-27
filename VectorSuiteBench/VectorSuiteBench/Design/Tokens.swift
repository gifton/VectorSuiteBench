import SwiftUI

/// Color tokens for VectorSuiteBench.
///
/// **Source of truth:** `docs/design/phase-2.1-design.html` §02. Tokens are
/// expressed there in OKLCH; the values here are the closest stable sRGB
/// approximations (SwiftUI doesn't yet expose OKLCH directly). Refine if
/// Apple ships a `Color(.oklch:)` initializer or if a perceptual mismatch
/// shows up in side-by-side review.
///
/// **Conventions:**
/// - Only `impl.vectorCore` is saturated. Every other impl is a muted
///   graphite at low chroma — the eye lands on the candidate under test
///   without competing color.
/// - Status colors (`pass / fail / warn / info`) sit at matched chroma so
///   a pass and a fail badge feel equally weighted; meaning is in the hue,
///   not the loudness.
/// - The 5-step text ramp + 4-step surface ramp keep contrast deliberate;
///   most numbers render at `text.hi`, supporting labels at `text.lo`.
///
/// **Namespacing convention:** every token lives under `VSB` (sub-enums
/// for category). Fonts are also nested as `VSB.Fonts` (see Typography.swift).
/// View modifiers (`vsbBody`, `vsbCaption`, …) are top-level `View`
/// extensions — that's the only idiomatic SwiftUI place for them.
///
/// `Color` values use the explicit `.sRGB` initializer so the color space
/// is locked against future SwiftUI changes.
enum VSB {
    enum Surface {
        /// Page background. Anything below this is the window chrome.
        static let bg       = Color(.sRGB, red: 21/255, green: 22/255, blue: 26/255, opacity: 1)   // #15161A
        /// Lowest card surface (sidebar rows, summary cells).
        static let s0       = Color(.sRGB, red: 27/255, green: 28/255, blue: 33/255, opacity: 1)   // #1B1C21
        static let s1       = Color(.sRGB, red: 34/255, green: 35/255, blue: 42/255, opacity: 1)   // #22232A
        static let s2       = Color(.sRGB, red: 42/255, green: 44/255, blue: 52/255, opacity: 1)   // #2A2C34
        /// Highest surface — toolbar selected state, modal sheet body.
        static let s3       = Color(.sRGB, red: 51/255, green: 53/255, blue: 62/255, opacity: 1)   // #33353E

        /// Hair lines between table rows / grid cells. Almost invisible.
        static let hair     = Color.white.opacity(0.06)
        /// Slightly stronger hair — chart axis gridlines, popover borders.
        static let hair2    = Color.white.opacity(0.10)
        /// Section dividers between large regions.
        static let divider  = Color.white.opacity(0.14)
    }

    /// 4-step text ramp. `hi` is the default body color; `dim` is the
    /// nearly-invisible state for redacted / disabled cells. Use the lowest
    /// step that still reads — keeping text demoted is what lets numbers
    /// dominate the page.
    enum Text {
        static let hi       = Color(.sRGB, red: 231/255, green: 232/255, blue: 236/255, opacity: 1) // #E7E8EC
        static let md       = Color(.sRGB, red: 164/255, green: 166/255, blue: 174/255, opacity: 1) // #A4A6AE
        static let lo       = Color(.sRGB, red: 108/255, green: 110/255, blue: 120/255, opacity: 1) // #6C6E78
        static let dim      = Color(.sRGB, red:  74/255, green:  76/255, blue:  84/255, opacity: 1) // #4A4C54
    }

    /// Implementation tokens. Drives both 10×10 `ImplSwatch` swatches and
    /// chart series colors.
    ///
    /// **Only `vectorCore` is saturated** (design principle P-02). The
    /// baselines are hue-varying graphites at low chroma — distinct enough
    /// to identify (vDSP feels warm, Accelerate feels cool, etc.) but
    /// quiet enough that a chart filled with baselines doesn't compete
    /// with VectorCore's accent.
    enum Impl {
        static let vectorCore   = Color(.sRGB, red:   0/255, green: 201/255, blue: 211/255, opacity: 1) // #00C9D3 — the only vibrant
        static let vDSP         = Color(.sRGB, red: 172/255, green: 165/255, blue: 156/255, opacity: 1) // #ACA59C — warm graphite
        static let accelerate   = Color(.sRGB, red: 159/255, green: 161/255, blue: 181/255, opacity: 1) // #9FA1B5 — cool graphite
        static let metal        = Color(.sRGB, red: 179/255, green: 164/255, blue: 176/255, opacity: 1) // #B3A4B0 — magenta graphite (reserved for 2.3+)
        static let naive        = Color(.sRGB, red: 137/255, green: 139/255, blue: 148/255, opacity: 1) // #898B94 — neutral cool gray
        static let simd         = Color(.sRGB, red: 181/255, green: 169/255, blue: 154/255, opacity: 1) // #B5A99A — warm graphite (distinct from vDSP)
    }

    /// Verification + flag colors. Matched chroma ~0.16 — a `.pass` pill
    /// and a `.fail` pill feel equally weighted, the difference is hue.
    enum Status {
        static let pass     = Color(.sRGB, red:  94/255, green: 204/255, blue: 133/255, opacity: 1) // #5ECC85
        static let fail     = Color(.sRGB, red: 224/255, green: 120/255, blue:  83/255, opacity: 1) // #E07853
        static let warn     = Color(.sRGB, red: 220/255, green: 173/255, blue:  77/255, opacity: 1) // #DCAD4D
        static let info     = Color(.sRGB, red: 108/255, green: 168/255, blue: 215/255, opacity: 1) // #6CA8D7
    }

    /// Soft VectorCore tint — used for selected-row highlights, accent pill
    /// backgrounds, and the "feasible region" fill below Roofline ceilings.
    static let accentSoft   = Color(.sRGB, red: 0/255, green: 201/255, blue: 211/255, opacity: 0.18)

    /// Corner-radius scale. Four steps cover every rounded surface the
    /// app draws today; the names describe the surface's *role*, not
    /// the literal pixel value, so a future visual review can adjust
    /// one constant without hunting through view code.
    ///
    /// **`nonisolated`** because `CGFloat` constants don't need actor
    /// isolation — and nonisolated `static let` is callable from any
    /// context, including the `Layout`-protocol implementations
    /// (`FlowLayout`) and the test target.
    enum Radius {
        /// 10×10 implementation swatches. Smallest decoration; barely
        /// rounded but enough to soften the square pixel grid.
        static let swatch: CGFloat = 1.5
        /// Status pills, mode pills, size pills — anything the design
        /// doc treats as a "pill" (capsule-adjacent, tight padding).
        static let pill: CGFloat = 3
        /// Selectable grid chips: Ops `CheckboxChip`, Impls `ImplChip`,
        /// the preset segmented control. One step up from `pill` to
        /// match the chips' larger padding + heavier border.
        static let chip: CGFloat = 4
        /// Card surfaces: the calibration terminal-feed card; future
        /// modal sections that read as cards (none yet but reserved).
        static let card: CGFloat = 6
    }
}
