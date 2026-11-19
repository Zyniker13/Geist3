// JSON Schema export (P2.9 / ARCHITECTURE §5.2 line 195): a draft 2020-12
// structural mirror of the ruleset and lesson documents for editor tooling.
// The Swift validator stays authoritative — the schema carries structure and
// fixed vocabularies only (references, expressions, and mechanic parameters
// remain the validator's job). The exporter is generated from the decoder
// shapes in this module; `rules-cli schema --check` keeps the committed files
// in sync, and CI revalidates the reference rulesets against the schema.

@_spi(Tools)
public enum SchemaExport {
    // MARK: - Builder helpers

    private static func s(_ v: String) -> JSON { .string(v) }

    private static func obj(_ pairs: [(String, JSON)]) -> JSON {
        .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }

    private static func t(_ type: String) -> JSON { obj([("type", s(type))]) }

    private static func ref(_ name: String) -> JSON {
        obj([("$ref", s("#/$defs/\(name)"))])
    }

    private static func strArray(minItems: Int? = nil) -> JSON {
        var pairs = [("type", s("array")), ("items", t("string"))]
        if let minItems { pairs.append(("minItems", .int(minItems))) }
        return obj(pairs)
    }

    private static func enumOf(_ values: [String]) -> JSON {
        obj([("enum", .array(values.map { .string($0) }))])
    }

    /// One closed object shape: properties in declaration order, optional
    /// extras allowed by name, unknown keys rejected.
    private static func shape(
        _ required: [String],
        _ properties: [(String, JSON)]
    ) -> JSON {
        obj([
            ("type", s("object")),
            ("properties", obj(properties)),
            ("required", .array(required.map { .string($0) })),
            ("additionalProperties", .bool(false)),
        ])
    }

    // MARK: - Ruleset schema

    /// The `parlor.ruleset/1` structural schema (§5.2). Every field the four
    /// reference rulesets carry is required; `teaching` is optional (§5.2).
    public static func rulesetSchema() -> JSON {
        obj([
            ("$schema", s("https://json-schema.org/draft/2020-12/schema")),
            ("title", s("Parlor ruleset document")),
            (
                "description",
                s(
                    "Structural mirror of the parlor.ruleset/1 base document "
                        + "(ARCHITECTURE §5.2) for editor tooling. The Swift "
                        + "RulesetValidator is authoritative: references, "
                        + "expressions, mechanic parameters, and semantics are "
                        + "validated by `rules-cli validate`, not here.")
            ),
            ("type", s("object")),
            ("required", requiredRulesetFields()),
            ("properties", obj(rulesetProperties())),
            ("additionalProperties", .bool(false)),
            ("$defs", rulesetDefs()),
        ])
    }

    private static func requiredRulesetFields() -> JSON {
        .array(
            [
                "format", "id", "game", "kind", "version", "engine", "name",
                "summary", "classification", "sources", "players", "deck",
                "orders", "options", "rules", "zones", "vars", "defs",
                "setup", "phases", "end", "display", "ai",
            ].map { .string($0) })
    }

    private static func rulesetProperties() -> [(String, JSON)] {
        [
            ("format", obj([("const", s("parlor.ruleset/1"))])),
            ("id", obj([("type", s("string")), ("pattern", s("^[a-z][a-z0-9-]*\\.[a-z0-9][a-z0-9-]*$"))])),
            ("game", obj([("type", s("string")), ("pattern", s("^[a-z][a-z0-9-]*$"))])),
            ("kind", obj([("const", s("base"))])),
            ("version", obj([("type", s("string")), ("pattern", s("^\\d+\\.\\d+\\.\\d+$"))])),
            ("engine", obj([("type", s("string")), ("pattern", s("^>=\\d+\\.\\d+(\\.\\d+)?$"))])),
            ("name", ref("text")),
            ("summary", ref("text")),
            ("description", ref("text")),
            ("author", ref("authorRef")),
            ("classification", ref("classification")),
            ("sources", obj([("type", s("array")), ("items", ref("source")), ("minItems", .int(1))])),
            ("players", ref("playersSpec")),
            ("deck", ref("deckSpec")),
            ("orders", obj([("type", s("object")), ("additionalProperties", strArray(minItems: 1))])),
            ("options", obj([("type", s("array")), ("items", ref("optionDecl"))])),
            ("rules", obj([("type", s("array")), ("items", ref("ruleDecl"))])),
            ("zones", obj([("type", s("array")), ("items", ref("zoneDecl"))])),
            ("vars", obj([("type", s("object")), ("additionalProperties", ref("varDecl"))])),
            ("defs", obj([("type", s("object")), ("additionalProperties", obj([("type", s("string")), ("minLength", .int(1))]))])),
            ("setup", ref("setupSpec")),
            ("phases", obj([("type", s("array")), ("items", ref("phase"))])),
            ("end", ref("endDecl")),
            ("display", ref("displayHints")),
            ("ai", ref("aiHints")),
            ("teaching", ref("teachingHints")),
        ]
    }

    private static func rulesetDefs() -> JSON {
        obj(rulesetDefsMetadata() + rulesetDefsTables() + rulesetDefsPlay() + rulesetDefsEnd())
    }

    /// Text, author, classification, and source shapes.
    private static func rulesetDefsMetadata() -> [(String, JSON)] {
        [
            ("text", shape(["default"], [("key", t("string")), ("default", t("string"))])),
            ("authorRef", shape(["displayName"], [("displayName", t("string"))])),
            (
                "classification",
                shape(
                    ["pagat", "objective", "tags"],
                    [("pagat", t("string")), ("objective", t("string")), ("tags", strArray())])
            ),
            (
                "source",
                shape(
                    ["id", "title", "url", "role"],
                    [
                        ("id", t("string")),
                        ("title", t("string")),
                        ("url", t("string")),
                        ("role", enumOf(["primary", "official", "secondary", "context"])),
                        ("accessed", t("string")),
                    ])
            ),
        ]
    }

    /// Players, deck, options, and rule declarations.
    private static func rulesetDefsTables() -> [(String, JSON)] {
        [
            (
                "playersSpec",
                shape(
                    ["counts", "default", "teams"],
                    [
                        ("counts", obj([("type", s("array")), ("items", t("integer")), ("minItems", .int(1))])),
                        ("default", t("integer")),
                        ("teams", t("string")),
                        ("seatNames", strArray()),
                    ])
            ),
            (
                "deckSpec",
                shape(
                    [],
                    [
                        ("base", t("string")),
                        ("copies", obj([("type", s("integer")), ("minimum", .int(1))])),
                        ("remove", strArray()),
                        ("add", strArray()),
                        ("faces", t("string")),
                    ])
            ),
            (
                "optionDecl",
                shape(
                    ["id", "type", "default", "label", "rules"],
                    [
                        ("id", t("string")),
                        ("type", enumOf(["bool", "int", "enum"])),
                        ("default", obj([])),
                        ("min", t("integer")),
                        ("max", t("integer")),
                        ("values", obj([("type", s("array"))])),
                        ("label", ref("text")),
                        ("help", ref("text")),
                        ("rules", strArray()),
                        ("group", t("string")),
                        ("locked", t("boolean")),
                    ])
            ),
            (
                "ruleDecl",
                shape(
                    ["id", "text"],
                    [("id", t("string")), ("text", ref("text")), ("explain", ref("text")), ("locked", t("boolean"))])
            ),
        ]
    }

    /// Zones, variables, setup, and phases.
    private static func rulesetDefsPlay() -> [(String, JSON)] {
        [
            (
                "zoneDecl",
                shape(
                    ["id", "scope", "visibility"],
                    [
                        ("id", t("string")),
                        ("scope", enumOf(["seat", "team", "shared"])),
                        ("visibility", visibility()),
                        ("ordered", t("boolean")),
                        ("faceDown", t("boolean")),
                        ("sort", t("string")),
                        ("owner", t("string")),
                        ("capacity", t("integer")),
                    ])
            ),
            (
                "varDecl",
                shape(
                    ["scope", "type", "initial"],
                    [
                        ("scope", enumOf(["match", "deal", "seatMatch", "seatDeal", "teamMatch", "teamDeal"])),
                        ("type", t("string")),
                        ("initial", t("string")),
                    ])
            ),
            ("setupSpec", shape(["firstDealer", "dealerRotation"], [("firstDealer", t("string")), ("dealerRotation", t("string"))])),
            (
                "phase",
                shape(
                    ["id", "mechanic"],
                    [
                        ("id", t("string")),
                        ("mechanic", t("string")),
                        ("params", t("object")),
                        ("when", t("string")),
                        ("rule", t("string")),
                        ("before", obj([("type", s("array")), ("items", ref("effect"))])),
                        ("after", obj([("type", s("array")), ("items", ref("effect"))])),
                        ("next", t("string")),
                    ])
            ),
            ("effect", effect()),
        ]
    }

    /// End conditions and display/AI/teaching hints.
    private static func rulesetDefsEnd() -> [(String, JSON)] {
        [
            (
                "endDecl",
                shape(
                    ["check", "rank", "ties"],
                    [
                        ("check", enumOf(["afterDeal", "continuous", "afterTrick"])),
                        ("when", t("string")),
                        ("rank", t("string")),
                        ("ties", enumOf(["shared", "playOff", "impossible"])),
                        ("rule", t("string")),
                        ("matchEffects", obj([("type", s("array")), ("items", ref("effect"))])),
                        ("maxDeals", t("integer")),
                    ])
            ),
            (
                "displayHints",
                shape(
                    [],
                    [
                        ("layout", t("string")),
                        ("scoreSheet", obj([])),
                        ("showLastTrick", t("boolean")),
                        ("trickHistory", t("string")),
                        ("board", t("string")),
                        ("showContract", t("boolean")),
                        ("showVulnerability", t("boolean")),
                        ("showTrump", t("boolean")),
                        ("showMaker", t("boolean")),
                        ("auctionBox", t("boolean")),
                        ("announceCount", t("boolean")),
                    ])
            ),
            ("aiHints", shape(["profile", "params"], [("profile", t("string")), ("params", t("object"))])),
            ("teachingHints", shape(["lessons"], [("lessons", strArray(minItems: 1))])),
        ]
    }

    private static func visibility() -> JSON {
        obj([
            ("oneOf", .array([
                t("string"),
                shape(["seats"], [("seats", t("string"))]),
            ])),
        ])
    }

    /// The Effects vocabulary (§5.4) as a recursive oneOf over its eight
    /// keyed shapes, mirroring `Effect` decoding in Effects.swift. Payload
    /// shapes stay structural; expression syntax is the validator's job.
    private static func effect() -> JSON {
        let rule = ("rule", t("string"))
        func shapeNoAdd(_ required: [String], _ properties: [(String, JSON)]) -> JSON {
            shape(required, properties + [rule])
        }
        let variants: [JSON] = [
            shapeNoAdd(["set", "to"], [("set", t("string")), ("to", t("string"))]),
            shapeNoAdd(["add", "value"], [("add", t("string")), ("value", t("string")), ("event", t("string"))]),
            shapeNoAdd(["let", "be"], [("let", t("string")), ("be", t("string"))]),
            shapeNoAdd(
                ["if", "then"],
                [
                    ("if", t("string")),
                    ("then", obj([("type", s("array")), ("items", ref("effect"))])),
                    ("else", obj([("type", s("array")), ("items", ref("effect"))])),
                ]),
            shapeNoAdd(
                ["forEach", "do"],
                [("forEach", t("string")), ("do", obj([("type", s("array")), ("items", ref("effect"))]))]),
            shapeNoAdd(
                ["move"],
                [
                    (
                        "move",
                        shape(
                            ["from", "to"],
                            [
                                ("from", obj([])),
                                ("to", obj([])),
                                ("toSeat", t("string")),
                                ("toTeam", t("string")),
                                ("cards", obj([])),
                            ])
                    )
                ]),
            shapeNoAdd(
                ["reveal"],
                [
                    (
                        "reveal",
                        shape(["zone"], [("zone", t("string")), ("seat", t("string")), ("to", obj([]))])
                    )
                ]),
            shapeNoAdd(
                ["emit"],
                [("emit", t("string")), ("data", obj([("type", s("object")), ("additionalProperties", t("string"))]))]),
        ]
        return obj([("oneOf", .array(variants))])
    }

    // MARK: - Lesson schema

    /// The `parlor.lesson/1` structural schema (§15.2). Lessons gain their
    /// Swift type in P4; until then this mirrors the documented format, and
    /// the deal/expect semantics stay with the (future) Swift validator.
    public static func lessonSchema() -> JSON {
        obj([
            ("$schema", s("https://json-schema.org/draft/2020-12/schema")),
            ("title", s("Parlor lesson document")),
            (
                "description",
                s(
                    "Structural mirror of the parlor.lesson/1 document "
                        + "(ARCHITECTURE §15.2) for editor tooling. Deal "
                        + "composition and step semantics are validated by the "
                        + "Swift lesson validator, not here.")
            ),
            ("type", s("object")),
            (
                "required",
                .array(["format", "id", "game", "ruleset", "title", "seat", "steps", "complete"].map { .string($0) })
            ),
            (
                "properties",
                obj([
                    ("format", obj([("const", s("parlor.lesson/1"))])),
                    ("id", obj([("type", s("string")), ("pattern", s("^[a-z][a-z0-9-]*\\.[a-z0-9][a-z0-9-]*$"))])),
                    ("game", obj([("type", s("string")), ("pattern", s("^[a-z][a-z0-9-]*$"))])),
                    ("ruleset", t("string")),
                    ("title", ref("text")),
                    ("seat", obj([("type", s("integer")), ("minimum", .int(0))])),
                    ("options", t("object")),
                    ("deal", t("object")),
                    ("bots", t("object")),
                    ("steps", obj([("type", s("array")), ("items", lessonStep()), ("minItems", .int(1))])),
                    ("complete", lessonStep()),
                ])
            ),
            ("additionalProperties", .bool(false)),
            ("$defs", lessonDefs()),
        ])
    }

    private static func lessonDefs() -> JSON {
        obj([
            ("text", shape(["default"], [("key", t("string")), ("default", t("string"))])),
        ])
    }

    private static func lessonStep() -> JSON {
        obj([
            ("type", s("object")),
            (
                "properties",
                obj([
                    ("say", ref("text")),
                    ("expect", lessonExpect()),
                    ("highlight", strArray()),
                    ("auto", obj([("type", s("integer")), ("minimum", .int(0))])),
                    ("onOther", shape(["say"], [("say", ref("text"))])),
                ])
            ),
            (
                "anyOf",
                .array([
                    shape(["say"], []),
                    shape(["expect"], []),
                    shape(["auto"], []),
                ])
            ),
            ("additionalProperties", .bool(false)),
        ])
    }

    private static func lessonExpect() -> JSON {
        shape(
            ["intent"],
            [
                ("intent", t("string")),
                ("card", t("string")),
                ("anyOf", strArray()),
            ])
    }
}
