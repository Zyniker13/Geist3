// P2.6 acceptance: layer resolution, ID-addressed patching, canonical
// hashing, provenance, and rules diffing. The Chicago overlay applied to the
// rubber-bridge base is the primary end-to-end case; golden hashes were
// produced by an independent Python canonicalizer and are frozen here.

import Foundation
import Testing
@testable import RulesetKit

struct ResolverTests {
    /// Walks up from this file until it finds `docs/plan/rulesets`.
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

    func read(_ name: String) throws -> String {
        try String(contentsOf: Self.rulesetDir.appendingPathComponent(name), encoding: .utf8)
    }

    func rubberBase() throws -> RulesetDocument { try Schema.decodeRuleset(try read("contract-bridge.rubber.ruleset.json")) }
    func chicagoOverlay() throws -> OverlayDocument { try Schema.decodeOverlay(try read("contract-bridge.chicago.variant.json")) }
    func heartsBase() throws -> RulesetDocument { try Schema.decodeRuleset(try read("hearts.standard.ruleset.json")) }
    func houseOverlay() throws -> OverlayDocument { try Schema.decodeOverlay(try read("hearts.house-example.house.json")) }

    /// Minimal synthetic base for error-path tests (locked option, misc ops).
    func syntheticBase(lockedOption: Bool = false, lockedRule: Bool = false) throws -> RulesetDocument {
        var optionFields: [JSONField] = [
            JSONField(key: "id", value: .string("lockedOpt")),
            JSONField(key: "type", value: .string("bool")),
            JSONField(key: "default", value: .bool(true)),
            JSONField(key: "label", value: .object([JSONField(key: "default", value: .string("Locked"))])),
            JSONField(key: "rules", value: .array([])),
        ]
        if lockedOption { optionFields.append(JSONField(key: "locked", value: .bool(true))) }
        let middleOption = JSON.object(optionFields).prettyString()
        var ruleFields: [JSONField] = [
            JSONField(key: "id", value: .string("R.2")),
            JSONField(key: "text", value: .object([JSONField(key: "default", value: .string("Two"))])),
        ]
        if lockedRule { ruleFields.append(JSONField(key: "locked", value: .bool(true))) }
        let middleRule = JSON.object(ruleFields).prettyString()
        let text = try Schema.decodeRuleset("""
        {
          "format": "parlor.ruleset/1",
          "id": "test.game",
          "game": "test",
          "kind": "base",
          "version": "1.0.0",
          "name": { "default": "Test" },
          "options": [
            { "id": "target", "type": "int", "default": 100, "label": { "default": "Target" }, "rules": [] },
            \(middleOption),
            { "id": "flag", "type": "bool", "default": false, "label": { "default": "Flag" }, "rules": [] }
          ],
          "rules": [
            { "id": "R.1", "text": { "default": "One" } },
            \(middleRule),
            { "id": "R.3", "text": { "default": "Three" } }
          ],
          "vars": { "counter": { "scope": "round", "type": "int", "initial": "0" } }
        }
        """)
        return text
    }

    func overlay(patch: [(String, String, JSON?)] = [], options: JSON? = nil, extends: String = "test.game@^1.0", id: String = "test.overlay", kind: String = "variant") throws -> OverlayDocument {
        var patchArray: [JSON] = []
        for (op, path, value) in patch {
            var entry: [JSONField] = [
                JSONField(key: "op", value: .string(op)),
                JSONField(key: "path", value: .string(path)),
            ]
            if let value { entry.append(JSONField(key: "value", value: value)) }
            patchArray.append(.object(entry))
        }
        var fields: [JSONField] = [
            JSONField(key: "format", value: .string("parlor.overlay/1")),
            JSONField(key: "id", value: .string(id)),
            JSONField(key: "kind", value: .string(kind)),
            JSONField(key: "extends", value: .string(extends)),
            JSONField(key: "version", value: .string("1.0.0")),
            JSONField(key: "name", value: .object([JSONField(key: "default", value: .string("Overlay"))])),
        ]
        if let options { fields.append(JSONField(key: "options", value: options)) }
        fields.append(JSONField(key: "patch", value: .array(patchArray)))
        return try Schema.decodeOverlay(JSON.object(fields).prettyString())
    }

    func resolvedOption(_ resolved: ResolvedRuleset, _ id: String) -> JSON? {
        resolved.document.options?.first(where: { $0.id == id })?.value
    }

    // MARK: Golden hashes (independent Python canonicalizer)

    @Test func goldenHashesMatchIndependentCanonicalizer() throws {
        let rubber = try Resolver.resolve(base: rubberBase())
        #expect(rubber.hash == "44d86a091419d2baa134262da884f21f4a36c5522545193df0640e81257acd7f")
        let hearts = try Resolver.resolve(base: heartsBase())
        #expect(hearts.hash == "5d158dd6821c42ed46b0bca1b4d49cb14a9060d0e98b9f7f26968de2efc124ec")
    }

    // MARK: Chicago overlay → rubber base (primary acceptance)

    @Test func chicagoResolvesOntoRubber() throws {
        let resolved = try Resolver.resolve(base: rubberBase(), variant: chicagoOverlay())
        // Deal-1 vulnerability flips to the rotating table.
        #expect(resolved.document.rules?.contains(where: { $0.id == "BRG-C.1" }) == true)
        #expect(resolved.document.end?.when?.source == "match.dealsPlayed == 4")
        // Provenance records each override with the overlay as source.
        let vulnerable = resolved.provenance["/defs/vulnerable(t: team) -> bool"]
        #expect(vulnerable?.role == .variant)
        #expect(vulnerable?.sourceId == "contract-bridge.chicago")
        #expect(vulnerable?.note?.contains("dealer side") == true)
        #expect(resolved.provenance["/vars/dealsPlayed"]?.role == .variant)
        #expect(resolved.provenance["/options/byId/passOut/default"]?.role == .variant)
        #expect(resolved.provenance["/end"]?.role == .variant)
        // The passOut default changed.
        let passOut = resolved.document.options?.first(where: { $0.id == "passOut" })
        #expect(passOut?.defaultValue == .string("redealSameDealer"))
    }

    @Test func houseOptionsResolveOntoHearts() throws {
        let resolved = try Resolver.resolve(base: heartsBase(), house: houseOverlay())
        #expect(resolvedOption(resolved, "jackOfDiamonds") == .bool(true))
        #expect(resolvedOption(resolved, "passSchedule") == .string("leftRightAcross"))
        #expect(resolvedOption(resolved, "target") == .int(50))
        #expect(resolved.provenance["/options/byId/jackOfDiamonds/default"]?.role == .house)
        #expect(resolved.provenance["/options/byId/target/default"]?.sourceId == "house.mahler.hearts-grandma")
    }

    // MARK: Hash stability and identity

    @Test func hashIsStableAcrossRuns() throws {
        let a = try Resolver.resolve(base: rubberBase(), variant: chicagoOverlay())
        let b = try Resolver.resolve(base: rubberBase(), variant: chicagoOverlay())
        #expect(a.hash == b.hash)
    }

    @Test func overlayChangesTheHash() throws {
        let base = try Resolver.resolve(base: rubberBase())
        let chicago = try Resolver.resolve(base: rubberBase(), variant: chicagoOverlay())
        #expect(base.hash != chicago.hash)
    }

    @Test func hashIsOrderIndependentOverKeyOrder() throws {
        // The synthetic doc builds `format` first; the same document with a
        // different insertion order must hash identically.
        let base = try syntheticBase()
        var reordered = base.json
        guard case .object(var fields) = reordered else { return }
        if let name = fields.first(where: { $0.key == "name" }) {
            fields.removeAll { $0.key == "name" }
            fields.append(name)
        }
        reordered = .object(fields)
        let doc = try RulesetDocument(json: reordered, path: "$")
        #expect(Resolver.canonicalHash(of: base) == Resolver.canonicalHash(of: doc))
    }

    // MARK: Table options (§8.4)

    @Test func tableOptionsWriteValueAndProvenance() throws {
        let resolved = try Resolver.resolve(
            base: try syntheticBase(),
            tableOptions: ["target": .int(50), "flag": .bool(true)])
        #expect(resolvedOption(resolved, "target") == .int(50))
        #expect(resolvedOption(resolved, "flag") == .bool(true))
        #expect(resolved.provenance["/options/byId/target/value"]?.role == .table)
        #expect(resolved.provenance["/options/byId/flag/value"]?.role == .table)
    }

    @Test func everyOptionCarriesAResolvedValue() throws {
        let resolved = try Resolver.resolve(base: rubberBase())
        for option in resolved.document.options ?? [] {
            #expect(option.value == option.defaultValue, "option \(option.id) has no resolved value")
        }
    }

    @Test func unknownTableOptionFails() throws {
        #expect(throws: ResolveError.self) {
            _ = try Resolver.resolve(base: rubberBase(), tableOptions: ["nope": .bool(true)])
        }
    }

    @Test func lockedTableOptionFails() throws {
        let base = try syntheticBase(lockedOption: true)
        #expect(throws: ResolveError.self) {
            _ = try Resolver.resolve(base: base, tableOptions: ["lockedOpt": .bool(false)])
        }
    }

    // MARK: Patch ops

    @Test func replaceAddAppendRemoveWork() throws {
        let base = try syntheticBase()
        let ov = try overlay(patch: [
            ("replace", "/options/byId/target/default", .int(200)),
            ("add", "/vars/bonus", .object([JSONField(key: "scope", value: .string("round")),
                                           JSONField(key: "type", value: .string("int")),
                                           JSONField(key: "initial", value: .string("0"))])),
            ("append", "/rules", .object([JSONField(key: "id", value: .string("R.9")),
                                          JSONField(key: "text", value: .object([JSONField(key: "default", value: .string("Nine"))]))])),
            ("remove", "/options/byId/flag", nil),
        ])
        let resolved = try Resolver.resolve(base: base, variant: ov)
        #expect(resolvedOption(resolved, "target") == .int(200))
        #expect(resolved.document.vars?.first(where: { $0.key == "bonus" }) != nil)
        #expect(resolved.document.rules?.contains(where: { $0.id == "R.9" }) == true)
        #expect(resolved.document.options?.contains(where: { $0.id == "flag" }) == false)
        #expect(resolved.provenance["/options/byId/target/default"]?.role == .variant)
        #expect(resolved.provenance["/vars/bonus"]?.role == .variant)
        #expect(resolved.provenance["/rules"]?.role == .variant)
    }

    @Test func numericIndexIsRejected() throws {
        let base = try syntheticBase()
        let ov = try overlay(patch: [("replace", "/rules/0", nil)])
        #expect(throws: ResolveError.self) {
            _ = try Resolver.resolve(base: base, variant: ov)
        }
        let ov2 = try overlay(patch: [("replace", "/rules/0/text", .object([JSONField(key: "default", value: .string("x"))]))])
        #expect(throws: ResolveError.self) {
            _ = try Resolver.resolve(base: base, variant: ov2)
        }
    }

    @Test func unknownByIdTargetFails() throws {
        let base = try syntheticBase()
        let ov = try overlay(patch: [("replace", "/options/byId/nope/default", .int(1))])
        do {
            _ = try Resolver.resolve(base: base, variant: ov)
            Issue.record("expected unknownId failure")
        } catch {
            guard case .unknownId(let id) = error.kind else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(id == "nope")
        }
    }

    @Test func missingTargetsFail() throws {
        let base = try syntheticBase()
        let replaceMissing = try overlay(patch: [("replace", "/vars/ghost", .int(1))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: replaceMissing) }
        let removeMissing = try overlay(patch: [("remove", "/vars/ghost", nil)])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: removeMissing) }
        let addExisting = try overlay(patch: [("add", "/vars/counter", .int(1))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: addExisting) }
        let appendNonArray = try overlay(patch: [("append", "/format", .string("x"))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: appendNonArray) }
    }

    @Test func malformedPointerFails() throws {
        let base = try syntheticBase()
        let noSlash = try overlay(patch: [("replace", "format", .string("x"))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: noSlash) }
        let scalarDescent = try overlay(patch: [("replace", "/format/sub", .string("x"))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: scalarDescent) }
        let removeWithValue = try overlay(patch: [("remove", "/vars/counter", .int(1))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: removeWithValue) }
    }

    // MARK: Locking (§8.2 constraint 3)

    @Test func lockedOptionRejectsOverlayAndTable() throws {
        let base = try syntheticBase(lockedOption: true)
        let ov = try overlay(patch: [("replace", "/options/byId/lockedOpt/default", .bool(false))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: ov) }
        let wholeOption = try overlay(patch: [("replace", "/options/byId/lockedOpt", .null)])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: wholeOption) }
        // Replacing the whole options array would clobber the locked option.
        let wholeArray = try overlay(patch: [("replace", "/options", .array([]))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: wholeArray) }
    }

    @Test func lockedRuleRejectsPatch() throws {
        let base = try syntheticBase(lockedRule: true)
        let ov = try overlay(patch: [("replace", "/rules/byId/R.2/text", .object([JSONField(key: "default", value: .string("Changed"))]))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: ov) }
        // Untouched neighbors still patch fine.
        let ok = try overlay(patch: [("replace", "/rules/byId/R.1/text", .object([JSONField(key: "default", value: .string("One-ish"))]))])
        let resolved = try Resolver.resolve(base: base, variant: ok)
        #expect(resolved.document.rules?.first(where: { $0.id == "R.1" })?.text.defaultString == "One-ish")
    }

    // MARK: Protected fields (§8.2 constraint 2)

    @Test func protectedFieldsAreRejected() throws {
        let base = try syntheticBase()
        for path in ["/format", "/id", "/game", "/kind"] {
            let ov = try overlay(patch: [("replace", path, .string("nope"))])
            do {
                _ = try Resolver.resolve(base: base, variant: ov)
                Issue.record("expected protectedField failure for \(path)")
            } catch {
                guard case .protectedField = error.kind else {
                    Issue.record("wrong error for \(path): \(error)")
                    continue
                }
            }
        }
    }

    // MARK: Same-path conflicts (§8.2 constraint 5)

    @Test func conflictingPatchesInOneOverlayFail() throws {
        let base = try syntheticBase()
        let ov = try overlay(patch: [
            ("replace", "/vars/counter", .int(1)),
            ("replace", "/vars/counter", .int(2)),
        ])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: ov) }
    }

    @Test func optionsShorthandConflictsWithPatch() throws {
        let base = try syntheticBase()
        let ov = try overlay(
            patch: [("replace", "/options/byId/target/default", .int(1))],
            options: .object([JSONField(key: "target", value: .int(2))]))
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: ov) }
    }

    // MARK: Compatibility (§8.2 constraint 1)

    @Test func extendsMismatchFails() throws {
        let base = try syntheticBase()
        let ov = try overlay(extends: "other.game@^1.0")
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: ov) }
    }

    @Test func versionRangeEnforced() throws {
        let base = try syntheticBase()
        let newer = try overlay(extends: "test.game@^2.0")
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: newer) }
        let exact = try overlay(extends: "test.game@1.0.0")
        _ = try Resolver.resolve(base: base, variant: exact)
        let caretSameMajor = try overlay(extends: "test.game@^1.5")
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: caretSameMajor) }
        let badRange = try overlay(extends: "test.game@banana")
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: badRange) }
        let noAt = try overlay(extends: "test.game")
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: noAt) }
    }

    @Test func realOverlaysPassCompatibility() throws {
        let rubber = try rubberBase()
        let chicago = try chicagoOverlay()
        let resolved = try Resolver.resolve(base: rubber, variant: chicago)
        #expect(resolved.document.id == rubber.id)
        let hearts = try heartsBase()
        _ = try Resolver.resolve(base: hearts, house: houseOverlay())
    }

    // MARK: Layer ordering (§8.3)

    @Test func layersApplyInOrderVariantThenHouse() throws {
        // Both overlays touch the same option's default — only via distinct
        // overlays, which is legal; the later layer wins.
        let base = try syntheticBase()
        let variant = try overlay(patch: [("replace", "/options/byId/target/default", .int(10))], id: "v")
        let house = try overlay(patch: [("replace", "/options/byId/target/default", .int(20))], id: "h")
        let resolved = try Resolver.resolve(base: base, variant: variant, house: house)
        #expect(resolvedOption(resolved, "target") == .int(20))
        #expect(resolved.provenance["/options/byId/target/default"]?.sourceId == "h")
    }

    @Test func houseCanOverrideVariant() throws {
        // Same arrangement through the real files is not possible (different
        // bases), so reuse the synthetic pair with different option paths.
        let base = try syntheticBase()
        let varBody: (String) -> JSON = { initial in
            .object([
                JSONField(key: "scope", value: .string("match")),
                JSONField(key: "type", value: .string("int")),
                JSONField(key: "initial", value: .string(initial)),
            ])
        }
        let variant = try overlay(patch: [("add", "/vars/extra", varBody("0"))], id: "v")
        let house = try overlay(patch: [("replace", "/vars/extra", varBody("1"))], id: "h", kind: "house")
        let resolved = try Resolver.resolve(base: base, variant: variant, house: house)
        #expect(resolved.provenance["/vars/extra"]?.sourceId == "h")
        #expect(resolved.provenance["/vars/extra"]?.role == .house)
    }

    // MARK: Re-decode (§8.2 constraint 6)

    @Test func patchWritingGarbageFailsDecode() throws {
        let base = try syntheticBase()
        // An int where an object must be: the final re-decode must refuse.
        let ov = try overlay(patch: [("replace", "/vars/counter", .int(3))])
        #expect(throws: ResolveError.self) { _ = try Resolver.resolve(base: base, variant: ov) }
    }

    // MARK: Rules diff (§8.5)

    @Test func rulesDiffChicagoVersusRubber() throws {
        let base = try Resolver.resolve(base: rubberBase())
        let chicago = try Resolver.resolve(base: rubberBase(), variant: chicagoOverlay())
        let lines = RulesDiff.diff(base, chicago)
        #expect(lines.contains { $0.contains("BRG-C.1") && $0.contains("added") })
        #expect(lines.contains { $0.contains("passOut") && $0.contains("redealSameDealer") })
        // Every line is deterministic under sorting.
        #expect(lines == lines.sorted())
        #expect(!lines.isEmpty)
    }

    @Test func rulesDiffOptionsVersusHouse() throws {
        let base = try Resolver.resolve(base: heartsBase())
        let house = try Resolver.resolve(base: heartsBase(), house: houseOverlay())
        let lines = RulesDiff.diff(base, house)
        #expect(lines.contains { $0.contains("jackOfDiamonds") && $0.contains("false → true") })
        #expect(lines.contains { $0.contains("target") && $0.contains("→ 50") })
    }

    @Test func rulesDiffIdenticalIsEmpty() throws {
        let a = try Resolver.resolve(base: rubberBase())
        let b = try Resolver.resolve(base: rubberBase())
        #expect(RulesDiff.diff(a, b).isEmpty)
    }
}
