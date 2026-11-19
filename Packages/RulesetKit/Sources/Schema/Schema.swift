// Schema layer for rulesets and overlays.
//
// Public surface (P2.5): RulesetDocument, Phase, PhaseParams, the mechanic
// params structs, OverlayDocument, PatchOp, and the JSON tree they round-trip
// through. Losslessness contract: decode → encode → decode yields an
// `==`-identical document, and unknown keys are preserved verbatim in each
// shapes are closed: unknown keys throw `SchemaError` during decode.

import Foundation

// MARK: - Phase (§5.2)

/// One phase of the game loop. `params` is mechanic-shaped and decoded
/// through `PhaseParams`; unknown mechanics keep their params verbatim
/// (`.unknown`), so the document still round-trips.
public struct Phase: Equatable, Sendable, JSONCodable {
    public var id: String
    public var mechanic: String
    public var params: PhaseParams?
    public var when: Expr?
    public var rule: String?
    public var before: [Effect]?
    public var after: [Effect]?
    public var next: Expr?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        id = try reader.string("id")
        mechanic = try reader.string("mechanic")
        if let paramsJSON = reader.optionalValue("params") {
            params = try PhaseParams(
                json: paramsJSON, mechanic: mechanic, path: reader.childPath("params"))
        } else {
            params = nil
        }
        when = try reader.optionalDecoded("when")
        rule = try reader.optionalString("rule")
        before = try reader.optionalArray("before")
        after = try reader.optionalArray("after")
        next = try reader.optionalDecoded("next")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("id", .string(id)),
            ("mechanic", .string(mechanic)),
        ]
        if let params { pairs.append(("params", params.json)) }
        if let when { pairs.append(("when", when.json)) }
        if let rule { pairs.append(("rule", .string(rule))) }
        if let before { pairs.append(("before", .array(before.map { $0.json }))) }
        if let after { pairs.append(("after", .array(after.map { $0.json }))) }
        if let next { pairs.append(("next", next.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - Ruleset document (§5.1)

/// A full ruleset document. Sections are optional here so partial documents
/// can be decoded for inspection; the validator (P2.7) enforces which
/// sections a `base` ruleset must carry.
public struct RulesetDocument: Equatable, Sendable, JSONCodable {
    public var format: String
    public var id: String
    public var game: String
    public var kind: String
    public var version: String
    public var engine: String?
    public var name: Text
    public var summary: Text?
    public var description: Text?
    public var author: AuthorRef?
    public var classification: Classification?
    public var sources: [SourceRef]?
    public var players: PlayersSpec?
    public var deck: DeckSpec?
    public var orders: [JSONField]?
    public var options: [OptionDecl]?
    public var rules: [RuleDecl]?
    public var zones: [ZoneDecl]?
    public var vars: [JSONField]?
    public var defs: [JSONField]?
    public var setup: SetupSpec?
    public var phases: [Phase]?
    public var end: EndDecl?
    public var display: DisplayHints?
    public var ai: AIHints?
    public var teaching: TeachingHints?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        format = try reader.string("format")
        id = try reader.string("id")
        game = try reader.string("game")
        kind = try reader.string("kind")
        version = try reader.string("version")
        engine = try reader.optionalString("engine")
        name = try reader.decoded("name")
        summary = try reader.optionalDecoded("summary")
        description = try reader.optionalDecoded("description")
        author = try reader.optionalDecoded("author")
        classification = try reader.optionalDecoded("classification")
        sources = try reader.optionalArray("sources")
        players = try reader.optionalDecoded("players")
        deck = try reader.optionalDecoded("deck")
        orders = try reader.optionalKeyedFields("orders")
        options = try reader.optionalArray("options")
        rules = try reader.optionalArray("rules")
        zones = try reader.optionalArray("zones")
        vars = try reader.optionalKeyedFields("vars")
        // Each vars entry must be a well-formed VarDecl: garbage written by a
        // patch must fail the final re-decode loudly (§8.2 constraint 6).
        if let vars {
            for field in vars {
                _ = try VarDecl(json: field.value, path: "vars.\(field.key)")
            }
        }
        defs = try reader.optionalKeyedFields("defs")
        setup = try reader.optionalDecoded("setup")
        phases = try reader.optionalArray("phases")
        end = try reader.optionalDecoded("end")
        display = try reader.optionalDecoded("display")
        ai = try reader.optionalDecoded("ai")
        teaching = try reader.optionalDecoded("teaching")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("format", .string(format)),
            ("id", .string(id)),
            ("game", .string(game)),
            ("kind", .string(kind)),
            ("version", .string(version)),
        ]
        if let engine { pairs.append(("engine", .string(engine))) }
        pairs.append(("name", name.json))
        if let summary { pairs.append(("summary", summary.json)) }
        if let description { pairs.append(("description", description.json)) }
        if let author { pairs.append(("author", author.json)) }
        if let classification { pairs.append(("classification", classification.json)) }
        if let sources { pairs.append(("sources", .array(sources.map { $0.json }))) }
        if let players { pairs.append(("players", players.json)) }
        if let deck { pairs.append(("deck", deck.json)) }
        if let orders { pairs.append(("orders", .object(orders))) }
        if let options { pairs.append(("options", .array(options.map { $0.json }))) }
        if let rules { pairs.append(("rules", .array(rules.map { $0.json }))) }
        if let zones { pairs.append(("zones", .array(zones.map { $0.json }))) }
        if let vars { pairs.append(("vars", .object(vars))) }
        if let defs { pairs.append(("defs", .object(defs))) }
        if let setup { pairs.append(("setup", setup.json)) }
        if let phases { pairs.append(("phases", .array(phases.map { $0.json }))) }
        if let end { pairs.append(("end", end.json)) }
        if let display { pairs.append(("display", display.json)) }
        if let ai { pairs.append(("ai", ai.json)) }
        if let teaching { pairs.append(("teaching", teaching.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - Overlay document (§8.1)

/// An overlay document: a named patch bundle applied to a base ruleset.
/// `options` is the tier-1 surface (a keyed object of raw values); deeper
/// changes go through `patch` operations.
public struct OverlayDocument: Equatable, Sendable, JSONCodable {
    public var format: String
    public var id: String
    public var kind: String
    public var extends: String
    public var version: String
    public var author: AuthorRef?
    public var name: Text?
    public var description: Text?
    public var options: [JSONField]?
    public var sources: [SourceRef]?
    public var provenance: Provenance?
    public var patch: [PatchOp]

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        format = try reader.string("format")
        id = try reader.string("id")
        kind = try reader.string("kind")
        extends = try reader.string("extends")
        version = try reader.string("version")
        author = try reader.optionalDecoded("author")
        name = try reader.optionalDecoded("name")
        description = try reader.optionalDecoded("description")
        options = try reader.optionalKeyedFields("options")
        sources = try reader.optionalArray("sources")
        provenance = try reader.optionalDecoded("provenance")
        patch = try reader.array("patch")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("format", .string(format)),
            ("id", .string(id)),
            ("kind", .string(kind)),
            ("extends", .string(extends)),
            ("version", .string(version)),
        ]
        if let author { pairs.append(("author", author.json)) }
        if let name { pairs.append(("name", name.json)) }
        if let description { pairs.append(("description", description.json)) }
        if let options { pairs.append(("options", .object(options))) }
        if let sources { pairs.append(("sources", .array(sources.map { $0.json }))) }
        if let provenance { pairs.append(("provenance", provenance.json)) }
        pairs.append(("patch", .array(patch.map { $0.json })))
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// Who produced an overlay. `displayName` only; no accounts, no emails.
public struct AuthorRef: Equatable, Sendable, JSONCodable {
    public var displayName: String

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        displayName = try reader.string("displayName")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        let pairs: [(String, JSON)] = [("displayName", .string(displayName))]
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// How an overlay came to be: which tool produced it and at what tier.
public struct Provenance: Equatable, Sendable, JSONCodable {
    public var createdWith: String
    public var tier: Int?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        createdWith = try reader.string("createdWith")
        tier = try reader.optionalInt("tier")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("createdWith", .string(createdWith))]
        if let tier { pairs.append(("tier", .int(tier))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// One overlay patch operation: `{op, path, value?, note?}`. `path` is a
/// JSON Pointer into the resolved ruleset document; `value` is absent for
/// removal-style ops. The op vocabulary itself is validated in P2.7.
public struct PatchOp: Equatable, Sendable, JSONCodable {
    /// The op vocabulary (§8.3): `replace` and `add` place a value, `append`
    /// adds one to a list, `remove` deletes the target.
    public static let knownOps = ["replace", "add", "append", "remove"]

    public var op: String
    public var path: String
    public var value: JSON?
    public var note: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        op = try reader.string("op")
        self.path = try reader.string("path")
        value = reader.optionalValue("value")
        note = try reader.optionalString("note")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("op", .string(op)),
            ("path", .string(path)),
        ]
        if let value { pairs.append(("value", value)) }
        if let note { pairs.append(("note", .string(note))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - FieldReader additions

extension FieldReader {
    /// Optional keyed object of raw JSON values, preserved verbatim (the
    /// optional counterpart of the non-generic `keyedFields`).
    mutating func optionalKeyedFields(_ key: String) throws(SchemaError) -> [JSONField]? {
        guard let raw = optionalValue(key) else { return nil }
        guard let fields = raw.fields else {
            throw SchemaError.wrongType(expected: "object", path: childPath(key))
        }
        return fields
    }
}

// MARK: - Loader

/// Entry points for decoding and re-encoding schema documents.
public enum Schema {
    public static let rulesetFormat = "parlor.ruleset/1"
    public static let overlayFormat = "parlor.overlay/1"

    /// Parse text and check the format marker, then decode as a ruleset.
    public static func decodeRuleset(_ text: String) throws(SchemaError) -> RulesetDocument {
        let tree = try JSONParser.parse(text)
        try checkFormat(tree, expected: rulesetFormat)
        return try RulesetDocument(json: tree, path: "$")
    }

    /// Parse text and check the format marker, then decode as an overlay.
    public static func decodeOverlay(_ text: String) throws(SchemaError) -> OverlayDocument {
        let tree = try JSONParser.parse(text)
        try checkFormat(tree, expected: overlayFormat)
        return try OverlayDocument(json: tree, path: "$")
    }

    private static func checkFormat(_ tree: JSON, expected: String) throws(SchemaError) {
        let actual: String
        if let value = tree["format"] {
            actual = value.stringValue ?? "(non-string)"
        } else {
            actual = "missing"
        }
        guard actual == expected else {
            throw SchemaError.formatMismatch(expected: expected, actual: actual)
        }
    }

    /// Read a ruleset file, decode, re-encode, decode again.
    public static func roundTrip(_ doc: RulesetDocument) throws(SchemaError) -> RulesetDocument {
        try decodeRuleset(encode(doc))
    }

    /// Read an overlay file, decode, re-encode, decode again.
    public static func roundTrip(_ doc: OverlayDocument) throws(SchemaError) -> OverlayDocument {
        try decodeOverlay(encode(doc))
    }

    /// Pretty text in the repository's two-space style (§5.1 key order).
    public static func encode(_ doc: RulesetDocument) -> String {
        doc.json.prettyString()
    }

    public static func encode(_ doc: OverlayDocument) -> String {
        doc.json.prettyString()
    }

    /// Canonical text: sorted keys, normalized numbers, compact spacing.
    public static func canonical(_ doc: RulesetDocument) -> String {
        doc.json.canonicalString()
    }

    public static func canonical(_ doc: OverlayDocument) -> String {
        doc.json.canonicalString()
    }

    private static func decode<T>(
        _ text: String,
        expecting expectedFormat: String,
        build: (JSON) throws(SchemaError) -> T
    ) throws(SchemaError) -> T {
        let tree = try JSONParser.parse(text)
        let actual: String
        if let value = tree["format"] {
            actual = value.stringValue ?? "(non-string)"
        } else {
            actual = "missing"
        }
        guard actual == expectedFormat else {
            throw SchemaError.formatMismatch(expected: expectedFormat, actual: actual)
        }
        return try build(tree)
    }
}
