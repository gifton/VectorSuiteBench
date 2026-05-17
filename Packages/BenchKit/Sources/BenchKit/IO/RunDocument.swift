import Foundation

/// Top-level JSON document persisted per run. Combines `RunMetadata`
/// (provenance, hardware, settings) with the list of `CaseResult`s.
public struct RunDocument: Codable, Sendable {
    public let schemaVersion: SchemaVersion
    public let runMetadata: RunMetadata
    public let cases: [CaseResult]

    public init(
        schemaVersion: SchemaVersion = .current,
        runMetadata: RunMetadata,
        cases: [CaseResult]
    ) {
        self.schemaVersion = schemaVersion
        self.runMetadata = runMetadata
        self.cases = cases
    }
}

/// Full provenance for a single run. Captured at run start; never duplicated
/// per-case (each `CaseResult` carries only the `runID` backpointer).
public struct RunMetadata: Codable, Sendable {
    public let runID: String
    public let timestamp: Date
    public let preset: RunPreset

    public let git: GitProvenance
    public let build: BuildProvenance
    public let hardware: HardwareInventory
    public let linkedLibraryVersions: [String: String]

    public let fpcrAtStart: UInt64
    public let lowPowerModeEnabled: Bool

    // Harness self-bench
    public let timerOverheadNanos: Double
    public let harnessOverheadNanos: Double?
    public let seedTableVersion: Int

    /// Wall-clock duration of the case-execution queue, in nanoseconds.
    /// `nil` while the run is in-flight; populated by `RunStore.finalizeRun`
    /// from the queue's start/end clock ticks. Schema 1.2+.
    public let wallTimeNanos: UInt64?

    public init(
        runID: String,
        timestamp: Date,
        preset: RunPreset,
        git: GitProvenance,
        build: BuildProvenance,
        hardware: HardwareInventory,
        linkedLibraryVersions: [String: String],
        fpcrAtStart: UInt64,
        lowPowerModeEnabled: Bool,
        timerOverheadNanos: Double,
        harnessOverheadNanos: Double?,
        seedTableVersion: Int,
        wallTimeNanos: UInt64? = nil
    ) {
        self.runID = runID
        self.timestamp = timestamp
        self.preset = preset
        self.git = git
        self.build = build
        self.hardware = hardware
        self.linkedLibraryVersions = linkedLibraryVersions
        self.fpcrAtStart = fpcrAtStart
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.timerOverheadNanos = timerOverheadNanos
        self.harnessOverheadNanos = harnessOverheadNanos
        self.seedTableVersion = seedTableVersion
        self.wallTimeNanos = wallTimeNanos
    }

    /// Returns a copy with `wallTimeNanos` set. Used by `RunStore.finalizeRun`
    /// to stamp the elapsed queue time into the manifest that was originally
    /// written before the queue ran.
    public func withWallTime(_ nanos: UInt64) -> RunMetadata {
        RunMetadata(
            runID: runID,
            timestamp: timestamp,
            preset: preset,
            git: git,
            build: build,
            hardware: hardware,
            linkedLibraryVersions: linkedLibraryVersions,
            fpcrAtStart: fpcrAtStart,
            lowPowerModeEnabled: lowPowerModeEnabled,
            timerOverheadNanos: timerOverheadNanos,
            harnessOverheadNanos: harnessOverheadNanos,
            seedTableVersion: seedTableVersion,
            wallTimeNanos: nanos
        )
    }
}
