// ReferenceChecks: stage D reference validation (§11.4). Extracted from
// Validator.swift to keep both files under the file-length limit.
import Foundation

/// Stage D reference checks: rule IDs, zones, vars, defs, options, and
/// phases. One small struct so each check stays readable.
struct ReferenceChecks {
    let names: NameTables
    var issues: [ValidationIssue] = []

    mutating func ruleRef(_ rule: String?, _ pointer: String) {
        guard let rule, !rule.isEmpty else { return }
        // Id-shaped citations (EUC-2.4) must resolve to a declared rule;
        // prose slugs (firstOfWinningSideToNameStrain) are labels.
        let idShaped =
            rule.range(
                of: "^[A-Z]{2,5}(-[a-zA-Z]+)?-[0-9][0-9a-zA-Z.]*$",
                options: .regularExpression) != nil
        guard idShaped else { return }
        guard !names.ruleIds.contains(rule) else { return }
        issues.append(
            ValidationIssue(
                .error, "reference/unknown-rule", "\(pointer)/rule",
                "This cites rule '\(rule)', which the ruleset does not declare. "
                    + "Add a matching entry under 'rules' or fix the reference."))
    }

    mutating func zoneRef(_ zone: String?, _ pointer: String, _ what: String) {
        guard let zone, !names.zoneIds.contains(zone) else { return }
        issues.append(
            ValidationIssue(
                .error, "reference/unknown-zone", pointer,
                "The \(what) names zone '\(zone)', which the ruleset does not declare. "
                    + "Declared zones: \(names.zoneIds.sorted().joined(separator: ", "))."))
    }

    mutating func varRef(_ path: String, _ pointer: String) -> (
        root: String, name: String, index: String?
    )? {
        guard let parsed = RulesetValidator.parseWritePath(path) else {
            issues.append(
                ValidationIssue(
                    .error, "reference/unknown-var", pointer,
                    "'\(path)' is not a variable path like 'match.score[seat]'."))
            return nil
        }
        guard let binding = names.vars[parsed.name] else {
            issues.append(
                ValidationIssue(
                    .error, "reference/unknown-var", pointer,
                    "'\(path)' writes variable '\(parsed.name)', which the ruleset does not "
                        + "declare. Declared vars: \(names.vars.keys.sorted().joined(separator: ", "))."))
            return nil
        }
        let rootStore = parsed.root == "match" ? VarStore.match : VarStore.deal
        if binding.scope.store != rootStore {
            issues.append(
                ValidationIssue(
                    .error, "reference/unknown-var", pointer,
                    "'\(path)' reaches a \(parsed.root)-scoped variable, but '\(parsed.name)' "
                        + "is declared with scope '\(names.varScopeSpelling[parsed.name] ?? "?")'."))
        }
        return parsed
    }

    mutating func nextRef(_ next: Expr, _ pointer: String) {
        guard let target = RulesetValidator.literalString(next.source),
            !names.phaseIds.contains(target)
        else { return }
        issues.append(
            ValidationIssue(
                .error, "reference/unknown-phase", "\(pointer)/next",
                "This phase jumps to '\(target)', which is not a phase id. "
                    + "Declared phases: \(names.phaseIds.sorted().joined(separator: ", "))."))
    }

    mutating func defRef(_ name: Expr?, _ pointer: String) {
        guard let name, !name.source.isEmpty else { return }
        // Trick resolution may also name a built-in strategy.
        guard !RulesetValidator.winnerStrategies.contains(name.source),
            !names.defNames.contains(name.source)
        else { return }
        issues.append(
            ValidationIssue(
                .error, "reference/unknown-def", pointer,
                "'\(name.source)' names a def this ruleset does not declare. "
                    + "Declared defs: \(names.defNames.sorted().joined(separator: ", "))."))
    }

    mutating func document(_ doc: RulesetDocument) {
        endChecks(doc.end)
        for (i, option) in (doc.options ?? []).enumerated() {
            for r in option.rules { ruleRef(r, "/options/\(i)/rules") }
        }
        for (i, phase) in (doc.phases ?? []).enumerated() {
            phaseChecks(phase, i)
        }
    }

    private mutating func endChecks(_ end: EndDecl?) {
        guard let end else { return }
        ruleRef(end.rule, "/end")
        if let rank = RulesetValidator.parseRank(end.rank) {
            if !rank.isWellFormed {
                issues.append(
                    ValidationIssue(
                        .error, "reference/bad-vocabulary", "/end/rank",
                        "The rank rule must look like 'ascending(match.score)' or "
                            + "'descending(match.score)' naming a declared variable."))
            } else if names.vars[rank.varName] == nil {
                issues.append(
                    ValidationIssue(
                        .error, "reference/unknown-var", "/end/rank",
                        "The rank rule names variable '\(rank.varName)', which the ruleset "
                            + "does not declare."))
            }
        }
        if let maxDeals = end.maxDeals, maxDeals < 1 {
            issues.append(
                ValidationIssue(
                    .error, "reference/option-range", "/end/maxDeals",
                    "maxDeals must be at least 1."))
        }
    }

    private mutating func phaseChecks(_ phase: Phase, _ i: Int) {
        let p = "/phases/\(i)"
        ruleRef(phase.rule, p)
        if let next = phase.next { nextRef(next, p) }
        for effect in phase.before ?? [] {
            effectTree(effect, pointer: "\(p)/before")
        }
        for effect in phase.after ?? [] {
            effectTree(effect, pointer: "\(p)/after")
        }
        paramsChecks(phase, pointer: p)
    }

    private mutating func paramsChecks(_ phase: Phase, pointer: String) {
        switch phase.params {
        case .deal(let d):
            for (j, packet) in d.packets.enumerated() {
                zoneRef(packet.to, "\(pointer)/params/packets/\(j)/to", "deal packet")
            }
            for effect in d.thenEffects ?? [] {
                effectTree(effect, pointer: "\(pointer)/params/then")
            }
        case .auctionLadder(let a):
            ruleRef(a.ladder?.rule, "\(pointer)/params/ladder")
            ruleRef(a.end?.rule, "\(pointer)/params/end")
            ruleRef(a.allPass?.rule, "\(pointer)/params/allPass")
            ruleRef(a.result?.declarer?.rule, "\(pointer)/params/result/declarer")
            ruleRef(a.result?.declarer?.ruleId, "\(pointer)/params/result/declarer")
        case .auctionRounds(let a):
            for (j, round) in a.rounds.enumerated() {
                ruleRef(round.rule, "\(pointer)/params/rounds/\(j)")
            }
            for effect in a.onCallEffects ?? [] {
                effectTree(effect, pointer: "\(pointer)/params/onCall")
            }
        case .trickPlay(let t):
            trickParamsChecks(t, pointer: pointer)
        case .countPlay(let c):
            ruleRef(c.rule, "\(pointer)/params")
            ruleRef(c.pointsRule, "\(pointer)/params")
            ruleRef(c.go?.rule, "\(pointer)/params/go")
        case .show(let s):
            for (j, entry) in s.order.enumerated() {
                zoneRef(entry.zone, "\(pointer)/params/order/\(j)/zone", "show entry")
            }
            zoneRef(s.with, "\(pointer)/params/with", "show 'with'")
            ruleRef(s.pointsRule, "\(pointer)/params")
        case .score(let s):
            for effect in s.effects {
                effectTree(effect, pointer: "\(pointer)/params/effects")
            }
        case .revealStarter(let r):
            for effect in r.afterEffects ?? [] {
                effectTree(effect, pointer: "\(pointer)/params/after")
            }
        default:
            break
        }
    }

    private mutating func trickParamsChecks(_ t: TrickPlayParams, pointer: String) {
        ruleRef(t.follow?.rule, "\(pointer)/params/follow")
        ruleRef(t.leadAllowed?.rule, "\(pointer)/params/leadAllowed")
        ruleRef(t.playAllowed?.rule, "\(pointer)/params/playAllowed")
        ruleRef(t.firstLeaderRule, "\(pointer)/params")
        ruleRef(t.winnerRule, "\(pointer)/params")
        ruleRef(t.dummy?.rule, "\(pointer)/params/dummy")
        ruleRef(t.claims?.rule, "\(pointer)/params/claims")
        defRef(t.suitOf, "\(pointer)/params/suitOf")
        defRef(t.strength, "\(pointer)/params/strength")
        defRef(t.winner, "\(pointer)/params/winner")
        for effect in t.onCardPlayedEffects ?? [] {
            effectTree(effect, pointer: "\(pointer)/params/onCardPlayed")
        }
        for effect in t.onTrickEndEffects ?? [] {
            effectTree(effect, pointer: "\(pointer)/params/onTrickEnd")
        }
    }

    /// Reference checks shared by every effect tree (recursing into
    /// if/forEach).
    mutating func effectTree(_ effect: Effect, pointer: String) {
        switch effect {
        case .set(let path, _, _):
            _ = varRef(path, "\(pointer)/set")
        case .add(let path, _, _, _):
            _ = varRef(path, "\(pointer)/add")
        case .letBinding: break
        case .ifElse(_, let then, let elseBranch, _):
            for e in then { effectTree(e, pointer: "\(pointer)/if/then") }
            for e in elseBranch ?? [] { effectTree(e, pointer: "\(pointer)/if/else") }
        case .forEach(_, let body, _):
            for e in body { effectTree(e, pointer: "\(pointer)/forEach") }
        case .move(let spec, _):
            zoneRef(RulesetValidator.stringValue(spec.from), "\(pointer)/move/from", "move source")
            zoneRef(RulesetValidator.stringValue(spec.to), "\(pointer)/move/to", "move destination")
        case .reveal(let zone, _, _, _):
            zoneRef(zone, "\(pointer)/reveal", "reveal")
        case .emit: break
        }
    }
}

extension RulesetValidator {
    static func stringValue(_ json: JSON) -> String? {
        if case .string(let s) = json { return s }
        if case .object(let fields) = json, let zoneField = fields.first(key: "zone"),
            case .string(let s) = zoneField.value
        {
            return s
        }
        return nil
    }

    static func literalString(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
    }

    /// Splits a write path like `match.score[t]` into root, name, and the
    /// index expression (if any).
    static func parseWritePath(_ path: String) -> (root: String, name: String, index: String?)? {
        let dot = path.firstIndex(of: ".")
        guard let dotIndex = dot, dotIndex != path.startIndex else { return nil }
        let root = String(path[path.startIndex..<dotIndex])
        let rest = path[path.index(after: dotIndex)...]
        if let bracket = rest.firstIndex(of: "[") {
            guard rest.hasSuffix("]") else { return nil }
            let name = String(rest[rest.startIndex..<bracket])
            let index = String(rest[rest.index(after: bracket)..<rest.index(before: rest.endIndex)])
            return (root, name, index)
        }
        return (root, String(rest), nil)
    }

    static func parseRank(_ rank: String) -> (varName: String, isWellFormed: Bool)? {
        guard rank.hasPrefix("ascending(") || rank.hasPrefix("descending("),
            rank.hasSuffix(")")
        else { return (rank, false) }
        let innerStart = rank.index(rank.startIndex, offsetBy: rank.hasPrefix("ascending(") ? 10 : 11)
        let inner = rank[innerStart..<rank.index(before: rank.endIndex)]
        guard let parsed = parseWritePath(String(inner)) else { return (rank, false) }
        return (parsed.name, true)
    }
}

// MARK: - Name tables (stage D helpers)

/// Every declared identifier in one place, plus duplicate detection.
struct NameTables {
    let ruleIds: Set<String>
    let zoneIds: Set<String>
    let phaseIds: Set<String>
    let optionIds: Set<String>
    let defNames: Set<String>
    /// Var name → scope spelling (JSON form).
    let varScopeSpelling: [String: String]
    /// Var name → binding for the type checker.
    let vars: [String: VarBinding]
    let duplicateIssues: [ValidationIssue]

    init(_ doc: RulesetDocument) {
        var issues: [ValidationIssue] = []
        func collect(
            _ items: [String], what: String, pointerPrefix: String,
            into set: inout Set<String>
        ) {
            for (i, id) in items.enumerated() {
                if set.contains(id) {
                    issues.append(
                        ValidationIssue(
                            .error, "reference/duplicate-id", "\(pointerPrefix)/\(i)",
                            "The \(what) '\(id)' is declared more than once. " + "Give each one a distinct id."))
                }
                set.insert(id)
            }
        }
        var rules: Set<String> = []
        collect(
            (doc.rules ?? []).map { $0.id }, what: "rule", pointerPrefix: "/rules",
            into: &rules)
        var zones: Set<String> = []
        collect(
            (doc.zones ?? []).map { $0.id }, what: "zone", pointerPrefix: "/zones",
            into: &zones)
        var phases: Set<String> = []
        collect(
            (doc.phases ?? []).map { $0.id }, what: "phase", pointerPrefix: "/phases",
            into: &phases)
        var options: Set<String> = []
        collect(
            (doc.options ?? []).map { $0.id }, what: "option", pointerPrefix: "/options",
            into: &options)

        var varBindings: [String: VarBinding] = [:]
        var varSpellings: [String: String] = [:]
        for field in doc.vars ?? [] {
            if varBindings[field.key] != nil {
                issues.append(
                    ValidationIssue(
                        .error, "reference/duplicate-id", "/vars/\(field.key)",
                        "The variable '\(field.key)' is declared more than once. " + "Give each one a distinct name."))
                continue
            }
            guard case .object(_) = field.value else { continue }
            let decl: VarDecl
            do {
                decl = try VarDecl(json: field.value, path: "/vars/\(field.key)")
            } catch {
                continue
            }
            guard let scope = Self.varScope(decl.scope) else { continue }
            let type = (try? RulesetTypeNames.parse(decl.type)) ?? .int
            varBindings[field.key] = VarBinding(scope: scope, type: type, initial: decl.initial.source)
            varSpellings[field.key] = decl.scope
        }

        var defs: Set<String> = []
        for field in doc.defs ?? [] {
            // A def maps its signature string to its body: {"name(p: t) -> r": "body"}.
            let header =
                (try? RulesetTypeNames.parseDefSignature(field.key))?
                .name ?? field.key
            if defs.contains(header) {
                issues.append(
                    ValidationIssue(
                        .error, "reference/duplicate-id", "/defs/\(field.key)",
                        "The def '\(header)' is declared more than once. " + "Give each one a distinct name."))
            }
            defs.insert(header)
        }

        ruleIds = rules
        zoneIds = zones
        phaseIds = phases
        optionIds = options
        defNames = defs
        vars = varBindings
        varScopeSpelling = varSpellings
        duplicateIssues = issues
    }

    /// Maps the JSON scope spelling to the checker's `VarScope`.
    static func varScope(_ spelling: String) -> VarScope? {
        switch spelling {
        case "match": return .match
        case "seatMatch": return .seatMatch
        case "teamMatch": return .teamMatch
        case "deal": return .deal
        case "seatDeal": return .seatDeal
        case "teamDeal": return .teamDeal
        default: return nil
        }
    }
}
