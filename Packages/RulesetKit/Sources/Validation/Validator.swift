// Static ruleset validation (§11.4 stages B–F) and the error taxonomy the
// 60-case corpus asserts against.
//
// Stages:
//   B  decode-and-limits   byte size, string/name lengths, section counts,
//                          deck budget, player range (§11.3)
//   C  schema              decode + required sections + closed vocabularies
//   D  references          rule IDs, zones, vars, defs, options, phases
//   E  types               every expression type-checked via TypeChecker
//   F  static analysis     reachability, termination, fallback guards
//
// Every issue carries a stable `code` (stage/class + detail), a JSON pointer
// into the source document, and a plain-language message with a fix hint
// (§11.4 "reports are written for people").

import CardExpr

/// How serious an issue is. Stage B–F issues are errors; warnings exist for
/// soft conditions (no end condition, dynamic `next` making reachability
/// unprovable) that simulation (P2.8) settles.
public enum ValidationSeverity: Equatable, Sendable {
    case error
    case warning
}

/// One validation finding: machine-readable code, document pointer, and a
/// plain-language message.
public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public let severity: ValidationSeverity
    public let code: String
    public let pointer: String
    public let message: String

    public init(
        _ severity: ValidationSeverity, _ code: String, _ pointer: String, _ message: String
    ) {
        self.severity = severity
        self.code = code
        self.pointer = pointer
        self.message = message
    }

    public var description: String {
        "[\(code)] \(pointer): \(message)"
    }
}

/// The result of validating one document.
public struct ValidationReport: Equatable, Sendable {
    public let issues: [ValidationIssue]

    public init(issues: [ValidationIssue]) {
        self.issues = issues.sorted { a, b in
            if a.pointer != b.pointer { return a.pointer < b.pointer }
            if a.code != b.code { return a.code < b.code }
            return a.message < b.message
        }
    }

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    /// A document passes when it has no errors; warnings are advisory.
    public var passed: Bool { errors.isEmpty }
}

// MARK: - Limits (§11.3)

enum Limits {
    static let maxFileBytes = 256 * 1024
    static let maxPhases = 64
    static let maxDefs = 256
    static let maxZones = 32
    static let maxASTNodes = 2_000
    static let maxDeckCards = 312
    static let minPlayers = 1
    static let maxPlayers = 10
    static let maxStringLength = 2_000
    static let maxNameLength = 60
    /// Base deck sizes for the bases the reference corpus uses. Unknown bases
    /// are reported by the vocabulary check, not here.
    static let baseSizes: [String: Int] = ["french-52": 52, "euchre-24": 24]
}

// MARK: - Vocabularies (§6, as observed across the reference rulesets)

enum Vocab {
    static let zoneScopes: Set<String> = ["seat", "shared", "team"]
    static let zoneVisibilities: Set<String> = ["public", "owner", "none"]
    static let varScopes: Set<String> = [
        "match", "seatMatch", "teamMatch", "deal", "seatDeal", "teamDeal",
    ]
    static let forEachKinds: Set<String> = ["seat", "team"]
    static let otherwiseValues: Set<String> = ["any"]
    static let endChecks: Set<String> = ["afterDeal", "continuous"]
    static let ties: Set<String> = ["impossible", "shared"]
    static let teams: Set<String> = ["none", "partnershipOpposite"]
    static let firstDealers: Set<String> = ["firstJack", "highCut", "lowCut", "randomCut"]
    static let dealerRotations: Set<String> = ["left", "alternate"]
    static let zoneSorts: Set<String> = ["bridgeSuits", "byRank", "bySuitThenRank", "trumpFirst"]
    static let trickOrders: Set<String> = ["natural"]
    static let deckBases: Set<String> = ["french-52", "euchre-24"]
    /// Mechanics whose rules guarantee forward progress on their own
    /// (§11.4: each mechanic declares a progress measure). `show` and `score`
    /// move no cards, so a cycle made only of them needs the end condition
    /// to reference changing state.
    static let progressMechanics: Set<String> = [
        "deal", "auction.ladder", "auction.rounds",
        "exchange.pass", "exchange.kitty", "exchange.discardTo",
        "reveal.starter", "trick-play", "count-play",
    ]
}

// MARK: - Validator

public enum RulesetValidator {
    /// Validates raw JSON text: stages B through F.
    public static func validate(text: String, byteCount: Int? = nil) -> ValidationReport {
        do {
            let json = try JSONParser.parse(text)
            return validate(json: json, byteCount: byteCount)
        } catch {
            return ValidationReport(issues: [
                ValidationIssue(.error, "schema/bad-json", "", "The file is not valid JSON: \(error)")
            ])
        }
    }

    /// Validates a parsed JSON tree: stages B through F.
    public static func validate(json: JSON, byteCount: Int? = nil) -> ValidationReport {
        var issues: [ValidationIssue] = []
        issues += checkLimits(json: json, byteCount: byteCount)
        let doc: RulesetDocument
        do {
            doc = try RulesetDocument(json: json, path: "")
        } catch {
            issues.append(mapSchemaError(error as SchemaError))
            return ValidationReport(issues: issues)
        }
        issues += validate(doc, raw: json).issues
        return ValidationReport(issues: issues)
    }

    /// Validates an already-decoded document: stages D through F. `raw` (when
    /// supplied) re-checks the stage-B limits.
    public static func validate(
        _ doc: RulesetDocument, raw: JSON? = nil, byteCount: Int? = nil
    ) -> ValidationReport {
        var issues: [ValidationIssue] = []
        if let raw { issues += checkLimits(json: raw, byteCount: byteCount) }
        issues += checkRequiredSections(doc)
        issues += checkMechanics(doc)

        let names = NameTables(doc)
        issues += names.duplicateIssues
        issues += checkVocabularies(doc)
        issues += checkReferences(doc, names: names)
        issues += checkOptionRanges(doc)

        var typed = ExpressionChecker(doc: doc, names: names)
        issues += typed.run()
        var analysis = StaticAnalysis(doc: doc, names: names, writtenVars: typed.writtenVars)
        issues += analysis.run()
        return ValidationReport(issues: issues)
    }

    // MARK: Stage B — limits

    private static func checkLimits(json: JSON, byteCount: Int?) -> [ValidationIssue] {
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

    // MARK: Stage C — schema

    private static func mapSchemaError(_ error: SchemaError) -> ValidationIssue {
        func at(_ path: String?) -> String { path ?? "" }
        switch error {
        case .parse(let detail):
            return ValidationIssue(
                .error, "schema/bad-json", "",
                "The file is not valid JSON: \(detail).")
        case .notObject(let path):
            return ValidationIssue(
                .error, "schema/not-object", at(path),
                "This section must be a JSON object (a set of named fields).")
        case .missingKey(let key, let path):
            return ValidationIssue(
                .error, "schema/missing-field", at(path),
                "The field '\(key)' is required here. Add it — see the schema for its shape.")
        case .wrongType(let expected, let path):
            return ValidationIssue(
                .error, "schema/wrong-type", at(path),
                "This field has the wrong shape: expected \(expected). "
                    + "Check the key spelling and value type against the schema.")
        case .formatMismatch(let expected, let actual):
            return ValidationIssue(
                .error, "schema/format-mismatch", "/format",
                "The format marker '\(actual)' does not match this document kind; " + "expected '\(expected)'.")
        }
    }

    private static func checkRequiredSections(_ doc: RulesetDocument) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func require(_ section: Bool, _ name: String) {
            if !section {
                issues.append(
                    ValidationIssue(
                        .error, "schema/missing-field", "/\(name)",
                        "The '\(name)' section is required."))
            }
        }
        require(doc.players != nil, "players")
        require(doc.deck != nil, "deck")
        require(doc.phases != nil, "phases")
        require(doc.end != nil, "end")
        if doc.format != "parlor.ruleset/1" {
            issues.append(
                ValidationIssue(
                    .error, "schema/format-mismatch", "/format",
                    "The format marker '\(doc.format)' does not match this document kind; "
                        + "expected 'parlor.ruleset/1'."))
        }
        if let phases = doc.phases, phases.isEmpty {
            issues.append(
                ValidationIssue(
                    .error, "schema/missing-field", "/phases",
                    "The ruleset has no phases; at least one is needed."))
        }
        return issues
    }

    private static func checkMechanics(_ doc: RulesetDocument) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (i, phase) in (doc.phases ?? []).enumerated() where !PhaseParams.knownMechanics.contains(phase.mechanic) {
            issues.append(
                ValidationIssue(
                    .error, "schema/unknown-mechanic", "/phases/\(i)/mechanic",
                    "'\(phase.mechanic)' is not a mechanic the engine knows. "
                        + "Use one of: \(PhaseParams.knownMechanics.joined(separator: ", "))."))
        }
        return issues
    }

    // MARK: Stage D — references and vocabularies

    private static func checkVocabularies(_ doc: RulesetDocument) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func bad(
            _ ok: Bool, _ code: String, _ pointer: String, _ value: String,
            _ allowed: Set<String>, _ what: String
        ) {
            if !ok {
                issues.append(
                    ValidationIssue(
                        .error, code, pointer,
                        "'\(value)' is not a known \(what). Use one of: "
                            + "\(allowed.sorted().joined(separator: ", "))."))
            }
        }
        for (i, zone) in (doc.zones ?? []).enumerated() {
            let p = "/zones/\(i)"
            bad(
                Vocab.zoneScopes.contains(zone.scope), "reference/bad-vocabulary",
                "\(p)/scope", zone.scope, Vocab.zoneScopes, "zone scope")
            switch zone.visibility {
            case .named(let v):
                bad(
                    Vocab.zoneVisibilities.contains(v), "reference/bad-vocabulary",
                    "\(p)/visibility", v, Vocab.zoneVisibilities, "zone visibility")
            case .seats: break
            }
            if let sort = zone.sort {
                bad(
                    Vocab.zoneSorts.contains(sort), "reference/bad-vocabulary",
                    "\(p)/sort", sort, Vocab.zoneSorts, "zone sort order")
            }
        }
        for field in (doc.vars ?? []) {
            guard case .object(let body) = field.value,
                let scopeField = body.first(key: "scope"), case .string(let scope) = scopeField.value
            else { continue }
            bad(
                Vocab.varScopes.contains(scope), "reference/bad-vocabulary",
                "/vars/\(field.key)/scope", scope, Vocab.varScopes, "variable scope")
        }
        if let players = doc.players {
            bad(
                Vocab.teams.contains(players.teams), "reference/bad-vocabulary",
                "/players/teams", players.teams, Vocab.teams, "team layout")
        }
        if let setup = doc.setup {
            bad(
                Vocab.firstDealers.contains(setup.firstDealer), "reference/bad-vocabulary",
                "/setup/firstDealer", setup.firstDealer, Vocab.firstDealers, "first-dealer rule")
            bad(
                Vocab.dealerRotations.contains(setup.dealerRotation), "reference/bad-vocabulary",
                "/setup/dealerRotation", setup.dealerRotation, Vocab.dealerRotations,
                "dealer rotation")
        }
        if let deck = doc.deck, let base = deck.base {
            bad(
                Vocab.deckBases.contains(base), "reference/bad-vocabulary",
                "/deck/base", base, Vocab.deckBases, "deck base")
        }
        if let end = doc.end {
            bad(
                Vocab.endChecks.contains(end.check), "reference/bad-vocabulary",
                "/end/check", end.check, Vocab.endChecks, "end check")
            bad(
                Vocab.ties.contains(end.ties), "reference/bad-vocabulary",
                "/end/ties", end.ties, Vocab.ties, "tie rule")
        }
        for (i, phase) in (doc.phases ?? []).enumerated() {
            let p = "/phases/\(i)/params"
            switch phase.params {
            case .trickPlay(let t):
                if let order = t.order {
                    bad(
                        Vocab.trickOrders.contains(order), "reference/bad-vocabulary",
                        "\(p)/order", order, Vocab.trickOrders, "play order")
                }
            default: break
            }
        }
        return issues
    }

    private static func checkOptionRanges(_ doc: RulesetDocument) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (i, option) in (doc.options ?? []).enumerated() {
            let p = "/options/\(i)"
            if let min = option.min, let max = option.max, min > max {
                issues.append(
                    ValidationIssue(
                        .error, "reference/option-range", "\(p)/min",
                        "The minimum (\(min)) is greater than the maximum (\(max)). Swap them."))
            }
            if case .int(let value) = option.defaultValue {
                if let min = option.min, value < min {
                    issues.append(
                        ValidationIssue(
                            .error, "reference/option-range", "\(p)/default",
                            "The default (\(value)) is below the minimum (\(min))."))
                }
                if let max = option.max, value > max {
                    issues.append(
                        ValidationIssue(
                            .error, "reference/option-range", "\(p)/default",
                            "The default (\(value)) is above the maximum (\(max))."))
                }
            }
        }
        return issues
    }

    /// Built-in trick-resolution strategies a `winner` param may name
    /// instead of a def (§7.3).
    static let winnerStrategies: Set<String> = [
        "highestOfLedSuit", "highestTrumpElseLedSuit",
    ]

    private static func checkReferences(
        _ doc: RulesetDocument, names: NameTables
    ) -> [ValidationIssue] {
        var checks = ReferenceChecks(names: names)
        checks.document(doc)
        return checks.issues
    }

    /// Stage D reference checks: rule IDs, zones, vars, defs, options, and
    /// phases. One small struct so each check stays readable.
}
