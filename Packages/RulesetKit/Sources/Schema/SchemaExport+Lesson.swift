// Lesson-schema half of the JSON Schema export (P2.9 / ARCHITECTURE §15.2),
// split from SchemaExport.swift to keep each type body small. The builder
// helpers live on SchemaExport as internal statics shared by both halves.

extension SchemaExport {
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
            ("text", shape(["default"], [("key", t("string")), ("default", t("string"))]))
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
