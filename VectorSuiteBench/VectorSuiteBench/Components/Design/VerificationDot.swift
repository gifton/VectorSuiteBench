import SwiftUI

/// Small filled circle that signals a case's verification state at a
/// glance. Lives in the Status column of the data table beside the
/// verification flag pill, and beside summary-header `Cases` counts.
///
/// **Inflight pulse.** Per design doc §07 "Run still in progress" — the
/// in-flight state pulses opacity 1.0 ↔ 0.4 with `easeInOut` so the dot
/// reads as "alive" without spinning chrome that would clash with the
/// rest of the static UI. The pulse is wrapped in a `PulseWhen` view
/// modifier so `.onChange(of:)` can start / stop it cleanly when state
/// transitions.
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

/// Pulses `opacity` 1.0 ↔ 0.4 with a repeat-forever easeInOut while `active`
/// is `true`. Pulled out so the animation lifecycle (start on appear /
/// state transition; stop cleanly otherwise) is co-located.
private struct PulseWhen: ViewModifier {
    let active: Bool
    @State private var lowOpacity = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? (lowOpacity ? 0.4 : 1.0) : 1.0)
            .onAppear { startIfActive() }
            .onChange(of: active) { _, isActive in
                if isActive {
                    startIfActive()
                } else {
                    withAnimation(.default) { lowOpacity = false }
                }
            }
    }

    private func startIfActive() {
        guard active else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            lowOpacity = true
        }
    }
}

enum VerificationDisplayState: Hashable, Sendable {
    case verified
    case unverifiable
    case failed
    /// Case is mid-run; samples still streaming in. Used by the in-flight
    /// row treatment in the data table.
    case inflight

    var color: Color {
        switch self {
        case .verified:     return VSB.Status.pass
        case .unverifiable: return VSB.Status.warn
        case .failed:       return VSB.Status.fail
        case .inflight:     return VSB.Status.info
        }
    }

    /// VoiceOver / Voice Control label. Spoken text, not visible.
    var accessibilityLabel: Text {
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
