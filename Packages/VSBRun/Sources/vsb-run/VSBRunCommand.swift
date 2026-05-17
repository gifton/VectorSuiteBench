import Foundation
import ArgumentParser
import BenchKit
import VSBCore

/// `vsb-run` — the headless CLI that drives the VectorSuiteBench harness
/// end-to-end. Phase 2.0 ships this as the canonical entry point; the
/// SwiftUI app shell (Phase 2.1) will call the same `RunController`
/// in-process but read its config from a settings sheet rather than argv.
@main
struct VSBRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vsb-run",
        abstract: "Run the VectorSuiteBench harness and emit JSON + CSV to disk.",
        discussion: """
            Drives the registered workloads through BenchKit's RunController
            and writes a RunDocument under --output (or the default
            ~/Library/Application Support/VectorSuiteBench/).

            Examples:
              vsb-run --preset smoke
              vsb-run --preset standard --filter dot
              vsb-run --preset smoke --filter naive --filter dot --output ./out
              vsb-run --preset full --dry-run
            """
    )

    @Option(name: .long, help: "Preset to run: smoke | standard | full.")
    var preset: PresetArg

    @Option(
        name: .long,
        help: "Output directory. Defaults to ~/Library/Application Support/VectorSuiteBench/."
    )
    var output: String?

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: ArgumentHelp(
            "Filter by op or impl kind. Repeatable; OR-semantics within a kind, AND-semantics across kinds. e.g. `--filter dot --filter naive` runs only naïve-dot cases.",
            valueName: "op|impl"
        )
    )
    var filter: [String] = []

    @Flag(name: .long, help: "Print the planned case list and exit; do not measure.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Suppress per-case progress; print only the final summary.")
    var quiet: Bool = false

    @Flag(
        name: .long,
        help: "Skip empirical peak measurement (saves ~30 s on first run; Roofline chart loses reference lines)."
    )
    var skipPeaks: Bool = false

    @Flag(
        name: .long,
        help: "Allow Debug builds to measure. Disables ReleaseGuard; numbers will be meaningless. Used by integration tests."
    )
    var allowDebugBuilds: Bool = false

    mutating func run() async throws {
        let store = try makeStore()
        let registry = filteredRegistry()
        if registry.isEmpty {
            print("vsb-run: filter '\(filter.joined(separator: ","))' matched zero cases. Aborting.")
            throw ExitCode(2)
        }

        if dryRun {
            printPlan(registry)
            return
        }

        let cancellation = installSignalHandler()
        let start = Date()
        let controller = RunController(
            registry: registry,
            store: store,
            preset: preset.runPreset,
            cancellation: cancellation,
            allowDebugBuildsForTesting: allowDebugBuilds,
            measurePeaks: !skipPeaks
        )

        if !quiet {
            print("vsb-run: starting \(preset.rawValue) — \(registry.count) cases — runID \(controller.runID)")
        }

        do {
            let doc = try await controller.run()
            let wall = Date().timeIntervalSince(start)
            printSummary(doc: doc, store: store, wallSeconds: wall)
        } catch let releaseError as ReleaseGuard.Error {
            FileHandle.standardError.write(Data(("vsb-run: " + releaseError.description + "\n").utf8))
            throw ExitCode(3)
        }
    }

    // MARK: - Helpers

    private func makeStore() throws -> RunStore {
        if let output {
            let url = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return RunStore(rootURL: url)
        }
        return try RunStore.defaultStore()
    }

    private func filteredRegistry() -> [any RunnableWorkload] {
        let all = VSBCoreRegistry.workloads
        guard !filter.isEmpty else { return all }
        let opFilter = Set(filter.compactMap { OpKind(rawValue: $0) })
        let implFilter = Set(filter.compactMap { ImplKind(rawValue: $0) })
        // If the user supplied filter strings but NONE of them parsed to a
        // known OpKind or ImplKind, that's a typo — not "match everything".
        // Returning [] here trips the empty-registry exit-2 path so the
        // user sees the error rather than silently running the full
        // registry under what they thought was a filter.
        if opFilter.isEmpty && implFilter.isEmpty {
            return []
        }
        return all.filter { workload in
            let id = workload.identifier
            let opMatches  = opFilter.isEmpty  || opFilter.contains(id.op)
            let implMatches = implFilter.isEmpty || implFilter.contains(id.impl)
            return opMatches && implMatches
        }
    }

    private func printPlan(_ registry: [any RunnableWorkload]) {
        print("vsb-run dry-run — \(registry.count) cases planned:")
        for w in registry {
            print("  \(w.identifier.canonicalString)")
        }
    }

    private func printSummary(doc: RunDocument, store: RunStore, wallSeconds: TimeInterval) {
        let verified = doc.cases.filter { if case .verified = $0.verification { return true } else { return false } }.count
        let failed = doc.cases.filter { if case .failed = $0.verification { return true } else { return false } }.count
        let unverifiable = doc.cases.count - verified - failed
        let runDir = store.runDirectory(for: doc.runMetadata.runID).path
        print("")
        print("vsb-run: complete")
        print("  runID:        \(doc.runMetadata.runID)")
        print("  wall:         \(String(format: "%.2f", wallSeconds))s")
        print("  cases:        \(doc.cases.count) total — \(verified) verified, \(failed) failed, \(unverifiable) unverifiable")
        print("  manifest:     \(store.manifestURL(for: doc.runMetadata.runID).path)")
        print("  samples.csv:  \(store.samplesCSVURL(for: doc.runMetadata.runID).path)")
        print("  rundir:       \(runDir)")
    }

    /// Install a SIGINT handler that cancels the run cooperatively. A second
    /// SIGINT exits immediately. CTRL-C produces a *valid* partial
    /// RunDocument per the spec contract.
    private func installSignalHandler() -> CancellationToken {
        let token = CancellationToken()
        // DispatchSource gives us a clean way to handle SIGINT without
        // colliding with Swift's structured-concurrency cooperative
        // cancellation (which doesn't observe POSIX signals).
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        // Default disposition: SIGINT terminates the process. We need to
        // disable that before installing the source.
        signal(SIGINT, SIG_IGN)
        let sharedToken = token
        source.setEventHandler {
            if sharedToken.isCancelled {
                // Second CTRL-C → die now. `Darwin.exit` to disambiguate
                // from `ParsableCommand.exit(withError:)`.
                Darwin.exit(130)
            }
            sharedToken.cancel()
            FileHandle.standardError.write(Data("\nvsb-run: cancellation requested (Ctrl-C again to force-quit)\n".utf8))
        }
        source.resume()
        // Leak the source — it lives for the process lifetime.
        _ = source
        return token
    }
}

enum PresetArg: String, ExpressibleByArgument, CaseIterable {
    case smoke
    case standard
    case full

    var runPreset: RunPreset {
        switch self {
        case .smoke:    return .smoke
        case .standard: return .standard
        case .full:     return .full
        }
    }
}
