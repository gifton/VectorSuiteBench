import Testing
import Foundation
@testable import BenchKit

@Suite("FPCR")
struct FPCRTests {
    @Test("Reads a plausible FPCR value on AArch64")
    func canRead() {
        let v = FPCRState.current()
        // FPCR fits in the low 32 bits on AArch64. A value of UInt64.max is
        // clearly the no-op fallback path. We don't assert a specific value
        // (the OS may have set FZ/DN already) — only that we got something
        // out of the upper bits being zero is plausible.
        #expect(v < UInt64(UInt32.max))
    }

    @Test("enableFlushToZero sets FZ and DN, returns previous value")
    func enableSetsBits() {
        let previous = FPCRState.enableFlushToZero()
        let current = FPCRState.current()
        // After enableFlushToZero, both FZ (bit 24) and DN (bit 25) must be set.
        #expect((current & FPCRState.flushToZeroBit) != 0)
        #expect((current & FPCRState.defaultNaNBit) != 0)
        // Restore for cleanliness.
        FPCRState.restore(previous)
    }
}
