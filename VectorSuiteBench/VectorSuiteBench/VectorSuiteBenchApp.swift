import SwiftUI

/// VectorSuiteBench app entry point.
///
/// The default macOS SwiftUI template ships with a SwiftData ModelContainer
/// and an `Item` model — neither is used here. Persistence is JSON-on-disk
/// via `BenchKit.RunStore`; UI state is `@Observable` classes owned by
/// `AppRoot`.
@main
struct VectorSuiteBenchApp: App {
    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
    }
}
