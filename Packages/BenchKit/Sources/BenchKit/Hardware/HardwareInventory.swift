import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Snapshot of the hardware a run executed on. Used to gate cross-machine
/// diff (diff view refuses to compare across mismatched `fingerprint`).
///
/// Captures: chip identifier, P/E core counts, GPU core count (rough), RAM,
/// OS / SDK / Swift versions. Probed via `sysctlbyname` + Bundle / ProcessInfo
/// at run start; cheap (<1 ms).
public struct HardwareInventory: Codable, Hashable, Sendable {
    public let chip: String
    public let pCoreCount: Int
    public let eCoreCount: Int
    public let gpuCoreCount: Int
    public let memoryGB: Int
    public let osVersion: String
    public let xcodeBuild: String
    public let swiftVersion: String

    public init(
        chip: String,
        pCoreCount: Int,
        eCoreCount: Int,
        gpuCoreCount: Int,
        memoryGB: Int,
        osVersion: String,
        xcodeBuild: String,
        swiftVersion: String
    ) {
        self.chip = chip
        self.pCoreCount = pCoreCount
        self.eCoreCount = eCoreCount
        self.gpuCoreCount = gpuCoreCount
        self.memoryGB = memoryGB
        self.osVersion = osVersion
        self.xcodeBuild = xcodeBuild
        self.swiftVersion = swiftVersion
    }

    /// Deterministic short hash for cache keys (e.g., `peaks/<fingerprint>.json`).
    public var fingerprint: String {
        let parts = [
            chip,
            "P\(pCoreCount)",
            "E\(eCoreCount)",
            "G\(gpuCoreCount)",
            "\(memoryGB)GB"
        ]
        return parts.joined(separator: "-")
    }

    /// Probe the host. Always succeeds — fields it can't read get sensible
    /// defaults (e.g., "unknown"). Designed never to fail a run start.
    public static func probe() -> HardwareInventory {
        HardwareInventory(
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            pCoreCount: Int(sysctlUInt64("hw.perflevel0.physicalcpu") ?? 0),
            eCoreCount: Int(sysctlUInt64("hw.perflevel1.physicalcpu") ?? 0),
            gpuCoreCount: 0,    // No public sysctl; left at 0 until we add IORegistry probe.
            memoryGB: Int((sysctlUInt64("hw.memsize") ?? 0) / (1024 * 1024 * 1024)),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            xcodeBuild: Bundle.main.infoDictionary?["DTXcodeBuild"] as? String ?? "unknown",
            swiftVersion: swiftCompilerVersion()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func swiftCompilerVersion() -> String {
        // No first-class API; best we can do is the compile-time bake-in.
        #if swift(>=6.0)
        return "6.0+"
        #elseif swift(>=5.10)
        return "5.10"
        #else
        return "unknown"
        #endif
    }
}
