import Foundation

/// AArch64 FPCR (Floating-Point Control Register) snapshot + flush-to-zero
/// control. Capturing FPCR at run start ensures the run manifest records the
/// denormals policy under which measurements were taken — without this, a
/// test that ran after some other code touched FPCR measures something
/// different than a fresh test.
public enum FPCRState {
    /// Read the current FPCR value.
    public static func current() -> UInt64 {
        #if arch(arm64)
        var value: UInt64 = 0
        // MRS x0, FPCR  →  read FPCR into x0
        asm_read_fpcr(&value)
        return value
        #else
        return 0
        #endif
    }

    /// Set FZ (Flush-to-Zero, bit 24) and DN (Default NaN, bit 25). Returns
    /// the previous FPCR value so caller can restore.
    @discardableResult
    public static func enableFlushToZero() -> UInt64 {
        #if arch(arm64)
        let previous = current()
        let fz: UInt64 = 1 << 24
        let dn: UInt64 = 1 << 25
        let newValue = previous | fz | dn
        asm_write_fpcr(newValue)
        return previous
        #else
        return 0
        #endif
    }
}

#if arch(arm64)
/// MRS x0, FPCR
@_silgen_name("asm_read_fpcr")
private func asm_read_fpcr(_ out: UnsafeMutablePointer<UInt64>) {
    // Swift inline-asm isn't available pre-Swift-stable; we use a small C
    // shim that lives in BenchKit's bridging header instead. Until the shim
    // lands, fall back to a no-op that records FPCR as 0.
    //
    // TODO: ship FPCRBridge.c with `mrs %0, fpcr` / `msr fpcr, %0` shims
    //       and link them from this module.
    out.pointee = 0
}

@_silgen_name("asm_write_fpcr")
private func asm_write_fpcr(_ value: UInt64) {
    _ = value
    // See note above; placeholder.
}
#endif
