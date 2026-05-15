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

    @Test("ImplClass.naive Codable wire-name is frozen as \"naive\"")
    func implClassNaiveWireName() throws {
        let params = try CanonicalParams([:], impl: .naive, op: .dot, shape: .vector(n: 64))
        let id = WorkloadID(
            op: .dot, impl: .naive, implClass: .naive,
            dtype: .f32, shape: .vector(n: 64), params: params
        )
        let encoded = try JSONEncoder().encode(id)
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let implClassValue = json?["implClass"] as? String
        #expect(implClassValue == "naive",
                "expected implClass wire-name \"naive\"; got \(String(describing: implClassValue))")
        // Round-trip must preserve identity.
        let decoded = try JSONDecoder().decode(WorkloadID.self, from: encoded)
        #expect(decoded == id)
    }

    @Test("OpKind.null Codable wire-name is frozen as \"null\"")
    func opKindNullWireName() throws {
        let params = try CanonicalParams([:], impl: .naive, op: .null, shape: .vector(n: 1))
        let id = WorkloadID(
            op: .null, impl: .naive, implClass: .standard,
            dtype: .f32, shape: .vector(n: 1), params: params
        )
        let encoded = try JSONEncoder().encode(id)
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let opValue = json?["op"] as? String
        #expect(opValue == "null",
                "expected op wire-name \"null\"; got \(String(describing: opValue))")
        let decoded = try JSONDecoder().decode(WorkloadID.self, from: encoded)
        #expect(decoded == id)
    }

    @Test("vectorflavor wire-names are frozen as \"optimized\" | \"generic\" | \"dynamic\"")
    func vectorFlavorWireNames() throws {
        for flavor in ["optimized", "generic", "dynamic"] {
            let params = try CanonicalParams(
                ["vectorflavor": flavor],
                impl: .vectorCore, op: .dot, shape: .vector(n: 512)
            )
            let id = WorkloadID(
                op: .dot, impl: .vectorCore, implClass: .standard,
                dtype: .f32, shape: .vector(n: 512), params: params
            )
            let encoded = try JSONEncoder().encode(id)
            let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            let paramsJson = json?["params"] as? [String: Any]
            let flavorValue = paramsJson?["vectorflavor"] as? String
            #expect(flavorValue == flavor,
                    "expected vectorflavor wire-name \"\(flavor)\"; got \(String(describing: flavorValue))")
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
