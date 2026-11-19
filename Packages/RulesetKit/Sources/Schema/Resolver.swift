// Resolver.swift — §8: layer resolution, ID-addressed patching, canonical
// hashing, provenance, and rules diffing (P2.6).
//
// Resolution is a pure function over lossless JSON trees: base document, an
// ordered list of overlays (variant, then house), and table options produce a
// `ResolvedRuleset` whose SHA-256 identifies the game everywhere. Arrays of
// declarations are addressed by element id (`/phases/byId/play`), never by
// numeric index, so overlays survive base edits that reorder arrays. Shapes
// are closed: unknown keys fail decode, and a patch that writes a malformed
// value fails the final re-decode loudly.

import CryptoKit
import Foundation

// MARK: - Errors

/// Why resolution refused. `message` is plain language; `path` (when present)
/// points at the offending location.
public struct ResolveError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The patch path is not a usable JSON Pointer.
        case badPointer
        /// A raw numeric array index was used; declaration arrays are
        /// id-addressed so overlays survive reordering.
        case numericIndex
        /// A `byId` segment named an id the array does not contain.
        case unknownId(String)
        /// `replace` or `remove` targeted a key that is absent.
        case missingTarget
        /// `add` targeted a key that already exists (arrays excepted).
        case alreadyExists
        /// `append` targeted something that is not an array.
        case notAnArray
        /// The patch touched `format`, `id`, `game`, or `kind`.
        case protectedField
        /// The target is, contains, or sits under a `locked: true` value.
        case lockedPath
        /// Two operations in one overlay address the same value.
        case conflictingPatches
        /// The overlay's `extends` names a different base.
        case baseMismatch
        /// The base's version is outside the overlay's `extends` range.
        case versionMismatch
        /// The `extends` string itself is malformed.
        case badExtends
        /// A table option names an option the ruleset does not declare.
        case unknownOption(String)
        /// The patched document no longer decodes (a patch wrote garbage).
        case schemaFailure(SchemaError)
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

// MARK: - Provenance

/// Which layer last set a value, for the "Rules in Effect" sheet.
public struct LayerRef: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case base
        case variant
        case house
        case table
    }

    public let role: Role
    /// The overlay's id, or `"table"` for table options.
    public let sourceId: String
    /// The patch's `note`, when it carried one.
    public let note: String?

    public init(role: Role, sourceId: String, note: String? = nil) {
        self.role = role
        self.sourceId = sourceId
        self.note = note
    }
}

// MARK: - Resolved ruleset

/// The outcome of resolution: a decoded document, its identity hash, and the
/// map of which layer set each changed value.
public struct ResolvedRuleset: Equatable, Sendable {
    public var document: RulesetDocument
    /// Lowercase hex SHA-256 of the canonical JSON (§8.1).
    public var hash: String
    /// Normalized pointer → the layer that set it. Only values an overlay or
    /// the table changed appear; everything else traces to the base.
    public var provenance: [String: LayerRef]

    public init(document: RulesetDocument, hash: String, provenance: [String: LayerRef]) {
        self.document = document
        self.hash = hash
        self.provenance = provenance
    }
}

// MARK: - Resolver

public enum Resolver {
    /// Resolve a base ruleset with an optional variant and house overlay
    /// (applied in that order) plus table options (§8.1–8.4).
    public static func resolve(
        base: RulesetDocument,
        variant: OverlayDocument? = nil,
        house: OverlayDocument? = nil,
        tableOptions: [String: JSON] = [:]
    ) throws(ResolveError) -> ResolvedRuleset {
        var overlays: [OverlayDocument] = []
        if let variant { overlays.append(variant) }
        if let house { overlays.append(house) }
        return try resolve(base: base, overlays: overlays, tableOptions: tableOptions)
    }

    /// Resolve with overlays applied in the given order (variant first).
    public static func resolve(
        base: RulesetDocument,
        overlays: [OverlayDocument],
        tableOptions: [String: JSON] = [:]
    ) throws(ResolveError) -> ResolvedRuleset {
        var tree = base.json
        var provenance: [String: LayerRef] = [:]

        for overlay in overlays {
            try checkCompatibility(base: base, overlay: overlay)
            let role: LayerRef.Role = overlay.kind == "variant" ? .variant : .house
            tree = try applyOverlay(tree, overlay, role: role, into: &provenance)
        }

        tree = try applyTableOptions(tree, tableOptions, into: &provenance)

        // The patched tree must still decode as a closed-shape ruleset; a
        // patch that wrote a malformed value fails here, loudly.
        let document: RulesetDocument
        do {
            document = try RulesetDocument(json: tree, path: "$")
        } catch {
            throw ResolveError(.schemaFailure(error), "patched document failed to decode: \(error)")
        }

        let hash = canonicalHash(of: tree)
        return ResolvedRuleset(document: document, hash: hash, provenance: provenance)
    }

    /// SHA-256 (lowercase hex) of the canonical JSON: sorted keys, normalized
    /// numbers, compact spacing. This hash identifies a game everywhere.
    public static func canonicalHash(of document: RulesetDocument) -> String {
        canonicalHash(of: document.json)
    }

    public static func canonicalHash(of tree: JSON) -> String {
        let canonical = tree.normalizedForCompare().canonicalString()
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Compatibility (§8.2 constraint 1)

    /// `extends` is `"base-id@^1.0"`: the id must match and the base version
    /// must satisfy the range (`^` pins the major; without `^`, exact).
    static func checkCompatibility(base: RulesetDocument, overlay: OverlayDocument) throws(ResolveError) {
        let marker = overlay.extends
        guard let at = marker.firstIndex(of: "@") else {
            throw ResolveError(.badExtends, "overlay \(overlay.id): extends is missing '@': \(marker)")
        }
        let baseId = String(marker[..<at])
        let range = String(marker[marker.index(after: at)...])
        guard baseId == base.id else {
            throw ResolveError(
                .baseMismatch,
                "overlay \(overlay.id) extends \(baseId), but the base is \(base.id)")
        }
        guard let (floor, pinned) = parseVersionRange(range) else {
            throw ResolveError(.badExtends, "overlay \(overlay.id): unparseable version range \(range)")
        }
        guard let baseVersion = parseVersion(base.version) else {
            throw ResolveError(
                .badExtends,
                "overlay \(overlay.id): base version \(base.version) is not semver")
        }
        if baseVersion.major != floor.major || baseVersion < floor {
            throw ResolveError(
                .versionMismatch,
                "overlay \(overlay.id) needs base \(range), found \(base.version)")
        }
        _ = pinned  // `^` already encoded in `floor`/major check
    }

    /// Returns the inclusive floor `(major, minor, patch)` and whether the
    /// range was written with `^` (major must match exactly either way).
    static func parseVersionRange(_ text: String) -> (VersionTriple, Bool)? {
        var body = text
        var caret = false
        if body.hasPrefix("^") {
            caret = true
            body.removeFirst()
        }
        guard let floor = parseVersion(body) else { return nil }
        return (floor, caret)
    }

    // MARK: Patch application

    static func applyOverlay(
        _ tree: JSON,
        _ overlay: OverlayDocument,
        role: LayerRef.Role,
        into provenance: inout [String: LayerRef]
    ) throws(ResolveError) -> JSON {
        var working = tree

        // Same-path conflict detection operates on normalized pointers so
        // `/phases/byId/play/when` and an escaped variant of the same pointer
        // collide, while distinct pointers never do.
        var seen: Set<String> = []

        // The tier-1 `options` shorthand: each entry is a `replace` on the
        // option's default.
        if let options = overlay.options {
            for field in options {
                let path = "/options/byId/\(field.key)/default"
                guard seen.insert(path).inserted else {
                    throw ResolveError(
                        .conflictingPatches,
                        "overlay \(overlay.id): two patches address \(path)")
                }
                working = try apply(
                    working,
                    step: Step(
                        name: "replace", path: path, value: field.value,
                        overlayId: overlay.id, note: nil),
                    role: role, into: &provenance)
            }
        }

        for op in overlay.patch {
            let path = try Pointer.parse(op.path).normalized
            guard seen.insert(path).inserted else {
                throw ResolveError(
                    .conflictingPatches,
                    "overlay \(overlay.id): two patches address \(path)")
            }
            working = try apply(
                working,
                step: Step(
                    name: op.op, path: path, value: op.value,
                    overlayId: overlay.id, note: op.note),
                role: role, into: &provenance)
        }
        return working
    }

    /// One patch step about to land on the working tree: what to do, where
    /// (`path` is normalized Pointer text), and which overlay it came from.
    struct Step {
        let name: String
        let path: String
        let value: JSON?
        let overlayId: String
        let note: String?
    }

    static func apply(
        _ tree: JSON, step: Step, role: LayerRef.Role,
        into provenance: inout [String: LayerRef]
    ) throws(ResolveError) -> JSON {
        let id = step.overlayId
        guard step.name == "replace" || step.name == "add" || step.name == "append" || step.name == "remove" else {
            throw ResolveError(.badPointer, "\(id): unknown op \(step.name) at \(step.path)")
        }
        guard step.name != "remove" || step.value == nil else {
            throw ResolveError(.badPointer, "\(id): remove carries a value at \(step.path)")
        }
        guard step.name == "remove" || step.value != nil else {
            throw ResolveError(.badPointer, "\(id): \(step.name) is missing its value at \(step.path)")
        }
        let pointer = try Pointer.parse(step.path)
        try checkProtected(pointer)
        try checkLocked(tree, pointer)
        let newValue = step.value ?? .null

        let applied = mutate(tree, pointer: pointer, op: step.name, value: newValue)
        guard case .mutated(let result) = applied else {
            throw ResolveError(applied.failureKind, applied.failureMessage ?? step.path)
        }
        provenance[pointer.normalized] = LayerRef(role: role, sourceId: step.overlayId, note: step.note)
        return result
    }

    /// Table options (§8.4): the host may set any unlocked declared option;
    /// the choice lands in `options[].value` and the provenance map.
    static func applyTableOptions(
        _ tree: JSON,
        _ tableOptions: [String: JSON],
        into provenance: inout [String: LayerRef]
    ) throws(ResolveError) -> JSON {
        var working = tree
        for (id, choice) in tableOptions.sorted(by: { $0.key < $1.key }) {
            let pointer = Pointer(segments: ["options", "byId", id, "value"])
            let valuePointer = Pointer(segments: ["options", "byId", id, "default"])
            // Existence and locking are checked against the option itself.
            guard
                case .mutated(let found) = mutate(
                    working, pointer: Pointer(segments: ["options", "byId", id]),
                    op: "replace", value: .null)
            else {
                throw ResolveError(.unknownOption(id), "table option \(id) is not declared")
            }
            _ = found
            try checkLocked(working, valuePointer)
            guard
                case .mutated(let withValue) = mutate(
                    working, pointer: pointer, op: "add", value: choice)
            else {
                // `value` already present (a prior table pass) — replace it.
                guard
                    case .mutated(let replaced) = mutate(
                        working, pointer: pointer, op: "replace", value: choice)
                else {
                    throw ResolveError(.badPointer, "table option \(id) could not be set")
                }
                working = replaced
                provenance[pointer.normalized] = LayerRef(role: .table, sourceId: "table", note: nil)
                continue
            }
            working = withValue
            provenance[pointer.normalized] = LayerRef(role: .table, sourceId: "table", note: nil)
        }

        // Every declared option gets its resolved `value`: the table's choice
        // where present, otherwise the (possibly overlay-patched) default.
        working = injectOptionValues(working, tableOptions)
        return working
    }

    /// Write `value` into each option object: the table's choice when it made
    /// one, otherwise the option's current default.
    static func injectOptionValues(_ tree: JSON, _ tableOptions: [String: JSON]) -> JSON {
        guard var fields = tree.fields else { return tree }
        guard let index = fields.firstIndex(where: { $0.key == "options" }),
            var options = fields[index].value.arrayValue
        else { return tree }
        for optionIndex in options.indices {
            guard var option = options[optionIndex].fields,
                let idField = option.first(where: { $0.key == "id" }),
                let id = idField.value.stringValue
            else { continue }
            let resolved = tableOptions[id] ?? option.first(where: { $0.key == "default" })?.value ?? .null
            if let existing = option.firstIndex(where: { $0.key == "value" }) {
                option[existing].value = resolved
            } else {
                option.append(JSONField(key: "value", value: resolved))
            }
            options[optionIndex] = .object(option)
        }
        fields[index].value = .array(options)
        return .object(fields)
    }

    // MARK: Pointer checks

    static func checkProtected(_ pointer: Pointer) throws(ResolveError) {
        let protected: Set<[String]> = [["format"], ["id"], ["game"], ["kind"]]
        if protected.contains(pointer.segments) {
            throw ResolveError(
                .protectedField,
                "overlays may not change \(pointer.normalized)")
        }
    }

    /// Collect the pointers of every object in the tree that carries
    /// `locked: true`, then reject a patch that targets such an object, sits
    /// inside one, or replaces a container holding one.
    static func checkLocked(_ tree: JSON, _ pointer: Pointer) throws(ResolveError) {
        var locked: [Pointer] = []
        collectLocked(tree, prefix: [], into: &locked)
        for lockedPointer in locked {
            if lockedPointer.segments == pointer.segments
                || isPrefix(lockedPointer.segments, pointer.segments)
                || isPrefix(pointer.segments, lockedPointer.segments)
            {
                throw ResolveError(
                    .lockedPath,
                    "\(pointer.normalized) is locked in the base ruleset")
            }
        }
    }

    static func collectLocked(_ value: JSON, prefix: [String], into out: inout [Pointer]) {
        switch value {
        case .object(let fields):
            if let flag = fields.first(where: { $0.key == "locked" }), flag.value == .bool(true) {
                out.append(Pointer(segments: prefix))
            }
            for field in fields {
                collectLocked(field.value, prefix: prefix + [field.key], into: &out)
            }
        case .array(let items):
            for (index, item) in items.enumerated() {
                // Declaration arrays are addressed by id everywhere, so a
                // locked element records its `byId` pointer, not its index.
                if let id = item.fields?.first(where: { $0.key == "id" })?.value.stringValue {
                    collectLocked(item, prefix: prefix + ["byId", id], into: &out)
                } else {
                    collectLocked(item, prefix: prefix + ["\(index)"], into: &out)
                }
            }
        default:
            break
        }
    }

    static func isPrefix(_ prefix: [String], _ path: [String]) -> Bool {
        prefix.count <= path.count && zip(prefix, path).allSatisfy { $0.0 == $0.1 }
    }

    // MARK: - Version helpers

    struct VersionTriple: Equatable, Comparable {
        var major: Int
        var minor: Int
        var patch: Int

        static func < (lhs: VersionTriple, rhs: VersionTriple) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// Parse `"1.2"` or `"1.2.3"`; missing components default to zero.
    static func parseVersion(_ text: String) -> VersionTriple? {
        let parts = text.split(separator: ".")
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        return VersionTriple(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }
}

// MARK: - Pointer

/// A parsed JSON Pointer with `byId` treated as a first-class segment pair.
public struct Pointer: Equatable, Sendable {
    /// Unescaped segments; `byId` pairs keep both segments (`["phases",
    /// "byId", "play", "when"]`).
    public let segments: [String]
    /// The readable form used in errors and the provenance map.
    public let normalized: String

    init(segments: [String]) {
        self.segments = segments
        self.normalized = "/" + segments.joined(separator: "/")
    }

    /// Parse a JSON Pointer (`/a/b~1c`), rejecting anything that does not
    /// start with `/`.
    static func parse(_ text: String) throws(ResolveError) -> Pointer {
        guard text.hasPrefix("/"), text.count > 1 else {
            throw ResolveError(.badPointer, "patch path must start with '/': \(text)")
        }
        let body = String(text.dropFirst())
        let segments = body.split(separator: "/", omittingEmptySubsequences: false).map { unescape(String($0)) }
        return Pointer(segments: segments)
    }

    /// RFC 6901 unescaping: `~1` is `/`, `~0` is `~`.
    static func unescape(_ segment: String) -> String {
        var out = ""
        var iterator = segment.makeIterator()
        while let character = iterator.next() {
            guard character == "~" else {
                out.append(character)
                continue
            }
            guard let next = iterator.next() else {
                out.append(character)
                continue
            }
            switch next {
            case "1": out.append("/")
            case "0": out.append("~")
            default:
                out.append(character)
                out.append(next)
            }
        }
        return out
    }
}

// MARK: - Rules diff (§8.5)

/// Human-readable differences between two resolved rulesets, for the
/// rulebook, house-rule sharing, and lobby confirmation.
public enum RulesDiff {
    /// Compare two resolved rulesets and render each difference as one line
    /// (plus its provenance note, when the newer side has one).
    public static func diff(_ a: ResolvedRuleset, _ b: ResolvedRuleset) -> [String] {
        var flatA: [String: JSON] = [:]
        var flatB: [String: JSON] = [:]
        flatten(a.document.json, prefix: [], into: &flatA)
        flatten(b.document.json, prefix: [], into: &flatB)

        var lines: [String] = []
        var seenRuleIds = Set<String>()
        let pointers = Set(flatA.keys).union(flatB.keys).sorted()

        for pointer in pointers {
            let old = flatA[pointer]
            let new = flatB[pointer]
            guard old != new else { continue }
            let components = pointer.split(separator: "/").map(String.init)

            if components.count >= 3, components[0] == "options",
                let optionId = optionId(at: Int(components[1]), in: old != nil ? a : b)
            {
                let label = optionLabel(optionId, in: b) ?? optionLabel(optionId, in: a) ?? optionId
                let change = renderChange(old, new)
                lines.append(
                    "option '\(label)' (\(optionId)): \(change)\(noteSuffix("/options/byId/\(optionId)/", in: b))")
            } else if components.count >= 2, components[0] == "rules",
                let ruleId = ruleId(at: Int(components[1]), in: old != nil ? a : b)
            {
                // One line per rule, not one per changed leaf of the rule.
                guard seenRuleIds.insert(ruleId).inserted else { continue }
                let action = old == nil ? "added" : new == nil ? "removed" : "changed"
                lines.append("rule \(ruleId) \(action)\(noteSuffix("/rules/byId/\(ruleId)/", in: b))")
            } else {
                let change = renderChange(old, new)
                lines.append("\(pointer): \(change)\(noteSuffix(pointer, in: b))")
            }
        }
        return lines.sorted()
    }

    static func renderChange(_ old: JSON?, _ new: JSON?) -> String {
        switch (old, new) {
        case (let old?, let new?):
            return "\(old.canonicalString()) → \(new.canonicalString())"
        case (nil, let new?):
            return "added \(new.canonicalString())"
        case (let old?, nil):
            return "removed \(old.canonicalString())"
        case (nil, nil):
            return "unchanged"
        }
    }

    /// The provenance note for a diff line, when the newer side recorded one.
    /// Diff pointers are index-shaped; provenance keys are id-shaped, so the
    /// id-shaped key (or a prefix of it) is matched instead.
    static func noteSuffix(_ provenanceOfId: String, in resolved: ResolvedRuleset) -> String {
        for (key, ref) in resolved.provenance.sorted(by: { $0.key < $1.key }) {
            if key == provenanceOfId || key.hasPrefix(provenanceOfId) {
                if let note = ref.note { return " — \(note)" }
            }
        }
        return ""
    }

    static func optionId(at index: Int?, in resolved: ResolvedRuleset) -> String? {
        guard let index, let options = resolved.document.options, options.indices.contains(index) else {
            return nil
        }
        return options[index].id
    }

    static func ruleId(at index: Int?, in resolved: ResolvedRuleset) -> String? {
        guard let index, let rules = resolved.document.rules, rules.indices.contains(index) else {
            return nil
        }
        return rules[index].id
    }

    static func optionLabel(_ id: String, in resolved: ResolvedRuleset) -> String? {
        resolved.document.options?.first(where: { $0.id == id })?.label.defaultString
    }

    /// Flatten a tree into pointer → value pairs (arrays use numeric labels;
    /// option/rule lines recover ids from the documents).
    static func flatten(_ value: JSON, prefix: [String], into out: inout [String: JSON]) {
        let pointer = "/" + prefix.joined(separator: "/")
        switch value {
        case .object(let fields):
            if !prefix.isEmpty && fields.isEmpty { out[pointer] = value }
            for field in fields {
                flatten(field.value, prefix: prefix + [field.key], into: &out)
            }
        case .array(let items):
            if items.isEmpty { out[pointer] = value }
            for (index, item) in items.enumerated() {
                flatten(item, prefix: prefix + ["\(index)"], into: &out)
            }
        default:
            out[pointer] = value
        }
    }
}
