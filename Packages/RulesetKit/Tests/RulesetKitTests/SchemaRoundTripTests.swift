// P2.5 acceptance: the reference rulesets and overlays must round-trip
// losslessly — decode → encode → decode yields an `==`-identical document,
// and encode is deterministic (second encode == first encode).

import Foundation
import Testing
@testable import RulesetKit

struct SchemaRoundTripTests {
    /// Walks up from this file until it finds `docs/plan/rulesets`, so the
    /// path works regardless of what base SwiftPM gives `#filePath`.
    static let rulesetDir: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let candidate = dir.appendingPathComponent("docs/plan/rulesets")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        fatalError("docs/plan/rulesets not found above \(#filePath)")
    }()

    static let rulesetFiles = [
        "hearts.standard.ruleset.json",
        "contract-bridge.rubber.ruleset.json",
        "cribbage.six-card.ruleset.json",
        "euchre.standard.ruleset.json",
    ]

    static let overlayFiles = [
        "contract-bridge.chicago.variant.json",
        "hearts.house-example.house.json",
    ]

    func read(_ name: String) throws -> String {
        let url = Self.rulesetDir.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func referenceRulesetsRoundTrip() throws {
        for name in Self.rulesetFiles {
            let text = try read(name)
            let doc = try Schema.decodeRuleset(text)
            let encoded = Schema.encode(doc)
            let doc2 = try Schema.decodeRuleset(encoded)
            #expect(doc2 == doc, "\(name) round-trip mismatch")
            #expect(Schema.encode(doc2) == encoded, "\(name) encode not deterministic")
        }
    }

    @Test func referenceOverlaysRoundTrip() throws {
        for name in Self.overlayFiles {
            let text = try read(name)
            let doc = try Schema.decodeOverlay(text)
            let encoded = Schema.encode(doc)
            let doc2 = try Schema.decodeOverlay(encoded)
            #expect(doc2 == doc, "\(name) round-trip mismatch")
            #expect(Schema.encode(doc2) == encoded, "\(name) encode not deterministic")
        }
    }

    @Test func referenceRoundTripPreservesCanonicalForm() throws {
        // Canonical form must be byte-identical before and after the
        // round-trip — this is the form resolver hashing (P2.6) runs on.
        for name in Self.rulesetFiles {
            let text = try read(name)
            let doc = try Schema.decodeRuleset(text)
            let before = Schema.canonical(doc)
            let doc2 = try Schema.roundTrip(doc)
            #expect(Schema.canonical(doc2) == before, "\(name) canonical form drifted")
        }
        for name in Self.overlayFiles {
            let text = try read(name)
            let doc = try Schema.decodeOverlay(text)
            let before = Schema.canonical(doc)
            let doc2 = try Schema.roundTrip(doc)
            #expect(Schema.canonical(doc2) == before, "\(name) canonical form drifted")
        }
    }

    @Test func decodeIgnoresKeyOrder() throws {
        // §5.1: key order is presentational; two documents that differ only
        // in key order decode to `==`-equal values.
        let text = try read("hearts.standard.ruleset.json")
        let doc = try Schema.decodeRuleset(text)
        guard case .object(let fields) = doc.json else {
            Issue.record("ruleset root is not an object")
            return
        }
        let doc2 = try RulesetDocument(json: .object(fields.reversed()), path: "$")
        #expect(doc2 == doc)
    }

    @Test func decodeRejectsWrongFormatMarker() throws {
        let text = try read("hearts.standard.ruleset.json")
        var tree = try JSONParser.parse(text)
        tree = try tree.withReplaced(key: "format", value: .string("parlor.overlay/1"))
        let bad = tree.prettyString()
        #expect(throws: SchemaError.formatMismatch(expected: Schema.rulesetFormat, actual: "parlor.overlay/1")) {
            _ = try Schema.decodeRuleset(bad)
        }
    }

    @Test func decodeRejectsMissingFormatMarker() throws {
        let text = try read("hearts.standard.ruleset.json")
        var tree = try JSONParser.parse(text)
        tree = try tree.withRemoved(key: "format")
        let bad = tree.prettyString()
        #expect(throws: SchemaError.formatMismatch(expected: Schema.rulesetFormat, actual: "missing")) {
            _ = try Schema.decodeRuleset(bad)
        }
    }

    @Test func decodeRejectsMalformedJSON() {
        #expect(throws: SchemaError.self) {
            _ = try Schema.decodeRuleset("{not json")
        }
        #expect(throws: SchemaError.self) {
            _ = try Schema.decodeOverlay("[1, 2, 3]")
        }
    }

    @Test func decodeRejectsUnknownPhaseKey() throws {
        // Shapes are closed: an unknown key inside a phase is an error, not
        // silent loss (SchemaError tests the rejectLeftovers path).
        let text = try read("hearts.standard.ruleset.json")
        let doc = try Schema.decodeRuleset(text)
        var tree = doc.json
        guard case .object(var fields) = tree else { Issue.record("not an object"); return }
        for (index, field) in fields.enumerated() where field.key == "phases" {
            guard case .array(var phases) = field.value, let first = phases.first,
                  case .object(var phaseFields) = first else { continue }
            phaseFields.append(JSONField(key: "bogusKey", value: .int(1)))
            phases[0] = .object(phaseFields)
            fields[index] = JSONField(key: "phases", value: .array(phases))
        }
        tree = .object(fields)
        #expect(throws: SchemaError.self) {
            _ = try RulesetDocument(json: tree, path: "$")
        }
    }

    @Test func decodeSurfacesPathInErrors() throws {
        let text = try read("hearts.standard.ruleset.json")
        let doc = try Schema.decodeRuleset(text)
        var tree = doc.json
        guard case .object(var fields) = tree else { Issue.record("not an object"); return }
        for (index, field) in fields.enumerated() where field.key == "phases" {
            guard case .array(var phases) = field.value, let first = phases.first,
                  case .object(var phaseFields) = first else { continue }
            for (pi, pf) in phaseFields.enumerated() where pf.key == "mechanic" {
                phaseFields[pi] = JSONField(key: "mechanic", value: .int(7))
            }
            phases[0] = .object(phaseFields)
            fields[index] = JSONField(key: "phases", value: .array(phases))
        }
        tree = .object(fields)
        do {
            _ = try RulesetDocument(json: tree, path: "$")
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("phases"))
        }
    }

    @Test func overlayDecodesHouseOptionsAsKeyedObject() throws {
        let doc = try Schema.decodeOverlay(try read("hearts.house-example.house.json"))
        let options = try #require(doc.options)
        #expect(options.contains { $0.key == "jackOfDiamonds" && $0.value == .bool(true) })
        #expect(doc.patch.isEmpty)
        #expect(doc.kind == "house")
    }

    @Test func overlayDecodesVariantPatchOps() throws {
        let doc = try Schema.decodeOverlay(try read("contract-bridge.chicago.variant.json"))
        #expect(doc.patch.count == 8)
        let first = try #require(doc.patch.first)
        #expect(first.op == "replace")
        #expect(first.path.hasPrefix("/"))
        #expect(doc.kind == "variant")
        #expect(doc.extends == "contract-bridge.rubber@^1.0")
    }
}

extension JSON {
    func withReplaced(key: String, value: JSON) throws -> JSON {
        guard case .object(let fields) = self else { throw SchemaError.notObject(path: "$") }
        var out = fields.filter { $0.key != key }
        out.append(JSONField(key: key, value: value))
        return .object(out)
    }

    func withRemoved(key: String) throws -> JSON {
        guard case .object(let fields) = self else { throw SchemaError.notObject(path: "$") }
        return .object(fields.filter { $0.key != key })
    }
}
