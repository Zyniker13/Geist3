// Stage B — limits. Size and count caps on a ruleset or overlay document
// (file bytes, name and string lengths, section counts, deck budget),
// shared by the ruleset and overlay validation paths.

extension RulesetValidator {
    static func checkLimits(
        json: JSON, byteCount: Int? = nil
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if let byteCount, byteCount > Limits.maxFileBytes {
            issues.append(
                ValidationIssue(
                    .error, "limits/file-size", "",
                    "The ruleset is \(byteCount) bytes; the limit is \(Limits.maxFileBytes). "
                        + "Split rule text into shorter passages or remove unused sections."))
        }
        issues += lengthAndPlayerIssues(json)
        issues += sectionCountIssues(json)
        issues += deckBudgetIssues(json)
        return issues
    }

    /// Per-value limits from one tree walk: string and name lengths, and the
    /// supported player range.
    private static func lengthAndPlayerIssues(_ json: JSON) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        walk(json) { value, key, pointer in
            if let key, key.count > Limits.maxNameLength {
                issues.append(
                    ValidationIssue(
                        .error, "limits/name-length", pointer,
                        "The name '\(key)' is \(key.count) characters; names are limited to "
                            + "\(Limits.maxNameLength). Choose a shorter identifier."))
            }
            if case .string(let s) = value, s.count > Limits.maxStringLength {
                issues.append(
                    ValidationIssue(
                        .error, "limits/string-length", pointer,
                        "This text is \(s.count) characters; strings are limited to "
                            + "\(Limits.maxStringLength). Shorten the text."))
            }
            if case .int(let i) = value, pointer.hasPrefix("/players/counts"),
                i < Limits.minPlayers || i > Limits.maxPlayers
            {
                issues.append(
                    ValidationIssue(
                        .error, "limits/player-count", pointer,
                        "Player count \(i) is outside the supported range "
                            + "\(Limits.minPlayers)–\(Limits.maxPlayers)."))
            }
        }
        return issues
    }

    /// Section size limits (§11.3): zones, phases, defs.
    private static func sectionCountIssues(_ json: JSON) -> [ValidationIssue] {
        var counts: [String: Int] = [:]
        walk(json) { value, _, pointer in
            guard case .object(let fields) = value,
                ["/zones", "/phases", "/defs"].contains(pointer)
            else { return }
            counts[pointer] = fields.count
        }
        var issues: [ValidationIssue] = []
        func cap(_ pointer: String, _ limit: Int, _ code: String, _ what: String, _ hint: String) {
            guard let count = counts[pointer], count > limit else { return }
            issues.append(
                ValidationIssue(
                    .error, code, pointer,
                    "The ruleset declares \(count) \(what); the limit is \(limit). \(hint)"))
        }
        cap(
            "/zones", Limits.maxZones, "limits/zone-count", "zones",
            "Merge zones that hold the same kind of cards.")
        cap(
            "/phases", Limits.maxPhases, "limits/phase-count", "phases",
            "Combine steps that always run together.")
        cap("/defs", Limits.maxDefs, "limits/def-count", "defs", "")
        return issues
    }

    /// Deck budget: base size × copies − removals + additions.
    private static func deckBudgetIssues(_ json: JSON) -> [ValidationIssue] {
        guard case .object(let root) = json, let deckField = root.first(key: "deck"),
            case .object(let deck) = deckField.value
        else { return [] }
        var base = "french-52"
        var copies = 1
        var removes = 0
        var adds = 0
        for f in deck {
            switch f.key {
            case "base":
                if case .string(let s) = f.value { base = s }
            case "copies":
                if case .int(let i) = f.value { copies = i }
            case "remove":
                if case .array(let a) = f.value { removes = a.count }
            case "add":
                if case .array(let a) = f.value { adds = a.count }
            default: break
            }
        }
        guard let size = Limits.baseSizes[base] else { return [] }
        let total = size * copies - removes + adds
        if total > Limits.maxDeckCards {
            return [
                ValidationIssue(
                    .error, "limits/deck-size", "/deck",
                    "The deck would hold \(total) cards; the limit is "
                        + "\(Limits.maxDeckCards). Use fewer copies or remove fewer cards.")
            ]
        }
        if total < 1 {
            return [
                ValidationIssue(
                    .error, "limits/deck-size", "/deck",
                    "The deck would hold \(total) cards; at least one card is needed.")
            ]
        }
        return []
    }

    /// Walks every value with its object key and pointer.
    private static func walk(
        _ json: JSON, key: String? = nil, pointer: String = "",
        _ visit: (JSON, String?, String) -> Void
    ) {
        visit(json, key, pointer)
        switch json {
        case .array(let items):
            for (i, item) in items.enumerated() {
                walk(item, key: nil, pointer: "\(pointer)/\(i)", visit)
            }
        case .object(let fields):
            for field in fields {
                walk(field.value, key: field.key, pointer: "\(pointer)/\(field.key)", visit)
            }
        default: break
        }
    }

}
