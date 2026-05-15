import Foundation
import simd

/// Empirical peak compute (single P-core, register-resident FMA) and peak
/// memory bandwidth (STREAM-triad, multi-thread saturating). The two
/// reference lines of the Roofline chart.
///
/// **Why empirical, not vendor spec.** Vendor TDP / theoretical numbers don't
/// reflect what the OS scheduler, FPCR state, thermal envelope, and current
/// build flags actually deliver. The Roofline only makes sense against peaks
/// measured *on this machine*, under *this build*, so a candidate's
/// percentage-of-peak is comparable.
///
/// **Caching.** Result is written to `peaks/<hardwareFingerprint>.json` so
/// subsequent runs reuse it. The cached record carries a `method` block;
/// a mismatch between cached `method` and current method versions triggers
/// a re-measurement instead of silently changing every roofline.
public enum PeakMeasurement {

    // MARK: - Method versions

    /// Bumped whenever the FMA microkernel changes shape (different
    /// accumulator count, different FMA form, different lane width) — a
    /// stale cache must be rejected because the *meaning* of the number
    /// changes.
    public static let computeMethodVersion = "fma-microkernel-v1"

    /// Bumped whenever the STREAM-triad implementation changes (different
    /// element count, different chunking, different data type).
    public static let bandwidthMethodVersion = "stream-triad-v1"

    // MARK: - Public API

    /// Measure peak FLOPS via the FMA microkernel. Single-threaded;
    /// register-resident; no memory traffic. Returns measured GFLOP/s on a
    /// single P-core.
    public static func measureCompute(targetWallNanos: UInt64 = 100_000_000) -> ComputePeak {
        let clock = BenchClock()
        // Tune iteration count so total wall ≈ targetWallNanos. Probe with
        // a small M, measure, then scale.
        var M: UInt64 = 1_000
        for _ in 0..<8 {
            let elapsed = runFMAKernel(iterations: M, clock: clock).elapsedNanos
            if elapsed >= targetWallNanos { break }
            // Scale up with a safety margin so we don't undershoot.
            let scale = elapsed == 0 ? 16 : UInt64((Double(targetWallNanos) / Double(elapsed) * 1.25).rounded(.up))
            M = M &* Swift.max(scale, 2)
            if M > 10_000_000_000 { break }       // hard cap
        }

        let measurement = runFMAKernel(iterations: M, clock: clock)
        // 16 independent FMAs per iteration; each FMA has 4 lanes × 2 ops = 8 FLOPs.
        let flopsPerIteration: UInt64 = 16 * 4 * 2
        let totalFlops = Double(M) * Double(flopsPerIteration)
        let gflops = totalFlops / Double(measurement.elapsedNanos)
        return ComputePeak(
            gflops: gflops,
            elapsedNanos: measurement.elapsedNanos,
            iterations: M
        )
    }

    /// Measure peak memory bandwidth via STREAM-triad
    /// (`a[i] = b[i] + alpha * c[i]`) over arrays sized to exceed
    /// last-level cache. Multi-threaded via `TaskGroup` fan-out.
    public static func measureBandwidth(
        bytesPerArray: Int = 128 * 1024 * 1024,    // 128 MiB — exceeds M3 LLC (~32 MB)
        threadCount: Int? = nil
    ) async -> BandwidthPeak {
        let n = bytesPerArray / MemoryLayout<Float>.size
        let threads = threadCount ?? Swift.max(1, ProcessInfo.processInfo.activeProcessorCount)

        // Single shared-storage allocation per array; chunked across tasks
        // by index range. Use `UnsafeMutableBufferPointer` so the inner loop
        // sees raw pointers (no Array bounds-check per element).
        let aBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: n)
        let bBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: n)
        let cBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: n)
        defer {
            aBuf.deallocate(); bBuf.deallocate(); cBuf.deallocate()
        }
        aBuf.initialize(repeating: 0)
        bBuf.initialize(repeating: 1)
        cBuf.initialize(repeating: 2)

        let alpha: Float = 3.0
        let clock = BenchClock()

        // Discard first run as warm-up: brings pages into resident memory
        // and gets the cache replacement policy past cold-start transients.
        await runStreamTriad(a: aBuf, b: bBuf, c: cBuf, alpha: alpha, n: n, threads: threads)

        let t0 = clock.now()
        await runStreamTriad(a: aBuf, b: bBuf, c: cBuf, alpha: alpha, n: n, threads: threads)
        let elapsedNanos = clock.nanos(clock.now() &- t0)

        // Bandwidth = 24 bytes/element (read b, read c, write a) × N / time.
        // (`write a` is a non-temporal store in the ideal case, but Swift
        // gives us no portable hint; assume cache-line allocate-on-write,
        // which adds a read of `a`'s line. STREAM convention is still
        // 24 B/elem so the numbers compare to literature.)
        let totalBytes = Double(n) * 24.0
        let gbPerSec = totalBytes / Double(elapsedNanos)

        // Anti-DCE — touch every Nth element so the optimizer can't elide.
        // Sample a handful spread across the array; cheap.
        var sentinel: Float = 0
        let stride = Swift.max(1, n / 64)
        var i = 0
        while i < n {
            sentinel += aBuf[i]
            i &+= stride
        }
        BlackHole.consume(sentinel)

        return BandwidthPeak(
            gbPerSec: gbPerSec,
            elapsedNanos: elapsedNanos,
            elementCount: n,
            threadCount: threads
        )
    }

    /// Read the cached peak for this hardware fingerprint, if any. Returns
    /// `nil` when no file exists OR when the cached method versions don't
    /// match current versions (stale cache).
    public static func loadCached(
        for fingerprint: String,
        in store: RunStore
    ) -> PeakRecord? {
        let url = store.peakURL(for: fingerprint)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = try? Data(contentsOf: url),
            let record = try? decoder.decode(PeakRecord.self, from: data)
        else { return nil }
        guard
            record.method.compute == computeMethodVersion,
            record.method.bandwidth == bandwidthMethodVersion
        else {
            return nil    // stale method → re-measure
        }
        return record
    }

    /// Ensure a peak record exists for this hardware fingerprint. Returns
    /// the cached record on hit; runs both microkernels and writes a new
    /// record on miss/stale.
    @discardableResult
    public static func ensureCached(
        for hardware: HardwareInventory,
        in store: RunStore
    ) async throws -> PeakRecord {
        if let cached = loadCached(for: hardware.fingerprint, in: store) {
            return cached
        }
        let compute = measureCompute()
        let bandwidth = await measureBandwidth()
        let record = PeakRecord(
            schemaVersion: .current,
            hardwareFingerprint: hardware.fingerprint,
            measuredAt: Date(),
            peakComputeGFLOPS: compute.gflops,
            peakBandwidthGBPerSec: bandwidth.gbPerSec,
            method: PeakMethod(
                compute: computeMethodVersion,
                bandwidth: bandwidthMethodVersion
            )
        )
        try writePeakRecord(record, in: store)
        return record
    }

    // MARK: - Internals

    /// 16-accumulator FMA microkernel. Each accumulator runs a dependent
    /// chain on itself (`acc = acc * a + acc` ≡ `acc * (a + 1)`); 16
    /// chains in parallel hide the FMA latency on Apple Silicon's NEON
    /// pipes. `@inline(never)` keeps the compiler from inlining and
    /// hoisting loop-invariant work outside the timed region.
    @inline(never)
    private static func runFMAKernel(iterations: UInt64, clock: BenchClock) -> RawMeasurement {
        // The multiplier is `1 + ε`. Choosing a tiny `ε` keeps numbers
        // numerically stable across long chains (a literal `1.0` would
        // make each FMA a no-op AND let the optimizer eliminate the
        // chain; a large multiplier would Inf out within microseconds).
        let a = SIMD4<Float>(repeating: Float.ulpOfOne)

        var acc0 = SIMD4<Float>(repeating: 1.0)
        var acc1 = SIMD4<Float>(repeating: 1.0)
        var acc2 = SIMD4<Float>(repeating: 1.0)
        var acc3 = SIMD4<Float>(repeating: 1.0)
        var acc4 = SIMD4<Float>(repeating: 1.0)
        var acc5 = SIMD4<Float>(repeating: 1.0)
        var acc6 = SIMD4<Float>(repeating: 1.0)
        var acc7 = SIMD4<Float>(repeating: 1.0)
        var acc8 = SIMD4<Float>(repeating: 1.0)
        var acc9 = SIMD4<Float>(repeating: 1.0)
        var accA = SIMD4<Float>(repeating: 1.0)
        var accB = SIMD4<Float>(repeating: 1.0)
        var accC = SIMD4<Float>(repeating: 1.0)
        var accD = SIMD4<Float>(repeating: 1.0)
        var accE = SIMD4<Float>(repeating: 1.0)
        var accF = SIMD4<Float>(repeating: 1.0)

        let t0 = clock.now()
        var i: UInt64 = 0
        while i < iterations {
            acc0 = acc0.addingProduct(acc0, a)
            acc1 = acc1.addingProduct(acc1, a)
            acc2 = acc2.addingProduct(acc2, a)
            acc3 = acc3.addingProduct(acc3, a)
            acc4 = acc4.addingProduct(acc4, a)
            acc5 = acc5.addingProduct(acc5, a)
            acc6 = acc6.addingProduct(acc6, a)
            acc7 = acc7.addingProduct(acc7, a)
            acc8 = acc8.addingProduct(acc8, a)
            acc9 = acc9.addingProduct(acc9, a)
            accA = accA.addingProduct(accA, a)
            accB = accB.addingProduct(accB, a)
            accC = accC.addingProduct(accC, a)
            accD = accD.addingProduct(accD, a)
            accE = accE.addingProduct(accE, a)
            accF = accF.addingProduct(accF, a)
            i &+= 1
        }
        let elapsedNanos = clock.nanos(clock.now() &- t0)

        // Sink. Without consuming the accumulators, `-O` would delete
        // every FMA above as dead work.
        let sink = (acc0 + acc1) + (acc2 + acc3) + (acc4 + acc5) + (acc6 + acc7)
                 + (acc8 + acc9) + (accA + accB) + (accC + accD) + (accE + accF)
        BlackHole.consume(sink)

        return RawMeasurement(elapsedNanos: elapsedNanos)
    }

    /// STREAM-triad pass: `a[i] = b[i] + alpha * c[i]` over `n` elements,
    /// chunked across `threads` concurrent tasks. Pointer-arithmetic inner
    /// loop with `addingProduct` for FMA-friendly codegen.
    private static func runStreamTriad(
        a: UnsafeMutableBufferPointer<Float>,
        b: UnsafeMutableBufferPointer<Float>,
        c: UnsafeMutableBufferPointer<Float>,
        alpha: Float,
        n: Int,
        threads: Int
    ) async {
        let chunkSize = (n + threads - 1) / threads
        let aBase = a.baseAddress!
        let bBase = b.baseAddress!
        let cBase = c.baseAddress!
        // Pass raw addresses (Sendable) to escape the buffer pointer's
        // ownership rules across task boundaries.
        let aAddr = UInt(bitPattern: aBase)
        let bAddr = UInt(bitPattern: bBase)
        let cAddr = UInt(bitPattern: cBase)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<threads {
                let start = t * chunkSize
                let end = Swift.min(start + chunkSize, n)
                if start >= end { continue }
                group.addTask {
                    Self.streamTriadChunk(
                        aAddr: aAddr, bAddr: bAddr, cAddr: cAddr,
                        alpha: alpha, start: start, end: end
                    )
                }
            }
        }
    }

    @inline(never)
    private static func streamTriadChunk(
        aAddr: UInt, bAddr: UInt, cAddr: UInt,
        alpha: Float, start: Int, end: Int
    ) {
        let aPtr = UnsafeMutablePointer<Float>(bitPattern: aAddr)!
        let bPtr = UnsafeMutablePointer<Float>(bitPattern: bAddr)!
        let cPtr = UnsafeMutablePointer<Float>(bitPattern: cAddr)!
        var i = start
        while i < end {
            aPtr[i] = bPtr[i].addingProduct(alpha, cPtr[i])
            i &+= 1
        }
    }

    private static func writePeakRecord(_ record: PeakRecord, in store: RunStore) throws {
        let url = store.peakURL(for: record.hardwareFingerprint)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        // Atomic temp+rename via Foundation's `.atomic`.
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Types

public struct ComputePeak: Sendable {
    public let gflops: Double
    public let elapsedNanos: UInt64
    public let iterations: UInt64
}

public struct BandwidthPeak: Sendable {
    public let gbPerSec: Double
    public let elapsedNanos: UInt64
    public let elementCount: Int
    public let threadCount: Int
}

public struct PeakRecord: Codable, Sendable {
    public let schemaVersion: SchemaVersion
    public let hardwareFingerprint: String
    public let measuredAt: Date
    public let peakComputeGFLOPS: Double
    public let peakBandwidthGBPerSec: Double
    public let method: PeakMethod

    public init(
        schemaVersion: SchemaVersion,
        hardwareFingerprint: String,
        measuredAt: Date,
        peakComputeGFLOPS: Double,
        peakBandwidthGBPerSec: Double,
        method: PeakMethod
    ) {
        self.schemaVersion = schemaVersion
        self.hardwareFingerprint = hardwareFingerprint
        self.measuredAt = measuredAt
        self.peakComputeGFLOPS = peakComputeGFLOPS
        self.peakBandwidthGBPerSec = peakBandwidthGBPerSec
        self.method = method
    }
}

public struct PeakMethod: Codable, Sendable, Equatable {
    public let compute: String
    public let bandwidth: String

    public init(compute: String, bandwidth: String) {
        self.compute = compute
        self.bandwidth = bandwidth
    }
}

// MARK: - Internal helpers

private struct RawMeasurement {
    let elapsedNanos: UInt64
}
