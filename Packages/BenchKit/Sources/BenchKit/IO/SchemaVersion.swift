import Foundation

/// Two-part schema version. Minor versions are additive (older readers
/// tolerate unknown fields). Major versions are breaking and require a
/// `RunMigration`.
public struct SchemaVersion: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Current on-disk schema. Bump `minor` for additive changes; bump
    /// `major` and add a migration for breaking changes.
    public static let current = SchemaVersion(major: 1, minor: 0)

    public var description: String { "\(major).\(minor)" }

    public static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }

    // MARK: Codable — encode as "major.minor" string for diff-friendly JSON.

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        let parts = s.split(separator: ".")
        guard parts.count == 2,
              let maj = Int(parts[0]),
              let min = Int(parts[1])
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected 'major.minor' format, got '\(s)'"
            )
        }
        self.major = maj
        self.minor = min
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
