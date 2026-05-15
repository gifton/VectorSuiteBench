import Foundation
import Darwin.Mach

/// Runner for `BorrowingWorkload` / `MutatingWorkload`. `AsyncRunner` lives
/// alongside for `AsyncWorkload`.
///
/// The runner is generic over the concrete workload type so the hot path uses
/// static dispatch — no existential `any Workload` in the inner loop. The
/// registry erases workloads to `any WorkloadMetadata` for enumeration, but
/// dispatches into specialized `Runner.run(...)` instantiations per case.
///
/// **Task context**: `run` is `async` even though the per-sample inner loops
/// are synchronous. The async entry forces the caller to invoke from a Swift
/// `Task` tree, which is the necessary precondition for `@TaskLocal` bindings
/// (e.g., VectorCore's `Operations.$simdProvider`, `ComputeProvider`) to
/// propagate to the workload's `invoke`. A sync runner would silently
/// measure default providers instead of whatever the workload configured.
public struct Runner: Sendable {
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

    // MARK: - BorrowingWorkload

    public func run<W: BorrowingWorkload>(
        _ workload: W,
        cancellation: CancellationToken? = nil
    ) async -> CaseResult {
        let caseStartTicks = clock.now()
        let perCaseBudgetNanos = nanos(from: budget.perCase)
        var flags: Set<CaseFlag> = []
        if workload.identifier.implClass == .approximate {
            flags.insert(.approximate)
        }

        // 1. Verification (synchronous reference call before warm-up).
        let rng0 = SplitMix64(seed: SeedTable.seed(for: workload.identifier))
        var rngForVerify = rng0
        let verification = verifyBorrowing(workload, rng: &rngForVerify)
        if case .failed = verification {
            return failedResult(workload: workload, verification: verification, flags: flags)
        }

        // Pre-sample RSS snapshot.
        let preRSS = readResidentSize()

        // 2. Build the one input used for warm-up + both sampling modes.
        var rngForInput = rng0
        let input = workload.makeInput(rng: &rngForInput)

        // 3. Warm-up — 100 ms AND ≥50 iterations (whichever LAST). Honors
        //    cancellation and the per-case wall budget so a long-running
        //    workload's warm-up alone can't strand the Stop button.
        warmUpBorrowing(
            workload, input: input,
            caseStartTicks: caseStartTicks,
            budgetNanos: perCaseBudgetNanos,
            cancellation: cancellation
        )
        if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: perCaseBudgetNanos, cancellation: cancellation) {
            flags.insert(.truncated)
            return makeResult(
                workload: workload, singleShot: nil, amortized: nil,
                preRSS: preRSS, postRSS: readResidentSize(),
                memoryTrace: [], thermalEvents: [],
                verification: verification, flags: flags
            )
        }

        // 4. Thermal gate.
        let thermalStateAtStart = ProcessInfo.processInfo.thermalState
        var thermalEvents: [ThermalEvent] = []

        // 5a. Single-shot sampling.
        let singleShot = sampleSingleShotBorrowing(
            workload,
            input: input,
            caseStartTicks: caseStartTicks,
            budgetNanos: perCaseBudgetNanos,
            cancellation: cancellation,
            flags: &flags
        )

        // Check thermal state mid-run.
        let thermalStateAfterSingleShot = ProcessInfo.processInfo.thermalState
        if thermalStateAfterSingleShot != thermalStateAtStart {
            thermalEvents.append(ThermalEvent(
                timestampNanos: 0,
                from: String(describing: thermalStateAtStart),
                to: String(describing: thermalStateAfterSingleShot)
            ))
            flags.insert(.thermalEscalation)
        }

        // 5b. Amortized sampling (if enabled).
        let amortized: AmortizedResult? = sampleCount.amortizedSamples > 0
            ? sampleAmortizedBorrowing(
                workload, input: input,
                caseStartTicks: caseStartTicks,
                budgetNanos: perCaseBudgetNanos,
                cancellation: cancellation,
                flags: &flags
            )
            : nil

        let postRSS = readResidentSize()

        let (bandwidth, gflops) = Self.deriveThroughput(
            amortized: amortized, workload: workload
        )

        if singleShot?.looksBimodal == true {
            flags.insert(.bimodal)
        }
        // Memory growth heuristic: post-RSS > pre-RSS by more than 10 MB.
        if postRSS > preRSS + 10 * 1024 * 1024 {
            flags.insert(.memoryGrowth)
        }

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

    /// Convert a Swift `Duration` to nanoseconds. Used to compute per-case
    /// deadlines from `WallClockBudget.perCase`.
    internal func nanos(from duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(max(components.seconds, 0)) &* 1_000_000_000
            &+ UInt64(max(components.attoseconds, 0) / 1_000_000_000)
    }

    /// Returns true if the per-case wall budget has been exceeded since
    /// `caseStartTicks`. Caller decides how to act based on `budget.abortPolicy`.
    internal func budgetExceeded(caseStartTicks: UInt64, budgetNanos: UInt64) -> Bool {
        guard budgetNanos > 0 else { return false }
        return clock.nanos(clock.now() &- caseStartTicks) >= budgetNanos
    }

    /// Should the sampling loop stop now? True if cancelled OR the per-case
    /// wall budget is exhausted. Caller flags `.truncated` on the result.
    internal func shouldStop(
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?
    ) -> Bool {
        if cancellation?.isCancelled == true { return true }
        return budgetExceeded(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos)
    }

    /// Derive GB/s and GFLOP/s **only** from the Amortized median. Returns
    /// `(nil, nil)` when no Amortized data exists — single-shot is never a
    /// fallback (per §2.3 / BandwidthEstimator's contract).
    private static func deriveThroughput<W: WorkloadMetadata>(
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

    // MARK: - BorrowingWorkload helpers

    private func warmUpBorrowing<W: BorrowingWorkload>(
        _ workload: W, input: W.Input,
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?
    ) {
        let start = clock.now()
        let warmupBudgetNanos: UInt64 = 100_000_000   // 100 ms — see §2.4
        var iters = 0
        repeat {
            // Honor cancellation / budget inside warm-up: a long-running async
            // workload's warm-up alone shouldn't block Stop. (For sync
            // workloads, this also caps unbounded warm-up on slow ops.)
            if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos, cancellation: cancellation) {
                return
            }
            let result = workload.invoke(input)
            BlackHole.consume(result)
            iters += 1
        } while iters < 50 || clock.nanos(clock.now() &- start) < warmupBudgetNanos
    }

    private func sampleSingleShotBorrowing<W: BorrowingWorkload>(
        _ workload: W,
        input: W.Input,
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?,
        flags: inout Set<CaseFlag>
    ) -> LatencyDistribution? {
        let n = sampleCount.singleShotMax
        guard n > 0 else { return nil }
        var samples = [UInt64](repeating: 0, count: n)
        for i in 0..<n {
            if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos, cancellation: cancellation) {
                flags.insert(.truncated)
                return LatencyDistribution(samples: Array(samples.prefix(i)))
            }
            let t0 = clock.now()
            let result = workload.invoke(input)
            let t1 = clock.now()
            BlackHole.consume(result)
            samples[i] = clock.nanos(t1 &- t0)
        }
        return LatencyDistribution(samples: samples)
    }

    private func sampleAmortizedBorrowing<W: BorrowingWorkload>(
        _ workload: W,
        input: W.Input,
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?,
        flags: inout Set<CaseFlag>
    ) -> AmortizedResult? {
        // Auto-tune K so each loop takes ≥100 µs.
        let targetLoopNanos: UInt64 = 100_000
        var K = autoTuneK(workload, input: input, targetLoopNanos: targetLoopNanos)
        K = Swift.max(K, 1)

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
                let result = workload.invoke(input)
                BlackHole.consume(result)
            }
            let t1 = clock.now()
            loopNanos[i] = clock.nanos(t1 &- t0)
        }
        return AmortizedResult(
            iterationsPerBatch: K,
            batchNanos: LatencyDistribution(samples: loopNanos)
        )
    }

    private func autoTuneK<W: BorrowingWorkload>(
        _ workload: W, input: W.Input, targetLoopNanos: UInt64
    ) -> Int {
        // Probe: time a small K to estimate per-op cost, then scale up.
        var probeK = 4
        for _ in 0..<8 {
            let t0 = clock.now()
            for _ in 0..<probeK {
                let result = workload.invoke(input)
                BlackHole.consume(result)
            }
            let t1 = clock.now()
            let elapsed = clock.nanos(t1 &- t0)
            if elapsed >= targetLoopNanos {
                return probeK
            }
            // Scale up by (target / elapsed) with a safety factor of 1.25.
            let scale = elapsed == 0 ? 4 : Int((Double(targetLoopNanos) / Double(elapsed) * 1.25).rounded(.up))
            probeK = Swift.min(probeK * Swift.max(scale, 2), 1_000_000)
        }
        return probeK
    }

    private func verifyBorrowing<W: BorrowingWorkload>(_ workload: W, rng: inout SplitMix64) -> VerificationResult {
        guard let oracle = workload.referenceOracle else {
            return .unverifiable(reason: "no reference oracle declared")
        }
        let verifyInput = workload.makeInput(rng: &rng)
        let candidate = workload.invoke(verifyInput)
        // Typed: oracle.compute takes W.Input directly, oracle.compare takes
        // W.Output. No `Any` casts; type mismatches are compile-time errors.
        let reference = oracle.compute(verifyInput)
        let window = ulpTolerance(
            op: workload.identifier.op,
            implClass: workload.identifier.implClass,
            shape: workload.identifier.shape
        )
        return oracle.compare(candidate, reference, window)
    }

    // MARK: - MutatingWorkload

    public func run<W: MutatingWorkload>(
        _ workload: W,
        cancellation: CancellationToken? = nil
    ) async -> CaseResult {
        let caseStartTicks = clock.now()
        let perCaseBudgetNanos = nanos(from: budget.perCase)
        var flags: Set<CaseFlag> = []
        if workload.identifier.implClass == .approximate {
            flags.insert(.approximate)
        }

        // 1. Verification.
        let baseSeed = SeedTable.seed(for: workload.identifier)
        var rngForVerify = SplitMix64(seed: baseSeed)
        let verification = verifyMutating(workload, rng: &rngForVerify)
        if case .failed = verification {
            return failedResult(workload: workload, verification: verification, flags: flags)
        }

        let preRSS = readResidentSize()

        let singleShotN = sampleCount.singleShotMax
        let amortizedTargetK = autoTuneKMutating(workload, baseSeed: baseSeed)

        // 3. Warm-up — uses a small ephemeral bank; honors cancellation/budget.
        var rngForWarmup = SplitMix64(seed: baseSeed &+ 7)
        var warmupInputs = workload.makeInputs(count: max(amortizedTargetK, 1), rng: &rngForWarmup)
        warmUpMutating(
            workload, inputs: &warmupInputs,
            caseStartTicks: caseStartTicks,
            budgetNanos: perCaseBudgetNanos,
            cancellation: cancellation
        )
        if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: perCaseBudgetNanos, cancellation: cancellation) {
            flags.insert(.truncated)
            return makeResult(
                workload: workload, singleShot: nil, amortized: nil,
                preRSS: preRSS, postRSS: readResidentSize(),
                memoryTrace: [], thermalEvents: [],
                verification: verification, flags: flags
            )
        }

        // 4. Thermal state.
        let thermalStateAtStart = ProcessInfo.processInfo.thermalState
        var thermalEvents: [ThermalEvent] = []

        // 5a. Single-shot: N fresh inputs (one per sample), each consumed exactly
        //     once. Per §2.4 step 1 (Mutating, single-shot mode).
        var rngForSingle = SplitMix64(seed: baseSeed &+ 1)
        var singleInputs = workload.makeInputs(count: singleShotN, rng: &rngForSingle)
        let singleShot = sampleSingleShotMutating(
            workload, inputs: &singleInputs,
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

        // 5b. Amortized: build K inputs ONCE; snapshot originals; restore
        //     before each sample (M4 fix — never rebuild per sample).
        let amortized: AmortizedResult? = sampleCount.amortizedSamples > 0
            ? sampleAmortizedMutating(
                workload, K: amortizedTargetK, baseSeed: baseSeed &+ 2,
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

    private func warmUpMutating<W: MutatingWorkload>(
        _ workload: W, inputs: inout [W.Input],
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?
    ) {
        guard !inputs.isEmpty else { return }
        let start = clock.now()
        let warmupBudgetNanos: UInt64 = 100_000_000
        var iters = 0
        repeat {
            if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos, cancellation: cancellation) {
                return
            }
            let idx = iters % inputs.count
            let result = workload.invoke(&inputs[idx])
            BlackHole.consume(result)
            iters += 1
        } while iters < 50 || clock.nanos(clock.now() &- start) < warmupBudgetNanos
    }

    private func sampleSingleShotMutating<W: MutatingWorkload>(
        _ workload: W,
        inputs: inout [W.Input],
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?,
        flags: inout Set<CaseFlag>
    ) -> LatencyDistribution? {
        let n = inputs.count
        guard n > 0 else { return nil }
        var samples = [UInt64](repeating: 0, count: n)
        for i in 0..<n {
            if shouldStop(caseStartTicks: caseStartTicks, budgetNanos: budgetNanos, cancellation: cancellation) {
                flags.insert(.truncated)
                return LatencyDistribution(samples: Array(samples.prefix(i)))
            }
            let t0 = clock.now()
            let result = workload.invoke(&inputs[i])
            let t1 = clock.now()
            BlackHole.consume(result)
            samples[i] = clock.nanos(t1 &- t0)
        }
        return LatencyDistribution(samples: samples)
    }

    private func sampleAmortizedMutating<W: MutatingWorkload>(
        _ workload: W,
        K: Int,
        baseSeed: UInt64,
        caseStartTicks: UInt64,
        budgetNanos: UInt64,
        cancellation: CancellationToken?,
        flags: inout Set<CaseFlag>
    ) -> AmortizedResult? {
        // M4 fix: build the K-input bank ONCE before the sampling loop.
        // `originals` is a COW snapshot — assignment `inputs = originals`
        // before each sample restores the unmutated bytes cheaply (no
        // allocation in the steady state), and only the elements that were
        // detached by invoke's `inout` are copied back. K * makeInputs cost
        // is amortized across all samples instead of paid per sample, which
        // is the correct spec interpretation of "rotate per iteration".
        var rng = SplitMix64(seed: baseSeed)
        let originals = workload.makeInputs(count: K, rng: &rng)
        var inputs = originals

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
            // Restore K inputs to their original pre-mutation state. Outside
            // the timed window; cost is O(K) refcount ops on COW arrays.
            inputs = originals
            let t0 = clock.now()
            for j in 0..<K {
                let result = workload.invoke(&inputs[j])
                BlackHole.consume(result)
            }
            let t1 = clock.now()
            loopNanos[i] = clock.nanos(t1 &- t0)
        }
        return AmortizedResult(
            iterationsPerBatch: K,
            batchNanos: LatencyDistribution(samples: loopNanos)
        )
    }

    private func autoTuneKMutating<W: MutatingWorkload>(_ workload: W, baseSeed: UInt64) -> Int {
        let targetLoopNanos: UInt64 = 100_000
        var probeK = 4
        for _ in 0..<8 {
            var rng = SplitMix64(seed: baseSeed &+ 0xA5A5)
            var inputs = workload.makeInputs(count: probeK, rng: &rng)
            let t0 = clock.now()
            for j in 0..<probeK {
                let result = workload.invoke(&inputs[j])
                BlackHole.consume(result)
            }
            let t1 = clock.now()
            let elapsed = clock.nanos(t1 &- t0)
            if elapsed >= targetLoopNanos { return probeK }
            let scale = elapsed == 0 ? 4 : Int((Double(targetLoopNanos) / Double(elapsed) * 1.25).rounded(.up))
            probeK = Swift.min(probeK * Swift.max(scale, 2), 1_000_000)
        }
        return probeK
    }

    private func verifyMutating<W: MutatingWorkload>(_ workload: W, rng: inout SplitMix64) -> VerificationResult {
        guard let oracle = workload.referenceOracle else {
            return .unverifiable(reason: "no reference oracle declared")
        }
        var verifyInputs = workload.makeInputs(count: 1, rng: &rng)
        // Snapshot the input *before* mutation so the oracle sees the same
        // pre-state the candidate did. Typed throughout.
        let snapshot = verifyInputs[0]
        let candidate = workload.invoke(&verifyInputs[0])
        let reference = oracle.compute(snapshot)
        let window = ulpTolerance(
            op: workload.identifier.op,
            implClass: workload.identifier.implClass,
            shape: workload.identifier.shape
        )
        return oracle.compare(candidate, reference, window)
    }

    // MARK: - Result helpers

    private func failedResult<W: WorkloadMetadata>(
        workload: W,
        verification: VerificationResult,
        flags: Set<CaseFlag>
    ) -> CaseResult {
        CaseResult(
            id: workload.identifier,
            singleShot: nil,
            amortized: nil,
            bandwidthGBPerSec: nil,
            gflops: nil,
            preSampleRSS: 0,
            postSampleRSS: 0,
            memoryTrace: [],
            thermalEvents: [],
            timerOverheadNanos: timerOverheadNanos,
            verification: verification,
            flags: flags,
            runID: runID
        )
    }

    private func makeResult<W: WorkloadMetadata>(
        workload: W,
        singleShot: LatencyDistribution?,
        amortized: AmortizedResult?,
        preRSS: UInt64,
        postRSS: UInt64,
        memoryTrace: [MemorySample],
        thermalEvents: [ThermalEvent],
        verification: VerificationResult,
        flags: Set<CaseFlag>
    ) -> CaseResult {
        let (bandwidth, gflops) = Self.deriveThroughput(amortized: amortized, workload: workload)
        return CaseResult(
            id: workload.identifier,
            singleShot: singleShot,
            amortized: amortized,
            bandwidthGBPerSec: bandwidth,
            gflops: gflops,
            preSampleRSS: preRSS,
            postSampleRSS: postRSS,
            memoryTrace: memoryTrace,
            thermalEvents: thermalEvents,
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
