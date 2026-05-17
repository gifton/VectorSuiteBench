import Testing
import Foundation
@testable import BenchKit

@Suite("PeakMeasurement")
struct PeakMeasurementTests {

    @Test("FMA microkernel produces positive GFLOPS at a short budget")
    func computeKernelRuns() {
        // 20 ms budget keeps the test fast; we're not asserting the
        // *magnitude* of the result (Debug vs Release differ by ~10×),
        // just that the kernel ran and the arithmetic is sane.
        let result = PeakMeasurement.measureCompute(targetWallNanos: 20_000_000)
        #expect(result.gflops > 0, "FMA kernel must produce positive GFLOPS, got \(result.gflops)")
        #expect(result.elapsedNanos > 0)
        #expect(result.iterations > 0)
    }

    @Test("STREAM-triad produces positive bandwidth at a small array size")
    func bandwidthRuns() async {
        // 4 MiB fits in LLC — the number won't be a "real" peak, but the
        // kernel runs and we get a non-zero answer in milliseconds.
        let result = await PeakMeasurement.measureBandwidth(
            bytesPerArray: 4 * 1024 * 1024,
            threadCount: 2
        )
        #expect(result.gbPerSec > 0, "STREAM-triad must produce positive GB/s, got \(result.gbPerSec)")
        #expect(result.elapsedNanos > 0)
        #expect(result.elementCount == (4 * 1024 * 1024) / MemoryLayout<Float>.size)
        #expect(result.threadCount == 2)
    }

    @Test("ensureCached writes a record on miss; loadCached returns it on hit")
    func cacheRoundTrip() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let hardware = HardwareInventory.probe()

        #expect(PeakMeasurement.loadCached(for: hardware.fingerprint, in: store) == nil)

        let record = try await PeakMeasurement.ensureCached(for: hardware, in: store)
        #expect(record.method.compute == PeakMeasurement.computeMethodVersion)
        #expect(record.method.bandwidth == PeakMeasurement.bandwidthMethodVersion)
        #expect(record.hardwareFingerprint == hardware.fingerprint)
        #expect(record.peakComputeGFLOPS > 0)
        #expect(record.peakBandwidthGBPerSec > 0)

        let cached = try #require(PeakMeasurement.loadCached(for: hardware.fingerprint, in: store))
        #expect(cached.hardwareFingerprint == record.hardwareFingerprint)
        #expect(cached.peakComputeGFLOPS == record.peakComputeGFLOPS)
        #expect(cached.peakBandwidthGBPerSec == record.peakBandwidthGBPerSec)
        // ISO-8601 encoding drops sub-second precision; compare within
        // formatter granularity rather than exact equality.
        #expect(abs(cached.measuredAt.timeIntervalSince(record.measuredAt)) < 1.0)
    }

    @Test("writeCached round-trips a hand-built record through loadCached")
    func writeCachedRoundTrip() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let hardware = HardwareInventory.probe()

        let record = PeakRecord(
            schemaVersion: .current,
            hardwareFingerprint: hardware.fingerprint,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            peakComputeGFLOPS: 384.2,
            peakBandwidthGBPerSec: 312.5,
            method: PeakMethod(
                compute: PeakMeasurement.computeMethodVersion,
                bandwidth: PeakMeasurement.bandwidthMethodVersion
            )
        )

        try PeakMeasurement.writeCached(record, in: store)
        let reloaded = try #require(PeakMeasurement.loadCached(for: hardware.fingerprint, in: store))
        #expect(reloaded.hardwareFingerprint == hardware.fingerprint)
        #expect(reloaded.peakComputeGFLOPS == 384.2)
        #expect(reloaded.peakBandwidthGBPerSec == 312.5)
        #expect(reloaded.method == record.method)
    }

    @Test("loadCached returns nil when the cached method version is stale")
    func staleMethodInvalidatesCache() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let hardware = HardwareInventory.probe()

        let staleRecord = PeakRecord(
            schemaVersion: .current,
            hardwareFingerprint: hardware.fingerprint,
            measuredAt: Date(timeIntervalSince1970: 1_000_000),
            peakComputeGFLOPS: 1.0,
            peakBandwidthGBPerSec: 1.0,
            method: PeakMethod(compute: "fma-microkernel-v0-DOES-NOT-EXIST", bandwidth: "stream-triad-v0-OLD")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(staleRecord)
        let url = store.peakURL(for: hardware.fingerprint)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)

        #expect(PeakMeasurement.loadCached(for: hardware.fingerprint, in: store) == nil,
                "stale method versions must invalidate the cache so the roofline isn't silently changed")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakMeasurementTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
