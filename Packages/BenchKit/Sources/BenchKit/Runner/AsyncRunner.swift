import Foundation
import Darwin.Mach

/// Async runner for workloads whose performance depends on internal
/// parallelism (`Operations.findNearest`, `Operations.distanceMatrix`,
/// `BatchOperations.*`). Runs inside a Task tree so `@TaskLocal` bindings
/// (e.g., VectorCore's `Operations.$simdProvider`, `ComputeProvider`)
/// propagate to the candidate.
///
/// **Provisional in Phase 1.** Phase 2+ when wiring real async candidates
/// (VectorIndex actors, EmbedKit) may need: actor reentrancy handling,
/// cancellation propagation via `withTaskCancellationHandler`, batch
/// fan-out semantics. Treat the protocol below as a working draft.
public struct AsyncRunner: Sendable {
    public let clock: BenchClock
    public let timerOverheadNanos: Double
    public let runID: String
    public let budget: WallClockBudget
    public let sampleCount: SampleCount

    public init(
        runID: String,
        budget: WallClockBudget,
        sampleCount: SampleCount,
        timerOverheadNanos: Double? = nil
    ) {
        let clock = BenchClock()
        self.clock = clock
        self.timerOverheadNanos = timerOverheadNanos
            ?? TimerCalibration.measureOverheadNanos(clock: clock)
        self.runID = runID
        self.budget = budget
        self.sampleCount = sampleCount
    }

    public func run<W: AsyncWorkload>(
        _ workload: W,
        cancellation: CancellationToken? = nil
    ) async -> CaseResult {
        var flags: Set<CaseFlag> = []
        if workload.identifier.implClass == .approximate {
            flags.insert(.approximate)
        }

        let baseSeed = SeedTable.seed(for: workload.identifier)

        // 1. Verification.
        var rngForVerify = SplitMix64(seed: baseSeed)
        let verification = await verifyAsync(workload, rng: &rngForVerify)
        if case .failed = verification {
            return failedResult(workload: workload, verification: verification, flags: flags)
        }

        let preRSS = readResidentSize()

        // 2. Build the input once for the run.
        var rngForInput = SplitMix64(seed: baseSeed)
        var input = await workload.makeInput(rng: &rngForInput)

        // 3. Warm-up.
        await warmUp(workload, input: &input)
        if cancellation?.isCancelled == true {
            flags.insert(.truncated)
            return makeEmptyResult(workload: workload, preRSS: preRSS, verification: verification, flags: flags)
        }

        // 4. Thermal gate.
        let thermalStateAtStart = ProcessInfo.processInfo.thermalState
        var thermalEvents: [ThermalEvent] = []

        // 5a. Single-shot.
        let singleShot = await sampleSingleShot(
            workload, input: &input, cancellation: cancellation, flags: &flags
        )

        let thermalStateAfterSingleShot = ProcessInfo.processInfo.thermalState
        if thermalStateAfterSingleShot != thermalStateAtStart {
            thermalEvents.append(ThermalEvent(
                timestampNanos: 0,
                from: String(describing: thermalStateAtStart),
                to: String(describing: thermalStateAfterSingleShot)
            ))
            flags.insert(.thermalEscalation)
        }

        // 5b. Amortized (if enabled). For async ops, K tuning is more
        // conservative — each invocation may already have non-trivial cost.
        let amortized: AmortizedResult? = sampleCount.amortizedSamples > 0
            ? await sampleAmortized(workload, input: &input, cancellation: cancellation, flags: &flags)
            : nil

        let postRSS = readResidentSize()
        let nanosPerOp = amortized?.nanosPerOp ?? Double(singleShot?.p50 ?? 0)
        let bandwidth = BandwidthEstimator.gbPerSec(bytesMoved: workload.bytesMoved, nanosPerOp: nanosPerOp)
        let gflops = BandwidthEstimator.gflops(flops: workload.flops, nanosPerOp: nanosPerOp)

        if singleShot?.looksBimodal == true { flags.insert(.bimodal) }
        if postRSS > preRSS + 10 * 1024 * 1024 { flags.insert(.memoryGrowth) }

        return CaseResult(
            id: workload.identifier,
            singleShot: singleShot,
            amortized: amortized,
            bandwidthGBPerSec: bandwidth,
            gflops: gflops,
            preSampleRSS: preRSS,
            postSampleRSS: postRSS,
            memoryTrace: [],
            thermalEvents: thermalEvents,
            timerOverheadNanos: timerOverheadNanos,
            verification: verification,
            flags: flags,
            runID: runID
        )
    }

    private func warmUp<W: AsyncWorkload>(_ workload: W, input: inout W.Input) async {
        let start = clock.now()
        let budgetNanos: UInt64 = 100_000_000
        var iters = 0
        repeat {
            do {
                let result = try await workload.invoke(&input)
                BlackHole.consume(result)
            } catch {
                BlackHole.consume(error)
            }
            iters += 1
        } while iters < 50 || clock.nanos(clock.now() &- start) < budgetNanos
    }

    private func sampleSingleShot<W: AsyncWorkload>(
        _ workload: W,
        input: inout W.Input,
        cancellation: CancellationToken?,
        flags: inout Set<CaseFlag>
    ) async -> LatencyDistribution? {
        let n = sampleCount.singleShotMax
        guard n > 0 else { return nil }
        var samples = [UInt64](repeating: 0, count: n)
        for i in 0..<n {
            if cancellation?.isCancelled == true {
                flags.insert(.truncated)
                return LatencyDistribution(samples: Array(samples.prefix(i)))
            }
            let t0 = clock.now()
            do {
                let result = try await workload.invoke(&input)
                let t1 = clock.now()
                BlackHole.consume(result)
                samples[i] = clock.nanos(t1 &- t0)
            } catch {
                BlackHole.consume(error)
                samples[i] = 0  // treated as a sample of 0; flagged separately
            }
        }
        return LatencyDistribution(samples: samples)
    }

    private func sampleAmortized<W: AsyncWorkload>(
        _ workload: W,
        input: inout W.Input,
        cancellation: CancellationToken?,
        flags: inout Set<CaseFlag>
    ) async -> AmortizedResult? {
        // Async amortization probes K with single-iteration runs to estimate
        // per-op cost (async ops are typically >µs, so probe overhead is small).
        let probeT0 = clock.now()
        do {
            let probeResult = try await workload.invoke(&input)
            BlackHole.consume(probeResult)
        } catch {
            BlackHole.consume(error)
        }
        let probeNanos = clock.nanos(clock.now() &- probeT0)
        let targetLoopNanos: UInt64 = 100_000
        let K = probeNanos == 0
            ? 16
            : Swift.max(1, Int(Double(targetLoopNanos) / Double(probeNanos)).advanced(by: 0))

        let samples = sampleCount.amortizedSamples
        var loopNanos = [UInt64](repeating: 0, count: samples)
        for i in 0..<samples {
            if cancellation?.isCancelled == true {
                flags.insert(.truncated)
                return AmortizedResult(
                    iterationsPerBatch: K,
                    batchNanos: LatencyDistribution(samples: Array(loopNanos.prefix(i)))
                )
            }
            let t0 = clock.now()
            for _ in 0..<K {
                do {
                    let result = try await workload.invoke(&input)
                    BlackHole.consume(result)
                } catch {
                    BlackHole.consume(error)
                }
            }
            let t1 = clock.now()
            loopNanos[i] = clock.nanos(t1 &- t0)
        }
        return AmortizedResult(
            iterationsPerBatch: K,
            batchNanos: LatencyDistribution(samples: loopNanos)
        )
    }

    private func verifyAsync<W: AsyncWorkload>(_ workload: W, rng: inout SplitMix64) async -> VerificationResult {
        guard let oracle = workload.referenceOracle else {
            return .unverifiable(reason: "no reference oracle declared")
        }
        var verifyInput = await workload.makeInput(rng: &rng)
        do {
            let candidate = try await workload.invoke(&verifyInput)
            let reference = oracle.compute(verifyInput)
            let window = ulpTolerance(
                op: workload.identifier.op,
                implClass: workload.identifier.implClass,
                shape: workload.identifier.shape
            )
            return oracle.compare(candidate, reference, window)
        } catch {
            return .failed(maxUlpObserved: .max, window: 0, sampleIndex: 0)
        }
    }

    // MARK: - Helpers

    private func failedResult<W: WorkloadMetadata>(
        workload: W,
        verification: VerificationResult,
        flags: Set<CaseFlag>
    ) -> CaseResult {
        CaseResult(
            id: workload.identifier,
            singleShot: nil, amortized: nil,
            bandwidthGBPerSec: 0, gflops: 0,
            preSampleRSS: 0, postSampleRSS: 0,
            memoryTrace: [], thermalEvents: [],
            timerOverheadNanos: timerOverheadNanos,
            verification: verification,
            flags: flags,
            runID: runID
        )
    }

    private func makeEmptyResult<W: WorkloadMetadata>(
        workload: W,
        preRSS: UInt64,
        verification: VerificationResult,
        flags: Set<CaseFlag>
    ) -> CaseResult {
        CaseResult(
            id: workload.identifier,
            singleShot: nil, amortized: nil,
            bandwidthGBPerSec: 0, gflops: 0,
            preSampleRSS: preRSS, postSampleRSS: readResidentSize(),
            memoryTrace: [], thermalEvents: [],
            timerOverheadNanos: timerOverheadNanos,
            verification: verification,
            flags: flags,
            runID: runID
        )
    }

    private func readResidentSize() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
