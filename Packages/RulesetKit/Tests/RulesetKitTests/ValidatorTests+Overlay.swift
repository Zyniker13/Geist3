// P2.7: overlay validation. Overlays route through stage B–C plus the
// overlay-local checks (kind, extends grammar, version, patch ops, pointer
// syntax, duplicate paths). The two reference overlays must validate clean;
// the negative cases here mirror what the resolver would reject at resolve
// time, but caught earlier and in plain language.

import Testing

@testable import RulesetKit

struct ValidatorOverlayTests {
    static let overlayFiles = [
        "contract-bridge.chicago.variant.json",
        "hearts.house-example.house.json",
    ]

    func read(_ relative: String) throws -> String {
        try String(
            contentsOf: ValidatorTests.repoRoot.appendingPathComponent(relative),
            encoding: .utf8)
    }

    @Test func referenceOverlaysValidateClean() throws {
        for name in Self.overlayFiles {
            let text = try read("docs/plan/rulesets/\(name)")
            let report = RulesetValidator.validate(
                text: text, byteCount: text.utf8.count)
            #expect(
                report.errors.isEmpty,
                "\(name) failed validation:\n\(report.errors.map { "\($0)" }.joined(separator: "\n"))")
        }
    }

    // MARK: helpers

    private func validateOverlay(_ body: String) throws -> ValidationReport {
        let text = #"""
            {
                "format": "parlor.overlay/1",
                "id": "test.variant",
                "kind": "variant",
                "extends": "hearts.standard@^1.0",
                "version": "1.0.0",
                "patch": [\#(body)]
            }
            """#
        return RulesetValidator.validate(text: text, byteCount: text.utf8.count)
    }

    private func expectCode(
        _ report: ValidationReport, _ code: String, _ pointer: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let matching = report.errors.filter { $0.code == code }
        let detail = report.errors.map { "\($0)" }.joined(separator: " | ")
        #expect(matching.count == 1, "expected exactly one \(code), got \(detail)")
        #expect(matching.first?.pointer == pointer, "expected the issue at \(pointer)")
    }

    // MARK: negative cases

    @Test func unknownKindIsRejected() {
        let text = """
            {
                "format": "parlor.overlay/1",
                "id": "test.variant",
                "kind": "plugin",
                "extends": "hearts.standard@^1.0",
                "version": "1.0.0",
                "patch": []
            }
            """
        let report = RulesetValidator.validate(text: text)
        expectCode(report, "schema/unknown-value", "/kind")
    }

    @Test func badVersionIsRejected() {
        let text = """
            {
                "format": "parlor.overlay/1",
                "id": "test.variant",
                "kind": "variant",
                "extends": "hearts.standard@^1.0",
                "version": "1.0.0.0",
                "patch": []
            }
            """
        let report = RulesetValidator.validate(text: text)
        expectCode(report, "schema/bad-version", "/version")
    }

    @Test func extendsWithoutAtIsRejected() {
        let text = """
            {
                "format": "parlor.overlay/1",
                "id": "test.variant",
                "kind": "variant",
                "extends": "hearts.standard",
                "version": "1.0.0",
                "patch": []
            }
            """
        let report = RulesetValidator.validate(text: text)
        expectCode(report, "reference/bad-extends", "/extends")
    }

    @Test func extendsWithBadRangeIsRejected() {
        let text = """
            {
                "format": "parlor.overlay/1",
                "id": "test.variant",
                "kind": "variant",
                "extends": "hearts.standard@latest",
                "version": "1.0.0",
                "patch": []
            }
            """
        let report = RulesetValidator.validate(text: text)
        expectCode(report, "reference/bad-extends", "/extends")
    }

    @Test func unknownPatchOpIsRejected() throws {
        let report = try validateOverlay(
            #"{"op": "move", "path": "/deck/rule", "value": null}"#)
        expectCode(report, "schema/unknown-value", "/patch/0/op")
    }

    @Test func removeOpWithValueIsRejected() throws {
        let report = try validateOverlay(
            #"{"op": "remove", "path": "/deck/rule", "value": 1}"#)
        expectCode(report, "schema/patch-op-value", "/patch/0")
    }

    @Test func replaceOpWithoutValueIsRejected() throws {
        let report = try validateOverlay(
            #"{"op": "replace", "path": "/deck/rule"}"#)
        expectCode(report, "schema/patch-op-value", "/patch/0")
    }

    @Test func pointerWithoutSlashIsRejected() throws {
        let report = try validateOverlay(
            #"{"op": "replace", "path": "deck/rule", "value": 2}"#)
        expectCode(report, "reference/bad-pointer", "/patch/0/path")
    }

    @Test func duplicatePatchPathsAreRejected() throws {
        let report = try validateOverlay(
            #"""
            {"op": "replace", "path": "/deck/rule", "value": 2},
            {"op": "replace", "path": "/deck/rule", "value": 3}
            """#)
        expectCode(report, "reference/duplicate-patch", "/patch/1/path")
    }
}
