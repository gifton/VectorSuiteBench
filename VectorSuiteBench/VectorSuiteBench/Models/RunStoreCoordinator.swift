import Foundation
import BenchKit
import Observation

/// Top-level data spine for VectorSuiteBench's UI. Wraps a `RunStore`,
/// publishes the loaded `RunIndex` as an observable property, and watches
/// `index.json` for changes so a CLI-driven run while the app is open
/// shows up within ~1 second.
///
/// **MainActor-isolated.** SwiftUI views read directly without bridging.
/// The polling task hops onto the MainActor before mutating state, so
/// `index` and `runCache` are never touched concurrently.
///
/// **Cache.** Per-run `RunDocument`s are cached on first load. The cache
/// is a simple dictionary — future refinement could invalidate entries
/// whose underlying case files have changed, but Phase 2.1 runs are
/// write-once-finalize-once on disk, so a never-evicting cache is safe.
///
/// **Polling cadence.** Default 1 Hz. Tests pass a shorter interval
/// (e.g. 50 ms) so the watcher exercises promptly.
@MainActor
@Observable
final class RunStoreCoordinator {
    let store: RunStore
    private(set) var index: RunIndex

    private var runCache: [String: RunDocument] = [:]
    private var lastIndexModified: Date?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration

    init(store: RunStore, pollInterval: Duration = .seconds(1)) {
        self.store = store
        self.pollInterval = pollInterval
        self.index = (try? store.loadIndex()) ?? RunIndex(schemaVersion: .current, runs: [])
        self.lastIndexModified = Self.modificationDate(of: store.indexURL)
    }

    /// Convenience factory — wraps `RunStore.defaultStore()` with a temp-dir
    /// fallback. `defaultStore()` throws if the user-domain Application
    /// Support directory isn't writable (rare on macOS but possible in
    /// sandboxed first-launch scenarios); falling back to a temp dir keeps
    /// the app launch-able even when the canonical location is unavailable.
    static func makeDefault() -> RunStoreCoordinator {
        do {
            return try RunStoreCoordinator(store: .defaultStore())
        } catch {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("VectorSuiteBench-fallback", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: tmp, withIntermediateDirectories: true
            )
            return RunStoreCoordinator(store: RunStore(rootURL: tmp))
        }
    }

    /// Begin polling `index.json` for modification-time changes.
    /// Idempotent — calling again before `stopWatching()` is a no-op.
    func startWatching() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.refreshIfChanged()
            }
        }
    }

    /// Stop polling. Idempotent.
    func stopWatching() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reload `index.json` from disk if its modification time changed since
    /// the last load. Cheap (one `stat` call) — safe to invoke directly
    /// from foreground / scene-phase notifications if the user wants
    /// non-polling refresh paths later.
    func refreshIfChanged() {
        let url = store.indexURL
        let modified = Self.modificationDate(of: url)
        guard modified != lastIndexModified else { return }
        lastIndexModified = modified
        if let newIndex = try? store.loadIndex() {
            self.index = newIndex
        }
    }

    /// Force-reload the index regardless of modification time. Useful after
    /// an in-process `RunController` writes a new run — the file's mtime
    /// may not have ticked on a fast SSD and we still want the UI to update.
    func forceReloadIndex() {
        if let newIndex = try? store.loadIndex() {
            self.index = newIndex
            self.lastIndexModified = Self.modificationDate(of: store.indexURL)
        }
    }

    /// Load (or return cached) the full `RunDocument` for a runID.
    func loadRun(id: String) throws -> RunDocument {
        if let cached = runCache[id] { return cached }
        let doc = try store.loadRun(runID: id)
        runCache[id] = doc
        return doc
    }

    /// Invalidate cached documents. Call after writing new cases to an
    /// already-loaded run, or when test cleanup nukes the on-disk store.
    func clearCache() {
        runCache.removeAll()
    }

    // MARK: - Internals

    private static func modificationDate(of url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}
