import SwiftUI

/// Small filled circle that signals a case's verification state at a
/// glance. Lives in the Status column of the data table beside the
/// verification flag pill, and beside summary-header `Cases` counts.
///
/// `VerificationDisplayState` is a local enum that mirrors BenchKit's
/// `VerificationResult` — kept local so this file compiles before the
/// BenchKit SwiftPM dependency lands. Add an adapter at the seam
/// (Item 3b) once the dep is added:
/// ```
/// extension VerificationResult { var displayState: VerificationDisplayState { ... } }
/// ```
struct VerificationDot: View {
    let state: VerificationDisplayState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
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
}

#Preview("VerificationDot — all states") {
    HStack(spacing: 16) {
        VStack(spacing: 6) { VerificationDot(state: .verified);     Text("verified").vsbMonoSha() }
        VStack(spacing: 6) { VerificationDot(state: .unverifiable); Text("unverifiable").vsbMonoSha() }
        VStack(spacing: 6) { VerificationDot(state: .failed);       Text("failed").vsbMonoSha() }
        VStack(spacing: 6) { VerificationDot(state: .inflight);     Text("inflight").vsbMonoSha() }
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
