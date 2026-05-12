import Foundation
import Darwin

/// Anti-DCE sink. Every measured `Output` is consumed via `BlackHole.consume`
/// so the optimizer cannot elide the computation under `-O`. Without this, a
/// `cblas_sdot` whose result is unused folds to a constant — we'd be
/// measuring LLVM's constant folder, not the library.
///
/// **Per-thread storage.** Each pthread has its own sink, allocated lazily
/// via `pthread_key_create`. A global sink would cause cacheline ping-pong
/// across cores when `AsyncRunner` runs concurrent tasks; per-thread keeps
/// every consume on the local L1.
///
/// Cost: ~3–8 ns/call on Apple Silicon — function call + memcpy of up to 8
/// bytes + thread-local pointer load + load-modify-store. Recorded as part
/// of `RunMetadata.harnessOverheadNanos` via the `NullWorkload` self-bench.
///
/// **Cannot be inlined**: `@inline(never)` is mandatory. With inlining the
/// optimizer can prove `sink` is dead and elide the work. The volatile-store
/// pattern + opaque function call is what defeats DCE.
public enum BlackHole {
    // Lazily-initialized pthread key. The destructor frees the per-thread
    // sink when the thread terminates.
    private static let key: pthread_key_t = {
        var k: pthread_key_t = 0
        let result = pthread_key_create(&k) { ptr in
            // Free the per-thread sink.
            ptr.assumingMemoryBound(to: UInt64.self).deallocate()
        }
        precondition(result == 0, "pthread_key_create failed: \(result)")
        return k
    }()

    /// Pointer to this thread's sink. Allocates on first call per thread.
    @usableFromInline
    static func threadSink() -> UnsafeMutablePointer<UInt64> {
        if let raw = pthread_getspecific(key) {
            return raw.assumingMemoryBound(to: UInt64.self)
        }
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        p.initialize(to: 0)
        pthread_setspecific(key, UnsafeRawPointer(p))
        return p
    }

    /// Consume a value. The first 8 bytes of `value`'s memory representation
    /// are XOR'd into the per-thread sink. The `@inline(never)` + volatile
    /// store pattern prevents LLVM from concluding the value is unobserved.
    @inline(never)
    public static func consume<T>(_ value: T) {
        let sink = threadSink()
        withUnsafeBytes(of: value) { buf in
            guard let base = buf.baseAddress else { return }
            let limit = Swift.min(buf.count, MemoryLayout<UInt64>.size)
            var u: UInt64 = 0
            memcpy(&u, base, limit)
            // Volatile-style store via UnsafeMutablePointer; sink is opaque
            // (pthread_getspecific) so the optimizer cannot prove subsequent
            // loads of *sink will not observe this write.
            sink.pointee &+= u
        }
    }

    /// Reads the calling thread's sink. Used by tests to confirm that
    /// `consume` actually wrote — if the optimizer DCE'd the call chain,
    /// the sink would not advance.
    public static func threadSinkValue() -> UInt64 {
        threadSink().pointee
    }
}
