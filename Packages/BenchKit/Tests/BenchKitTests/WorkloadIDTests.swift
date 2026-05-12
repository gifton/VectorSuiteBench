import Testing
import Foundation
@testable import BenchKit

@Suite("WorkloadID + CanonicalParams")
struct WorkloadIDTests {
    @Test("vectorflavor required for VectorCore vector ops")
    func vectorFlavorRequired() {
        #expect(throws: CanonicalParams.ValidationError.vectorFlavorMissingForVectorCoreVectorOp) {
            try CanonicalParams([:], impl: .vectorCore, op: .dot, shape: .vector(n: 512))
        }
    }

    @Test("vectorflavor forbidden for non-VectorCore impls")
    func vectorFlavorForbidden() {
        #expect(throws: CanonicalParams.ValidationError.vectorFlavorRequiresVectorCoreImpl) {
            try CanonicalParams(["vectorflavor": "optimized"], impl: .accelerate, op: .dot, shape: .vector(n: 512))
        }
    }

    @Test("Unknown vectorflavor rejected")
    func unknownFlavor() {
        #expect(throws: CanonicalParams.ValidationError.self) {
            try CanonicalParams(["vectorflavor": "fast"], impl: .vectorCore, op: .dot, shape: .vector(n: 512))
        }
    }

    @Test("Canonical params accept valid VectorCore flavor")
    func validFlavor() throws {
        let p = try CanonicalParams(["vectorflavor": "optimized"], impl: .vectorCore, op: .dot, shape: .vector(n: 512))
        #expect(p["vectorflavor"] == "optimized")
    }

    @Test("Non-canonical keys rejected")
    func nonCanonicalKey() {
        #expect(throws: CanonicalParams.ValidationError.self) {
            try CanonicalParams(["VectorFlavor": "optimized"], impl: .vectorCore, op: .dot, shape: .vector(n: 512))
        }
    }

    @Test("Round-trip Codable preserves equality")
    func roundTrip() throws {
        let params = try CanonicalParams(
            ["vectorflavor": "optimized", "api": "raw"],
            impl: .vectorCore, op: .dot, shape: .vector(n: 512)
        )
        let id = WorkloadID(
            op: .dot, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: 512), params: params
        )
        let encoded = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(WorkloadID.self, from: encoded)
        #expect(decoded == id)
        #expect(decoded.canonicalString == id.canonicalString)
    }

    @Test("Decoder re-validates params; tampered JSON throws")
    func decoderRevalidates() {
        // Hand-crafted JSON with a non-canonical (uppercase) param key.
        // The encoder would never produce this; only a hand edit or a buggy
        // migration could. Decoder must reject.
        let tampered = #"""
        {
          "op": "dot",
          "impl": "vectorCore",
          "implClass": "standard",
          "dtype": "f32",
          "shape": {"vector": {"n": 512}},
          "params": {"VectorFlavor": "optimized"}
        }
        """#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorkloadID.self, from: tampered)
        }
    }

    @Test("Decoder rejects vectorflavor on non-VectorCore impls")
    func decoderRejectsForbiddenFlavor() {
        let tampered = #"""
        {
          "op": "dot",
          "impl": "accelerate",
          "implClass": "standard",
          "dtype": "f32",
          "shape": {"vector": {"n": 512}},
          "params": {"vectorflavor": "optimized"}
        }
        """#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorkloadID.self, from: tampered)
        }
    }

    @Test("Decoder rejects missing vectorflavor on VectorCore vector ops")
    func decoderRejectsMissingFlavor() {
        let tampered = #"""
        {
          "op": "dot",
          "impl": "vectorCore",
          "implClass": "standard",
          "dtype": "f32",
          "shape": {"vector": {"n": 512}},
          "params": {}
        }
        """#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorkloadID.self, from: tampered)
        }
    }

    @Test("WorkloadID canonicalString is stable")
    func canonicalStringStable() throws {
        let p = try CanonicalParams(["vectorflavor": "optimized"], impl: .vectorCore, op: .dot, shape: .vector(n: 256))
        let id = WorkloadID(op: .dot, impl: .vectorCore, implClass: .standard, dtype: .f32, shape: .vector(n: 256), params: p)
        let s = id.canonicalString
        #expect(s.contains("dot"))
        #expect(s.contains("vectorCore"))
        #expect(s.contains("standard"))
        #expect(s.contains("vec(256)"))
        #expect(s.contains("vectorflavor:optimized"))
    }
}
