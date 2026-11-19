@_spi(Tools) import RulesetKit
import XCTest

// P2.9: the exported JSON Schemas stay honest against the documents they
// describe. The schemas are generated from the decoder shapes, so the drift
// these tests guard against is a changed `RulesetDocument` field list, a
// changed draft, or a schema that no longer parses.
final class SchemaExportTests: XCTestCase {
    private var repoRoot: URL {
        // Tests run from the package; the repository root holds docs/plan.
        // SchemaExportTests.swift is 5 components below the root:
        // Geist3/Packages/RulesetKit/Tests/RulesetKitTests/<file>.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        return dir
    }

    func testSchemasAreDraft202012() throws {
        let ruleset = SchemaExport.rulesetSchema()
        let lesson = SchemaExport.lessonSchema()
        XCTAssertEqual(
            ruleset["$schema"]?.stringValue,
            "https://json-schema.org/draft/2020-12/schema")
        XCTAssertEqual(
            lesson["$schema"]?.stringValue,
            "https://json-schema.org/draft/2020-12/schema")
    }

    func testRulesetSchemaMirrorsReferenceDocuments() throws {
        // Every top-level key the four reference rulesets actually carry must
        // appear in the schema's properties, and every schema-required key
        // must be present in each document (ARCHITECTURE §5.2).
        let schema = SchemaExport.rulesetSchema()
        let properties = Set(schema["properties"]?.fields?.map(\.key) ?? [])
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        XCTAssertGreaterThan(properties.count, 20)
        XCTAssertFalse(required.isEmpty)

        let dir = repoRoot.appendingPathComponent("docs/plan/rulesets")
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".ruleset.json") }
        XCTAssertEqual(files.count, 4, "expected the four reference rulesets")
        for file in files {
            let json = try JSONParser.parse(try String(contentsOf: file, encoding: .utf8))
            let keys = Set(json.fields?.map(\.key) ?? [])
            XCTAssertFalse(keys.isEmpty, file.lastPathComponent)
            XCTAssert(
                keys.isSubset(of: properties),
                "\(file.lastPathComponent) carries keys outside the schema: \(keys.subtracting(properties).sorted())")
            XCTAssert(
                required.isSubset(of: keys),
                "\(file.lastPathComponent) is missing schema-required keys: \(required.subtracting(keys).sorted())")
        }
    }

    func testExportedSchemasSerializeRoundTrip() throws {
        for schema in [SchemaExport.rulesetSchema(), SchemaExport.lessonSchema()] {
            let text = schema.prettyString()
            let reparsed = try JSONParser.parse(text)
            XCTAssertEqual(reparsed, schema)
            // Third-party validators receive plain JSON; make sure the export
            // survives a lossless JSON round-trip too.
            let data = try XCTUnwrap(text.data(using: .utf8))
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            XCTAssertNotNil(object)
        }
    }
}
