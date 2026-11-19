// Overlay validation (§8.1, §11.4 stage B–C for `parlor.overlay/1` documents).
//
// An overlay cannot be type-checked or reachability-analyzed on its own: its
// patches land inside a base ruleset, so stages D–F for the combined document
// run at resolve time and in simulation (§11.4 stage G). What a standalone
// check CAN prove: the document is within limits (B), decodes as an overlay
// (C), and its own references are well-formed — kind vocabulary, `extends`
// grammar, semver version, patch-op vocabulary and value shape, pointer
// syntax, and no two patches addressing the same path.

import CardExpr

extension RulesetValidator {
    /// Validates a `parlor.overlay/1` document through stages B and C plus
    /// the overlay-local reference checks. Cross-document checks (base
    /// identity, target existence, expression typing) happen when the overlay
    /// is resolved onto a base ruleset.
    static func validateOverlay(json: JSON, byteCount: Int?) -> ValidationReport {
        var issues: [ValidationIssue] = []
        issues += checkLimits(json: json, byteCount: byteCount)
        let overlay: OverlayDocument
        do {
            overlay = try OverlayDocument(json: json, path: "")
        } catch let error {
            issues.append(mapSchemaError(error))
            return ValidationReport(issues: issues)
        }
        issues += checkOverlayLocal(overlay)
        return ValidationReport(issues: issues)
    }

    /// Checks the overlay's own vocabulary, grammars, and patch list.
    private static func checkOverlayLocal(_ overlay: OverlayDocument) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if overlay.format != "parlor.overlay/1" {
            issues.append(
                ValidationIssue(
                    .error, "schema/format-mismatch", "/format",
                    "The format marker '\(overlay.format)' does not match this document kind; "
                        + "expected 'parlor.overlay/1'."))
        }
        if overlay.kind != "variant" && overlay.kind != "house" {
            issues.append(
                ValidationIssue(
                    .error, "schema/unknown-value", "/kind",
                    "'\(overlay.kind)' is not a kind. Use 'variant' or 'house'."))
        }
        if Resolver.parseVersion(overlay.version) == nil {
            issues.append(
                ValidationIssue(
                    .error, "schema/bad-version", "/version",
                    "The version must be numbers separated by dots (for example 1.0.0); "
                        + "missing parts read as zero, so '1.0' means 1.0.0."))
        }
        issues += checkExtends(overlay.extends, overlayId: overlay.id)
        issues += checkPatchOps(overlay)
        return issues
    }

    /// `extends` is `base-id@range` (§8.1): the base id must be non-empty and
    /// the range must parse as a semver with an optional `^` prefix.
    private static func checkExtends(_ marker: String, overlayId: String) -> [ValidationIssue] {
        guard let at = marker.firstIndex(of: "@") else {
            return [
                ValidationIssue(
                    .error, "reference/bad-extends", "/extends",
                    "The extends value must name a base and a version range, "
                        + "like 'base-id@^1.0'. '\(marker)' has no '@'.")
            ]
        }
        let baseId = String(marker[..<at])
        let range = String(marker[marker.index(after: at)...])
        if baseId.isEmpty {
            return [
                ValidationIssue(
                    .error, "reference/bad-extends", "/extends",
                    "The extends value names no base before the '@'.")
            ]
        }
        if Resolver.parseVersionRange(range) == nil {
            return [
                ValidationIssue(
                    .error, "reference/bad-extends", "/extends",
                    "The version range after the '@' must be a semver like '1.0.0' "
                        + "or '^1.0'. '\(range)' does not parse.")
            ]
        }
        return []
    }

    /// Checks each patch op's vocabulary, value shape, and pointer syntax,
    /// and rejects two ops addressing the same path (§8.3: a later patch on
    /// the same path would silently hide an earlier one). The tier-1
    /// `options` shorthand counts as a patch on its option's default.
    private static func checkPatchOps(_ overlay: OverlayDocument) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var seen: Set<String> = []

        if let options = overlay.options {
            for field in options {
                let path = "/options/byId/\(field.key)/default"
                if !seen.insert(path).inserted {
                    issues.append(
                        ValidationIssue(
                            .error, "reference/duplicate-patch", "/options",
                            "Two patches address \(path); the second would silently hide "
                                + "the first. Keep one."))
                }
            }
        }

        for (i, op) in overlay.patch.enumerated() {
            let at = "/patch/\(i)"
            if !PatchOp.knownOps.contains(op.op) {
                issues.append(
                    ValidationIssue(
                        .error, "schema/unknown-value", "\(at)/op",
                        "'\(op.op)' is not a patch op. Use one of: "
                            + PatchOp.knownOps.joined(separator: ", ") + "."))
            }
            if op.op == "remove" && op.value != nil {
                issues.append(
                    ValidationIssue(
                        .error, "schema/patch-op-value", at,
                        "A 'remove' op must not carry a value."))
            }
            if op.op != "remove" && op.value == nil {
                issues.append(
                    ValidationIssue(
                        .error, "schema/patch-op-value", at,
                        "A '\(op.op)' op needs a value to place at the target."))
            }
            do {
                let pointer = try Pointer.parse(op.path)
                if !seen.insert(pointer.normalized).inserted {
                    issues.append(
                        ValidationIssue(
                            .error, "reference/duplicate-patch", "\(at)/path",
                            "Two patches address \(op.path); the second would silently "
                                + "hide the first. Merge them into one op."))
                }
            } catch {
                issues.append(
                    ValidationIssue(
                        .error, "reference/bad-pointer", "\(at)/path",
                        "'\(op.path)' is not a JSON pointer. Patch paths start with '/' "
                            + "and address the base ruleset, like /phases/byId/play/when."))
            }
        }
        return issues
    }
}
