import SwiftUI

/// Small filled circle that signals a case's verification state at a
/// glance. Lives in the Status column of the data table beside the
/// verification flag pill, and beside summary-header `Cases` counts.
///
/// **Inflight pulse.** Per design doc §07 "Run still in progress" — the
/// in-flight state pulses opacity 1.0 ↔ 0.4 with `easeInOut` so the dot
/// reads as "alive" without spinning chrome that would clash with the
/// rest of the static UI. The animation lives in the shared `PulseWhen`
/// modifier (Components/Design/PulseWhen.swift) so cadence stays
/// identical across every "alive" atom in the app.
///
/// **Accessibility.** Every state exposes a `Text` label via
/// `.accessibilityLabel(_:)` so screen readers and Voice Control see
/// "verified" / "in progress" rather than an unnamed circle. The dot
/// itself stays `.accessibilityHidden(false)` so it participates in
/// row-level VoiceOver descriptions.
///
/// `VerificationDisplayState` is a local enum that mirrors BenchKit's
/// `VerificationResult` — kept local so this file compiles before the
/// BenchKit SwiftPM dependency lands. Add an adapter at the seam
/// (Item 3b) once the dep is added:
/// ```
/// extension VerificationResult {
///     var displayState: VerificationDisplayState {
///         switch self {
///         case .verified:     return .verified
///         case .unverifiable: return .unverifiable
///         case .failed:       return .failed
///         }
///     }
/// }
/// ```
/// Note that `BenchKit.VerificationResult` carries associated data
/// (`maxUlpObserved`, `window`, `sampleIndex`, `reason`); the dot's
/// adapter intentionally discards those. The Status column's flag pills
/// and notes consume the rest.
struct VerificationDot: View {
    let state: VerificationDisplayState
    let size: CGFloat

    init(_ state: VerificationDisplayState, size: CGFloat = 8) {
        self.state = state
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .modifier(PulseWhen(active: state == .inflight))
            .accessibilityLabel(state.accessibilityLabel)
    }
}

/// **`nonisolated`** — the app target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise pin this
/// enum's auto-synthesized `Hashable`/`Equatable` conformances to
/// MainActor. Code that filters `Set<VerificationDisplayState>` from a
/// nonisolated context (the `CaseTableFilterLogic` pure-function path)
/// would emit Swift 6 warnings. Pure value enum; no MainActor reason.
nonisolated enum VerificationDisplayState: Hashable, Sendable {
    case verified
    case unverifiable
    case failed
    /// Case is mid-run; samples still streaming in. Used by the in-flight
    /// row treatment in the data table.
    case inflight

    /// MainActor-isolated because it reads `VSB.Status.*` tokens. The
    /// enum itself stays `nonisolated` so its `Hashable`/`Equatable`
    /// conformances are usable from nonisolated test contexts — only
    /// these two view-only accessors carry MainActor.
    @MainActor var color: Color {
        switch self {
        case .verified:     return VSB.Status.pass
        case .unverifiable: return VSB.Status.warn
        case .failed:       return VSB.Status.fail
        case .inflight:     return VSB.Status.info
        }
    }

    /// VoiceOver / Voice Control label. Spoken text, not visible.
    @MainActor var accessibilityLabel: Text {
        switch self {
        case .verified:     return Text("verified")
        case .unverifiable: return Text("unverifiable")
        case .failed:       return Text("verification failed")
        case .inflight:     return Text("in progress")
        }
    }
}

#Preview("VerificationDot — all states") {
    HStack(spacing: 16) {
        VStack(spacing: 6) { VerificationDot(.verified);     Text("verified").vsbMonoSha() }
        VStack(spacing: 6) { VerificationDot(.unverifiable); Text("unverifiable").vsbMonoSha() }
        VStack(spacing: 6) { VerificationDot(.failed);       Text("failed").vsbMonoSha() }
        VStack(spacing: 6) { VerificationDot(.inflight);     Text("inflight (pulses)").vsbMonoSha() }
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
