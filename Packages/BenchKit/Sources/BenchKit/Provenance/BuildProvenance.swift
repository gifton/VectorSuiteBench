import Foundation

/// Build-time provenance: optimization level, build configuration, compiler
/// flags. Captured at run start. Without these, a result from six months ago
/// is unreproducible.
public struct BuildProvenance: Codable, Hashable, Sendable {
    public let optimizationLevel: String        // "-O", "-Ounchecked", or "-Onone"
    public let buildConfiguration: String       // "Release" / "Debug"
    public let swiftCompilerFlags: [String]
    public let sdkVersion: String
    public let xcodeVersion: String

    public init(
        optimizationLevel: String,
        buildConfiguration: String,
        swiftCompilerFlags: [String],
        sdkVersion: String,
        xcodeVersion: String
    ) {
        self.optimizationLevel = optimizationLevel
        self.buildConfiguration = buildConfiguration
        self.swiftCompilerFlags = swiftCompilerFlags
        self.sdkVersion = sdkVersion
        self.xcodeVersion = xcodeVersion
    }

    public static func probe() -> BuildProvenance {
        let isDebug = _isDebugAssertConfiguration()
        return BuildProvenance(
            optimizationLevel: isDebug ? "-Onone" : "-O",
            buildConfiguration: isDebug ? "Debug" : "Release",
            swiftCompilerFlags: [],     // Not introspectable at runtime; left blank.
            sdkVersion: Bundle.main.infoDictionary?["DTSDKName"] as? String ?? "unknown",
            xcodeVersion: Bundle.main.infoDictionary?["DTXcode"] as? String ?? "unknown"
        )
    }
}
