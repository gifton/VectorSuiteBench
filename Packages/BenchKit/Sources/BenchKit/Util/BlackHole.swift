import Foundation

/// Anti-DCE sink. Every measured `Output` is consumed via `BlackHole.consume`
/// so the optimizer cannot elide the computation under `-O`. Without this, a
/// `cblas_sdot` whose result is unused folds to a constant — we'd be
/// measuring LLVM's constant folder, not the library.
///
/// Cost: ~2–5 ns/call on Apple Silicon. Part of the floor; recorded as
/// `harnessOverheadNanos` via the `NullWorkload` self-bench.
///
/// Implementation: a `@inline(never)` function that writes its argument to a
/// volatile sink. The volatile write prevents the compiler from concluding
/// that the value is unobserved.
public enum BlackHole {
    /// Per-thread sink. `volatile` semantics emulated via UnsafeMutablePointer
    /// + `@inline(never)`. The pointer is module-private storage; the value
    /// it points to is never read by anyone except `BlackHole.consume`.
    @usableFromInline
    nonisolated(unsafe) static var sink: UnsafeMutablePointer<UInt64> = {
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    @inline(never)
    public static func consume<T>(_ value: T) {
        // Funnel `value`'s bit pattern (up to 8 bytes) into the sink. For
        // types whose memory layout exceeds 8 bytes, take the first 8 bytes —
        // sufficient to defeat constant folding without paying for a full copy.
        withUnsafeBytes(of: value) { buf in
            if let base = buf.baseAddress {
                let limit = Swift.min(buf.count, MemoryLayout<UInt64>.size)
                var u: UInt64 = 0
                memcpy(&u, base, limit)
                sink.pointee &+= u
            }
        }
    }
}
