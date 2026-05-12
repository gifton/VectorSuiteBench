import Foundation

/// Maps `WorkloadID` → deterministic `SplitMix64` seed so the same workload
/// sees the same input bytes across runs, machines, and Swift versions.
///
/// `SeedTable.version` is recorded in `RunMetadata`. Changing the algorithm
/// here is a schema migration (every historical run is anchored to seeds
/// derived from this function).
public enum SeedTable {
    public static let version: Int = 1

    /// Salt prepended to every seeded input. Frozen forever as part of the
    /// SeedTable v1 contract.
    private static let salt: UInt64 = 0xB5_AD_4E_CE_DA_71_2C_91

    public static func seed(for id: WorkloadID) -> UInt64 {
        var hasher = SplitMix64(seed: salt)
        // Mix in each component of the WorkloadID. The exact mixing scheme is
        // part of the contract — DO NOT alter without bumping `version` and
        // writing a migration.
        _ = hasher.next()  // burn one to decouple from raw splitmix output
        hashInto(&hasher, id.op.rawValue)
        hashInto(&hasher, id.impl.rawValue)
        hashInto(&hasher, id.implClass.rawValue)
        hashInto(&hasher, id.dtype.rawValue)
        switch id.shape {
        case .vector(let n):
            hashInto(&hasher, "vector")
            hashInto(&hasher, UInt64(n))
        case .pairwise(let b, let n):
            hashInto(&hasher, "pairwise")
            hashInto(&hasher, UInt64(b))
            hashInto(&hasher, UInt64(n))
        case .matrix(let b, let n):
            hashInto(&hasher, "matrix")
            hashInto(&hasher, UInt64(b))
            hashInto(&hasher, UInt64(n))
        }
        hashInto(&hasher, id.params.canonicalString)
        return hasher.next()
    }

    @inline(__always)
    private static func hashInto(_ rng: inout SplitMix64, _ s: String) {
        for byte in s.utf8 {
            rng.state ^= UInt64(byte)
            _ = rng.next()
        }
    }

    @inline(__always)
    private static func hashInto(_ rng: inout SplitMix64, _ u: UInt64) {
        rng.state ^= u
        _ = rng.next()
    }
}
