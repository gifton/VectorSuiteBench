import Foundation

// MARK: - OpKind

/// The operation being measured. Closed enum: adding a new op is an additive
/// schema change; renaming an existing case is a breaking change handled by
/// the @CodableKey aliasing convention below.
public enum OpKind: String, Codable, Hashable, Sendable, CaseIterable {
    case dot
    case l2dist
    case cosine
    case normalize
    case axpy
    case topK
    case pairwiseDistances
    case distanceMatrix
    /// Sentinel op for `NullWorkload` (the harness self-bench). Never appears
    /// in real benchmark cases; filters that key on `.op == .dot` etc. will
    /// not accidentally pick up the floor measurement.
    case null
}

// MARK: - ImplKind

/// The implementation under test.
public enum ImplKind: String, Codable, Hashable, Sendable, CaseIterable {
    case vectorCore
    case accelerate
    case naive
    case simd
}

// MARK: - ImplClass

/// Numerical-precision class for ULP-window resolution.
///
/// `.exact` (bit-stable against the reference) is deliberately *not* a class —
/// every Float32 candidate has inherent O(N · ε_f32) drift from a Float64
/// Kahan-Neumaier oracle. Bit-stability across runs is verified separately by
/// BenchKit's determinism self-test, not by the ULP-vs-oracle check.
///
/// `.naive` is distinct from `.standard` because unfused left-to-right
/// summation has Wilkinson `O(N · ε)` error, not the `O(log₂N · ε)` of
/// tree/pairwise reductions. Without a wider per-class window, naïve
/// baselines at N≥1024 false-fail verification.
///
/// **`ImplClass` describes algorithm shape, not library identity** (per
/// spec §9.14). Any impl that uses unfused left-to-right summation should
/// declare `.naive` — typically `ImplKind.naive`, but conceivably a future
/// Accelerate or simd flavor could too. The canonicalizer does NOT enforce
/// `ImplClass.naive ⇔ ImplKind.naive` for this reason; the coupling is
/// convention, not a constraint. Conversely, `.standard` is the default
/// (tree/pairwise summation as in vDSP, SIMD-fused kernels), and
/// `.approximate` flags deliberately precision-trading impls
/// (fast-rsqrt, reduced-precision intermediates).
public enum ImplClass: String, Codable, Hashable, Sendable, CaseIterable {
    case standard
    case naive
    case approximate
}

// MARK: - DType

public enum DType: String, Codable, Hashable, Sendable {
    case f32
    case f16
    case f64
}

// MARK: - Shape

/// Shape of the workload's input. Tagged via stable case names so a
/// WorkloadID encoded today still decodes after future shape additions.
public enum Shape: Hashable, Codable, Sendable {
    case vector(n: Int)
    case pairwise(b: Int, n: Int)
    case matrix(b: Int, n: Int)

    /// The "summation depth" used by `ulpTolerance(op:implClass:shape:)` to
    /// scale tolerances logarithmically with the underlying reduction length.
    public var summationDepth: Int {
        switch self {
        case .vector(let n):        return n
        case .pairwise(_, let n):   return n
        case .matrix(_, let n):     return n
        }
    }
}

// MARK: - CanonicalParams

/// Canonical (sorted-key, lowercase) parameter set for `WorkloadID`. Stringly
/// typing this is a trap (silent dedup failures from spelling variants); the
/// wrapper enforces canonicalization at construction and rejects malformed
/// inputs.
///
/// Required keys:
/// - `vectorflavor` (`optimized` | `generic` | `dynamic`) is required iff
///   `impl == .vectorCore`. Other impls (`cblas_sdot`, `simd_dot`, naïve) take
///   raw `[Float]` buffers and have no flavor concept; if present alongside a
///   non-VectorCore impl, construction throws.
/// - For `op == .dot` on `impl == .vectorCore`: `api` (`raw` | `metric`)
///   distinguishes `Vector.dot()` (returns +a·b) from `DotProductDistance`
///   (returns −a·b).
public struct CanonicalParams: Hashable, Encodable, Sendable {
    /// Backing storage: keys are lowercased, values are arbitrary lowercase
    /// strings. Hashing/equality come from this Dictionary directly.
    private let entries: [String: String]

    public enum ValidationError: Error, Equatable {
        case nonCanonicalKey(String)
        case nonCanonicalValue(key: String, value: String)
        case emptyKey
        case emptyValue(key: String)
        case vectorFlavorRequiresVectorCoreImpl
        case vectorFlavorMissingForVectorCoreVectorOp
        case unknownVectorFlavor(String)
        case unknownDotApi(String)
    }

    /// Construct canonical params with validation. Pass `impl` and `op` so
    /// rules like "vectorflavor required iff impl == .vectorCore" can be
    /// enforced at construction, not deferred to runtime.
    public init(
        _ raw: [String: String],
        impl: ImplKind,
        op: OpKind,
        shape: Shape
    ) throws {
        var canonical: [String: String] = [:]
        for (key, value) in raw {
            guard !key.isEmpty else { throw ValidationError.emptyKey }
            let canonicalKey = key.lowercased()
            guard canonicalKey == key else {
                throw ValidationError.nonCanonicalKey(key)
            }
            guard !value.isEmpty else {
                throw ValidationError.emptyValue(key: canonicalKey)
            }
            let canonicalValue = value.lowercased()
            guard canonicalValue == value else {
                throw ValidationError.nonCanonicalValue(key: key, value: value)
            }
            canonical[canonicalKey] = canonicalValue
        }

        // Rule 1: vectorflavor presence ↔ impl == .vectorCore for vector-shaped ops.
        let isVectorShape: Bool
        switch shape {
        case .vector: isVectorShape = true
        case .pairwise, .matrix: isVectorShape = false
        }
        let hasFlavor = canonical["vectorflavor"] != nil
        switch (impl, hasFlavor, isVectorShape) {
        case (.vectorCore, false, true):
            throw ValidationError.vectorFlavorMissingForVectorCoreVectorOp
        case (.vectorCore, true, _):
            // Validate the value.
            let value = canonical["vectorflavor"]!
            guard ["optimized", "generic", "dynamic"].contains(value) else {
                throw ValidationError.unknownVectorFlavor(value)
            }
        case (_, true, _) where impl != .vectorCore:
            throw ValidationError.vectorFlavorRequiresVectorCoreImpl
        default:
            break
        }

        // Rule 2: `api` on dot is valid iff impl == .vectorCore.
        if let api = canonical["api"] {
            if op == .dot, impl == .vectorCore {
                guard ["raw", "metric"].contains(api) else {
                    throw ValidationError.unknownDotApi(api)
                }
            }
            // For other (op, impl) combinations the `api` key is permitted but
            // unconstrained — future ops may use it differently.
        }

        self.entries = canonical
    }

    public subscript(key: String) -> String? { entries[key] }

    public var keys: [String] { entries.keys.sorted() }
    public var isEmpty: Bool { entries.isEmpty }

    /// Direct dictionary access (validated entries only). Used by the
    /// validating decoder in `WorkloadID`.
    public var rawEntries: [String: String] { entries }

    /// Bypass-the-validator constructor used **only** by trusted code paths
    /// (the encoder round-trip and tests). All public construction goes
    /// through `init(_:impl:op:shape:)`.
    internal init(unsafeEntries: [String: String]) {
        self.entries = unsafeEntries
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // Sort keys for stable encoding.
        let sorted = entries.sorted(by: { $0.key < $1.key })
        let ordered = OrderedStringDict(sorted)
        try container.encode(ordered)
    }

    /// Stable string representation suitable for hashing into a SeedTable seed.
    /// Format: `key1:value1;key2:value2;...` with keys lexicographically sorted.
    public var canonicalString: String {
        entries.sorted(by: { $0.key < $1.key })
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ";")
    }
}

/// Helper that encodes a sorted [String: String] preserving key order on the wire.
private struct OrderedStringDict: Encodable {
    let entries: [(String, String)]

    init(_ entries: [(key: String, value: String)]) {
        self.entries = entries.map { ($0.key, $0.value) }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        init(_ s: String) { self.stringValue = s }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in entries {
            try container.encode(value, forKey: DynamicKey(key))
        }
    }
}

// MARK: - WorkloadID

/// The primary deduplication key for a measured workload across runs. Two
/// runs with the same `WorkloadID` are directly comparable in the diff view;
/// anything else is apples-to-oranges and refused.
///
/// **Identity rules (locked):**
/// - `params` is a typed `CanonicalParams` wrapper (not `[String: String]`),
///   with sorted-key / lowercase normalization and per-(impl, op) validation.
/// - Wire-names of every enum case are **frozen forever**. Renaming a case
///   bumps the major schema version and requires a migration.
public struct WorkloadID: Hashable, Codable, Sendable {
    public let op: OpKind
    public let impl: ImplKind
    public let implClass: ImplClass
    public let dtype: DType
    public let shape: Shape
    public let params: CanonicalParams

    public init(
        op: OpKind,
        impl: ImplKind,
        implClass: ImplClass,
        dtype: DType,
        shape: Shape,
        params: CanonicalParams
    ) {
        self.op = op
        self.impl = impl
        self.implClass = implClass
        self.dtype = dtype
        self.shape = shape
        self.params = params
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case op, impl, implClass, dtype, shape, params
    }

    /// Encoding is straightforward — each field encodes via its own Codable
    /// conformance. `CanonicalParams` writes its sorted-key dictionary form.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(op, forKey: .op)
        try container.encode(impl, forKey: .impl)
        try container.encode(implClass, forKey: .implClass)
        try container.encode(dtype, forKey: .dtype)
        try container.encode(shape, forKey: .shape)
        try container.encode(params, forKey: .params)
    }

    /// Decoding re-runs `CanonicalParams`'s validating initializer using the
    /// **just-decoded** impl / op / shape values, so a tampered, hand-edited,
    /// or migration-emitted JSON cannot silently land non-canonical params
    /// in the dedup index. A mismatch throws as `DecodingError.dataCorrupted`
    /// rather than `ValidationError`, so callers using `JSONDecoder` see a
    /// standard Swift error type.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(OpKind.self, forKey: .op)
        let impl = try container.decode(ImplKind.self, forKey: .impl)
        let implClass = try container.decode(ImplClass.self, forKey: .implClass)
        let dtype = try container.decode(DType.self, forKey: .dtype)
        let shape = try container.decode(Shape.self, forKey: .shape)
        let rawParams = try container.decode([String: String].self, forKey: .params)
        let params: CanonicalParams
        do {
            params = try CanonicalParams(rawParams, impl: impl, op: op, shape: shape)
        } catch let validation as CanonicalParams.ValidationError {
            throw DecodingError.dataCorruptedError(
                forKey: .params,
                in: container,
                debugDescription: "Decoded params failed validation: \(validation). " +
                    "This indicates a tampered or migration-bug WorkloadID."
            )
        }
        self.op = op
        self.impl = impl
        self.implClass = implClass
        self.dtype = dtype
        self.shape = shape
        self.params = params
    }

    /// Canonical string form suitable for hashing into a SeedTable seed or
    /// rendering in CSV exports.
    public var canonicalString: String {
        let shapeStr: String
        switch shape {
        case .vector(let n):          shapeStr = "vec(\(n))"
        case .pairwise(let b, let n): shapeStr = "pair(\(b),\(n))"
        case .matrix(let b, let n):   shapeStr = "mat(\(b),\(n))"
        }
        return "\(op.rawValue)|\(impl.rawValue)|\(implClass.rawValue)|\(dtype.rawValue)|\(shapeStr)|\(params.canonicalString)"
    }
}
