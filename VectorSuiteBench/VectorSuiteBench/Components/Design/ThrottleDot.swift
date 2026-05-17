import SwiftUI

/// Small indicator that lives in the top-right "throttle slot" of every
/// sidebar row (design doc §04 + §07). Three semantic states:
///
/// - `.none`          — slot is empty; row renders a clean shape.
/// - `.thermal(Int)`  — warn-colored dot indicating the OS reported a
///                      thermal escalation *during* the run. The count is
///                      announced via VoiceOver so a screen reader user
///                      gets the same triage signal a sighted user gets
///                      from the dot's presence.
/// - `.inflight`      — info-colored pulsing dot for runs still streaming
///                      from `RunController`. Per design doc §07 "Run still
///                      in progress" — single small spinning dot in the
///                      throttle slot. (Item 4c wires this up; current
///                      callers always pass `.none` or `.thermal`.)
///
/// **Distinct from `VerificationDot`.** That atom signals per-case
/// numerical correctness; this one signals per-run thermal integrity.
/// They share the small-circle shape because both are read in the
/// "is this row trustworthy?" glance — keeping them separate atoms
/// keeps the semantics scannable in code search.
struct ThrottleDot: View {
    let state: State
    let size: CGFloat

    init(_ state: State, size: CGFloat = 6) {
        self.state = state
        self.size = size
    }

    /// Convenience: derive state from a `RunSummary`'s thermal-escalation
    /// count. Threshold is `> 0` per design doc (any escalation surfaces
    /// the dot — there's no "small enough to ignore" amount for an engineer
    /// trying to triage a run).
    init(escalations: Int, size: CGFloat = 6) {
        self.init(escalations > 0 ? .thermal(escalations) : .none, size: size)
    }

    enum State: Hashable, Sendable {
        case none
        case thermal(Int)
        case inflight
    }

    var body: some View {
        Group {
            switch state {
            case .none:
                Color.clear
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            case .thermal(let count):
                Circle()
                    .fill(VSB.Status.warn)
                    .frame(width: size, height: size)
                    .accessibilityLabel(Text(
                        count == 1 ? "thermal throttle during run"
                                   : "\(count) thermal throttles during run"
                    ))
            case .inflight:
                Circle()
                    .fill(VSB.Status.info)
                    .frame(width: size, height: size)
                    .modifier(PulseWhen(active: true))
                    .accessibilityLabel(Text("run in progress"))
            }
        }
    }
}

/// Local copy of the pulse modifier — same animation as `VerificationDot`'s
/// `.inflight` treatment so the two atoms read identically when both are
/// pulsing (e.g. an in-flight case inside an in-flight run). Pulled out
/// rather than imported because `VerificationDot.PulseWhen` is `private`.
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

#Preview("ThrottleDot — all states") {
    HStack(spacing: 24) {
        VStack(spacing: 6) { ThrottleDot(.none);          Text("none").vsbMonoSha() }
        VStack(spacing: 6) { ThrottleDot(.thermal(1));    Text("thermal × 1").vsbMonoSha() }
        VStack(spacing: 6) { ThrottleDot(.thermal(4));    Text("thermal × 4").vsbMonoSha() }
        VStack(spacing: 6) { ThrottleDot(.inflight);      Text("inflight (pulses)").vsbMonoSha() }
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
