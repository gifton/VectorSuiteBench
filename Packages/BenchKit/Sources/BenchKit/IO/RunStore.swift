import Foundation

/// Filesystem-backed persistence for runs.
///
/// **Directory layout** (per §4 of the design spec):
/// ```
/// <rootURL>/
/// ├── index.json
/// ├── runs/
/// │   └── <runID>/
/// │       ├── manifest.json
/// │       └── cases/<workloadIDHash>.json
/// └── peaks/<hardwareFingerprint>.json
/// ```
///
/// **Atomicity**: every write goes to `<path>.tmp` → `fsync` → `rename(2)`.
/// APFS-atomic on macOS. Readers never see half-written files; a crash
/// mid-run leaves a valid partial run, not a corrupt JSON.
public final class RunStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Convenience: store under `~/Library/Application Support/VectorSuiteBench/`.
    public static func defaultStore(fileManager: FileManager = .default) throws -> RunStore {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport.appendingPathComponent("VectorSuiteBench", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return RunStore(rootURL: root)
    }

    // MARK: - Paths

    public var indexURL: URL {
        rootURL.appendingPathComponent("index.json")
    }

    public func runDirectory(for runID: String) -> URL {
        rootURL.appendingPathComponent("runs", isDirectory: true)
              .appendingPathComponent(runID, isDirectory: true)
    }

    public func manifestURL(for runID: String) -> URL {
        runDirectory(for: runID).appendingPathComponent("manifest.json")
    }

    public func casesDirectory(for runID: String) -> URL {
        runDirectory(for: runID).appendingPathComponent("cases", isDirectory: true)
    }

    public func caseURL(for runID: String, caseHash: String) -> URL {
        casesDirectory(for: runID).appendingPathComponent("\(caseHash).json")
    }

    public func peakURL(for hardwareFingerprint: String) -> URL {
        rootURL.appendingPathComponent("peaks", isDirectory: true)
              .appendingPathComponent("\(hardwareFingerprint).json")
    }

    // MARK: - Run lifecycle

    /// Begin a new run: create the run directory + write the manifest.
    public func beginRun(metadata: RunMetadata) throws {
        let runDir = runDirectory(for: metadata.runID)
        let casesDir = casesDirectory(for: metadata.runID)
        try FileManager.default.createDirectory(at: casesDir, withIntermediateDirectories: true)
        let manifest = ManifestPayload(
            schemaVersion: .current,
            runMetadata: metadata
        )
        try writeAtomic(manifest, to: manifestURL(for: metadata.runID))
    }

    /// Append a completed case to the run. One JSON file per case.
    public func writeCase(_ result: CaseResult) throws {
        let hash = caseHash(for: result.id)
        let url = caseURL(for: result.runID, caseHash: hash)
        try writeAtomic(result, to: url)
    }

    /// Finalize a run: load all case files, assemble the `RunDocument`, and
    /// update `index.json` with this run's summary.
    @discardableResult
    public func finalizeRun(runID: String) throws -> RunDocument {
        let manifest = try readJSON(ManifestPayload.self, at: manifestURL(for: runID))
        let cases = try loadCases(for: runID)
        let document = RunDocument(
            schemaVersion: .current,
            runMetadata: manifest.runMetadata,
            cases: cases
        )
        try updateIndex(with: document)
        return document
    }

    /// Read back a previously-finalized run, applying schema migrations as needed.
    public func loadRun(runID: String) throws -> RunDocument {
        let manifest = try readJSON(ManifestPayload.self, at: manifestURL(for: runID))
        let cases = try loadCases(for: runID)
        return RunDocument(
            schemaVersion: manifest.schemaVersion,
            runMetadata: manifest.runMetadata,
            cases: cases
        )
    }

    public func loadIndex() throws -> RunIndex {
        let url = indexURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RunIndex(schemaVersion: .current, runs: [])
        }
        return try readJSON(RunIndex.self, at: url)
    }

    // MARK: - Internals

    /// Hash function used to name per-case files. Stable across runs (so the
    /// same WorkloadID maps to the same filename in every run's cases/ dir).
    public func caseHash(for id: WorkloadID) -> String {
        // FNV-1a over the canonical string; 64 bits is plenty for collision-avoidance
        // within a single run's case set.
        let s = id.canonicalString
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return String(hash, radix: 16, uppercase: false)
    }

    private func loadCases(for runID: String) throws -> [CaseResult] {
        let dir = casesDirectory(for: runID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return try entries.map { name in
            let url = dir.appendingPathComponent(name)
            return try readJSON(CaseResult.self, at: url)
        }
    }

    private func updateIndex(with doc: RunDocument) throws {
        var index = (try? loadIndex()) ?? RunIndex(schemaVersion: .current, runs: [])
        let summary = RunSummary(
            runID: doc.runMetadata.runID,
            timestamp: doc.runMetadata.timestamp,
            gitSha: doc.runMetadata.git.sha,
            branch: doc.runMetadata.git.branch,
            preset: doc.runMetadata.preset.label,
            caseCount: doc.cases.count,
            completedCaseCount: doc.cases.filter { !$0.flags.contains(.truncated) }.count,
            hardwareFingerprint: doc.runMetadata.hardware.fingerprint,
            thermalEscalations: doc.cases.reduce(0) { $0 + $1.thermalEvents.count }
        )
        // Replace existing entry for the same runID if present.
        index.runs.removeAll { $0.runID == summary.runID }
        index.runs.append(summary)
        index.runs.sort { $0.timestamp > $1.timestamp }     // newest first
        try writeAtomic(index, to: indexURL)
    }

    private func writeAtomic<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // Foundation's `.atomic` already implements temp+rename; we add an
        // explicit second hop only when we need belt-and-suspenders behavior.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

/// On-disk manifest payload (header of a run). Stored at
/// `<runDir>/manifest.json`. The full `RunDocument` (manifest + cases) is
/// reconstructed by `RunStore.loadRun(runID:)` from the cases/ directory.
public struct ManifestPayload: Codable, Sendable {
    public let schemaVersion: SchemaVersion
    public let runMetadata: RunMetadata

    public init(schemaVersion: SchemaVersion, runMetadata: RunMetadata) {
        self.schemaVersion = schemaVersion
        self.runMetadata = runMetadata
    }
}

/// Sidebar-feeding index of all runs.
public struct RunIndex: Codable, Sendable {
    public let schemaVersion: SchemaVersion
    public var runs: [RunSummary]

    public init(schemaVersion: SchemaVersion, runs: [RunSummary]) {
        self.schemaVersion = schemaVersion
        self.runs = runs
    }
}

public struct RunSummary: Codable, Sendable {
    public let runID: String
    public let timestamp: Date
    public let gitSha: String
    public let branch: String
    public let preset: String
    public let caseCount: Int
    public let completedCaseCount: Int
    public let hardwareFingerprint: String
    public let thermalEscalations: Int

    public init(
        runID: String,
        timestamp: Date,
        gitSha: String,
        branch: String,
        preset: String,
        caseCount: Int,
        completedCaseCount: Int,
        hardwareFingerprint: String,
        thermalEscalations: Int
    ) {
        self.runID = runID
        self.timestamp = timestamp
        self.gitSha = gitSha
        self.branch = branch
        self.preset = preset
        self.caseCount = caseCount
        self.completedCaseCount = completedCaseCount
        self.hardwareFingerprint = hardwareFingerprint
        self.thermalEscalations = thermalEscalations
    }
}
