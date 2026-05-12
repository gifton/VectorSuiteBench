import Foundation
import BenchKitC

/// AArch64 FPCR (Floating-Point Control Register) snapshot + flush-to-zero
/// control. Capturing FPCR at run start ensures the run manifest records the
/// denormals policy under which measurements were taken — without this, a
/// test that ran after some other code touched FPCR measures something
/// different than a fresh test.
public enum FPCRState {
    /// Bit 24: FZ — Flush-to-Zero. When set, denormal inputs and results
    /// are flushed to ±0. Without FZ, denormal math takes a microcode trap
    /// on Apple Silicon and tanks performance unpredictably.
    public static let flushToZeroBit: UInt64 = 1 << 24

    /// Bit 25: DN — Default NaN. When set, NaN inputs produce a fixed
    /// canonical NaN output rather than propagating their payload.
    public static let defaultNaNBit: UInt64 = 1 << 25

    /// Read the current FPCR via the BenchKitC bridge. Returns 0 on
    /// non-AArch64 platforms.
    public static func current() -> UInt64 {
        benchkit_read_fpcr()
    }

    /// Set FZ + DN. Returns the previous FPCR value so the caller can
    /// restore on shutdown if desired.
    @discardableResult
    public static func enableFlushToZero() -> UInt64 {
        let previous = current()
        let newValue = previous | flushToZeroBit | defaultNaNBit
        benchkit_write_fpcr(newValue)
        return previous
    }

    /// Restore a previously-captured FPCR value.
    public static func restore(_ value: UInt64) {
        benchkit_write_fpcr(value)
    }
}
