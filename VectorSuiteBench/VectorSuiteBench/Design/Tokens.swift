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
enum VSB {
    enum Surface {
        /// Page background. Anything below this is the window chrome.
        static let bg       = Color(red: 21/255, green: 22/255, blue: 26/255)   // #15161A
        /// Lowest card surface (sidebar rows, summary cells).
        static let s0       = Color(red: 27/255, green: 28/255, blue: 33/255)   // #1B1C21
        static let s1       = Color(red: 34/255, green: 35/255, blue: 42/255)   // #22232A
        static let s2       = Color(red: 42/255, green: 44/255, blue: 52/255)   // #2A2C34
        /// Highest surface — toolbar selected state, modal sheet body.
        static let s3       = Color(red: 51/255, green: 53/255, blue: 62/255)   // #33353E

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
        static let hi       = Color(red: 231/255, green: 232/255, blue: 236/255) // #E7E8EC
        static let md       = Color(red: 164/255, green: 166/255, blue: 174/255) // #A4A6AE
        static let lo       = Color(red: 108/255, green: 110/255, blue: 120/255) // #6C6E78
        static let dim      = Color(red:  74/255, green:  76/255, blue:  84/255) // #4A4C54
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
        static let vectorCore   = Color(red:   0/255, green: 201/255, blue: 211/255) // #00C9D3 — the only vibrant
        static let vDSP         = Color(red: 172/255, green: 165/255, blue: 156/255) // #ACA59C — warm graphite
        static let accelerate   = Color(red: 159/255, green: 161/255, blue: 181/255) // #9FA1B5 — cool graphite
        static let metal        = Color(red: 179/255, green: 164/255, blue: 176/255) // #B3A4B0 — magenta graphite (reserved for 2.3+)
        static let naive        = Color(red: 137/255, green: 139/255, blue: 148/255) // #898B94 — neutral cool gray
        static let simd         = Color(red: 181/255, green: 169/255, blue: 154/255) // #B5A99A — warm graphite (distinct from vDSP)
    }

    /// Verification + flag colors. Matched chroma ~0.16 — a `.pass` pill
    /// and a `.fail` pill feel equally weighted, the difference is hue.
    enum Status {
        static let pass     = Color(red:  94/255, green: 204/255, blue: 133/255) // #5ECC85
        static let fail     = Color(red: 224/255, green: 120/255, blue:  83/255) // #E07853
        static let warn     = Color(red: 220/255, green: 173/255, blue:  77/255) // #DCAD4D
        static let info     = Color(red: 108/255, green: 168/255, blue: 215/255) // #6CA8D7
    }

    /// Soft VectorCore tint — used for selected-row highlights, accent pill
    /// backgrounds, and the "feasible region" fill below Roofline ceilings.
    static let accentSoft   = Color(red:   0/255, green: 201/255, blue: 211/255).opacity(0.18)
}
