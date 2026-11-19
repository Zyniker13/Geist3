// ResolverTests+Patches.swift — patch-op acceptance tests (replace/add/append/
// remove, index rejection, target and pointer failures), split out of the main
// suite to stay within the type_body_length lint limit.

import Foundation
import Testing

@testable import RulesetKit

extension ResolverTests {
    // MARK: Patch ops

    @Test func replaceAddAppendRemoveWork() throws {
        let base = try syntheticBase()
        let ov = try overlay(patch: [
            ("replace", "/options/byId/target/default", .int(200)),
            (
                "add", "/vars/bonus",
                .object([
                    JSONField(key: "scope", value: .string("round")),
                    JSONField(key: "type", value: .string("int")),
                    JSONField(key: "initial", value: .string("0")),
                ])
            ),
            (
                "append", "/rules",
                .object([
                    JSONField(key: "id", value: .string("R.9")),
                    JSONField(key: "text", value: .object([JSONField(key: "default", value: .string("Nine"))])),
                ])
            ),
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
        let ov2 = try overlay(patch: [
            ("replace", "/rules/0/text", .object([JSONField(key: "default", value: .string("x"))]))
        ])
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

}
