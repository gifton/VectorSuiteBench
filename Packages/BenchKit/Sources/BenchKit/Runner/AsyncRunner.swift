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
        let caseStartTicks = clock.now()
        let perCaseBudgetNanos = nanos(from: budget.perCase)
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

        // 3. Warm-up (honors cancellation + budget).
        await warmUp(
            workload, input: &input,
            caseStartTicks: caseStartTicks,
            budgetNanos: perCaseBudgetNanos,
            cancellation: cancellation
        )
        if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: perCaseBudgetNanos, cancellation: cancellation) {
            flags.insert(.truncated)
            return makeEmptyResult(workload: workload, preRSS: preRSS, verification: verification, flags: flags)
        }

        // 4. Thermal gate.
        let thermalStateAtStart = ProcessInfo.processInfo.thermalState
        var thermalEvents: [ThermalEvent] = []

        // 5a. Single-shot.
        let singleShot = await sampleSingleShot(
            workload, input: &input,
            caseStartTicks: caseStartTicks,
            budgetNanos: perCaseBudgetNanos,
            cancellation: cancellation, flags: &flags
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
            ? await sampleAmortized(
                workload, input: &input,
                caseStartTicks: caseStartTicks,
                budgetNanos: perCaseBudgetNanos,
                cancellation: cancellation, flags: &flags
            )
            : nil

        let postRSS = readResidentSize()
        let (bandwidth, gflops) = Self.deriveThroughput(amortized: amortized, workload: workload)

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

    private func warmUp<W: AsyncWorkload>(
        _ workload: W, input: inout W.Input,
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?
    ) async {
        let start = clock.now()
        let warmupBudgetNanos: UInt64 = 100_000_000
        var iters = 0
        repeat {
            if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos, cancellation: cancellation) {
                return
            }
            do {
                let result = try await workload.invoke(&input)
                BlackHole.consume(result)
            } catch {
                BlackHole.consume(error)
            }
            iters += 1
        } while iters < 50 || clock.nanos(clock.now() &- start) < warmupBudgetNanos
    }

    private func sampleSingleShot<W: AsyncWorkload>(
        _ workload: W,
        input: inout W.Input,
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?,
        flags: inout Set<CaseFlag>
    ) async -> LatencyDistribution? {
        let n = sampleCount.singleShotMax
        guard n > 0 else { return nil }
        var samples = [UInt64](repeating: 0, count: n)
        for i in 0..<n {
            if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos, cancellation: cancellation) {
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
                samples[i] = 0  // treated as 0; flagged in CaseResult via .approximate / future error-count
            }
        }
        return LatencyDistribution(samples: samples)
    }

    private func sampleAmortized<W: AsyncWorkload>(
        _ workload: W,
        input: inout W.Input,
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?,
        flags: inout Set<CaseFlag>
    ) async -> AmortizedResult? {
        // M7 fix: iterative probe-and-double to auto-tune K, mirroring the
        // sync Runner. Hard cap at 1_000_000 to prevent runaway when probe
        // returns 1ns by quantization.
        let targetLoopNanos: UInt64 = 100_000
        let maxK = 1_000_000
        var probeK = 4
        for _ in 0..<8 {
            let t0 = clock.now()
            for _ in 0..<probeK {
                do {
                    let result = try await workload.invoke(&input)
                    BlackHole.consume(result)
                } catch {
                    BlackHole.consume(error)
                }
            }
            let elapsed = clock.nanos(clock.now() &- t0)
            if elapsed >= targetLoopNanos { break }
            let scale = elapsed == 0 ? 4 : Int((Double(targetLoopNanos) / Double(elapsed) * 1.25).rounded(.up))
            probeK = Swift.min(probeK * Swift.max(scale, 2), maxK)
            if probeK == maxK { break }
        }
        let K = probeK

        let samples = sampleCount.amortizedSamples
        var loopNanos = [UInt64](repeating: 0, count: samples)
        for i in 0..<samples {
            if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos, cancellation: cancellation) {
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

    /// Same as `Runner.nanos(from:)` — duplicated to keep AsyncRunner
    /// self-contained pending a shared RunnerCommon helper.
    internal func nanos(from duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(max(components.seconds, 0)) &* 1_000_000_000
            &+ UInt64(max(components.attoseconds, 0) / 1_000_000_000)
    }

    internal func budgetExceeded(caseStartTicks: UInt64, budgetNanos: UInt64) -> Bool {
        guard budgetNanos > 0 else { return false }
        return clock.nanos(clock.now() &- caseStartTicks) >= budgetNanos
    }

    internal func shouldStop(
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?
    ) -> Bool {
        if cancellation?.isCancelled == true { return true }
        return budgetExceeded(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos)
    }

    /// Same contract as Runner.deriveThroughput: only the Amortized median
    /// yields bandwidth/gflops; single-shot is never a fallback.
    static func deriveThroughput<W: WorkloadMetadata>(
        amortized: AmortizedResult?, workload: W
    ) -> (bandwidth: Double?, gflops: Double?) {
        guard let nanosPerOp = amortized?.nanosPerOp, nanosPerOp > 0 else {
            return (nil, nil)
        }
        return (
            BandwidthEstimator.gbPerSec(bytesMoved: workload.bytesMoved, nanosPerOp: nanosPerOp),
            BandwidthEstimator.gflops(flops: workload.flops, nanosPerOp: nanosPerOp)
        )
    }

    private func failedResult<W: WorkloadMetadata>(
        workload: W,
        verification: VerificationResult,
        flags: Set<CaseFlag>
    ) -> CaseResult {
        CaseResult(
            id: workload.identifier,
            singleShot: nil, amortized: nil,
            bandwidthGBPerSec: nil, gflops: nil,
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
            bandwidthGBPerSec: nil, gflops: nil,
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
