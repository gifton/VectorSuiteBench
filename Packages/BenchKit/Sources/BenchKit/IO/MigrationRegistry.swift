import Foundation

/// Schema migration applied to raw JSON `Data` (not parsed `Codable` types,
/// so we don't have to keep `RunDocumentV1`/`V2`/... around forever).
public protocol RunMigration: Sendable {
    var from: SchemaVersion { get }
    var to: SchemaVersion { get }
    func migrate(_ json: Data) throws -> Data
}

/// Registry of all known migrations. Loaders apply them in order from the
/// detected on-disk version up to `SchemaVersion.current`.
public enum MigrationRegistry {
    /// Future migrations go here, sorted ascending by `from`.
    public static let migrations: [any RunMigration] = []

    public enum MigrationError: Error, CustomStringConvertible {
        case unknownVersion(String)
        case noMigrationFrom(SchemaVersion, to: SchemaVersion)
        case malformedDocument(underlying: Error)

        public var description: String {
            switch self {
            case .unknownVersion(let v):
                return "Document declares schema version '\(v)' which we cannot parse."
            case .noMigrationFrom(let from, let to):
                return "No migration path from \(from) to \(to). This run was written by a newer build of BenchKit; either upgrade or revert."
            case .malformedDocument(let err):
                return "Document is malformed: \(err)"
            }
        }
    }

    /// Decode a `RunDocument` from raw JSON data, applying migrations as
    /// needed to bring it up to `SchemaVersion.current`.
    public static func load(_ data: Data) throws -> RunDocument {
        let detected = try detectVersion(in: data)
        var current = data
        var version = detected

        while version < .current {
            guard let migration = migrations.first(where: { $0.from == version }) else {
                throw MigrationError.noMigrationFrom(version, to: .current)
            }
            current = try migration.migrate(current)
            version = migration.to
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RunDocument.self, from: current)
        } catch {
            throw MigrationError.malformedDocument(underlying: error)
        }
    }

    /// Inspect the JSON document and extract its `schemaVersion` field
    /// without decoding the full structure (since the structure may be
    /// older than what we know how to decode directly).
    private static func detectVersion(in data: Data) throws -> SchemaVersion {
        struct Header: Decodable {
            let schemaVersion: SchemaVersion
        }
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            return header.schemaVersion
        } catch {
            throw MigrationError.malformedDocument(underlying: error)
        }
    }
}
