import Foundation

/// Refuse to run measurements from a Debug build. The numbers under `-Onone`
/// are noise — function call overhead and unoptimized code dominate every
/// hot-path measurement.
///
/// Standard test suite (unit tests of BenchKit itself) bypasses this via the
/// `allowDebugForTesting` flag — exercised by tests that verify the guard's
/// behavior.
public enum ReleaseGuard {
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case debugBuild
        case unoptimized

        public var description: String {
            switch self {
            case .debugBuild:
                return "Measurement aborted: BenchKit was built with debug asserts enabled. Re-run with `-c release` (SwiftPM) or Release configuration (Xcode)."
            case .unoptimized:
                return "Measurement aborted: BenchKit was compiled with `-Onone`. Re-run with `-O` (default for Release configurations)."
            }
        }
    }

    public static func assertReleaseConfiguration(allowDebugForTesting: Bool = false) throws {
        if allowDebugForTesting { return }
        if _isDebugAssertConfiguration() {
            throw Error.debugBuild
        }
        // `_isFastAssertConfiguration` is true under `-Ounchecked`; that's
        // fine for measurement. The check we want is "are we in release?",
        // which is the negation of `_isDebugAssertConfiguration`. Apple's
        // standard-library helpers don't expose a direct "-O vs -Onone"
        // probe, so we rely on debug-assert config as our guard.
    }
}
