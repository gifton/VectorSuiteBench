import SwiftUI

/// Pulses `opacity` 1.0 ↔ 0.4 with a repeating ease-in-out animation while
/// `active` is `true`. Stops cleanly when `active` flips to `false`.
///
/// Used by every "alive" indicator in the app:
/// - `VerificationDot.inflight` — case is mid-run.
/// - `ThrottleDot.inflight`     — run is mid-stream (design doc §07).
///
/// Pulled out of those atoms so the cadence (0.8 s easeInOut, autoreverses,
/// opacity 1.0 → 0.4) is defined once. Animations applied to opacity rather
/// than scale/transform so the dot stays in its layout slot — no chrome
/// jiggling around it.
///
/// Defaults are pinned (cadence is a load-bearing UI signal; consistency
/// across atoms is the point). Override only if a future indicator has a
/// genuinely different rhythm — at which point a second case with a clear
/// name is better than a parameter.
struct PulseWhen: ViewModifier {
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
