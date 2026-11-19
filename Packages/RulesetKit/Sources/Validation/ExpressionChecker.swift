// Stage E (§11.4): every expression in the document is parsed and
// type-checked; variable-write targets are collected for stage F.

import CardExpr

// MARK: - Stage E — expression type checking

/// Parses and type-checks every expression in the document, collecting
/// variable-write targets along the way for stage F.
struct ExpressionChecker {
    let doc: RulesetDocument
    let names: NameTables
    var issues: [ValidationIssue] = []
    /// `(root, name)` pairs written by any set/add effect.
    var writtenVars: Set<String> = []
    /// Every `let` bound anywhere in the effect tree currently being walked
    /// (score choices may use names bound at any depth — hearts' shooter).
    var collectedLets: [String: ExprType] = [:]

    init(doc: RulesetDocument, names: NameTables) {
        self.doc = doc
        self.names = names
    }

    mutating func run() -> [ValidationIssue] {
        // Def bodies first (they may be called from anywhere).
        for field in doc.defs ?? [] {
            checkDef(field)
        }
        if let end = doc.end {
            if let when = end.when {
                check(when, pointer: "/end/when", expected: .bool, scope: Scope())
            }
            for effect in end.matchEffects ?? [] {
                checkEffects([effect], pointer: "/end/matchEffects", lambdas: [:])
            }
        }
        for field in doc.vars ?? [] {
            guard case .object(let body) = field.value,
                let initialField = body.first(key: "initial"), case .string(let source) = initialField.value
            else { continue }
            check(
                Expr(source: source), pointer: "/vars/\(field.key)/initial",
                expected: names.vars[field.key]?.type, scope: Scope())
        }
        for (i, zone) in (doc.zones ?? []).enumerated() {
            if let owner = zone.owner {
                check(owner, pointer: "/zones/\(i)/owner", expected: .seat, scope: Scope())
            }
            if case .seats(let expr) = zone.visibility {
                check(expr, pointer: "/zones/\(i)/visibility", expected: nil, scope: Scope())
            }
        }
        for (i, phase) in (doc.phases ?? []).enumerated() {
            let p = "/phases/\(i)"
            if let when = phase.when {
                check(when, pointer: "\(p)/when", expected: .bool, scope: Scope())
            }
            if let next = phase.next {
                check(next, pointer: "\(p)/next", expected: .string, scope: Scope())
            }
            checkEffects(phase.before ?? [], pointer: "\(p)/before", lambdas: [:])
            checkEffects(phase.after ?? [], pointer: "\(p)/after", lambdas: [:])
            checkParams(phase, pointer: p)
        }
        return issues
    }

    // MARK: context construction

    mutating func buildContext() -> TypeContext {
        var options: [String: ExprType] = [:]
        for option in doc.options ?? [] {
            do {
                // An enum option holds one of its declared string values.
                let typeName = option.type == "enum" ? "string" : option.type
                options[option.id] = try RulesetTypeNames.parse(typeName)
            } catch {
                issues.append(
                    ValidationIssue(
                        .error, "type/bad-type", "/options/\(option.id)/type",
                        "'\(option.type)' is not a known type name. "
                            + "Use int, bool, string, card, seat, team, or list<...>."))
            }
        }
        var zones: [String: ZoneInfo] = [:]
        for zone in doc.zones ?? [] {
            let visibility: ZoneVisibility
            switch zone.visibility {
            case .named(let v): visibility = ZoneVisibility(rawValue: v) ?? .none
            case .seats: visibility = .owner
            }
            zones[zone.id] = ZoneInfo(id: zone.id, visibility: visibility)
        }
        var defs: [String: DefSignature] = [:]
        for field in doc.defs ?? [] {
            guard case .string(let bodyText) = field.value else {
                issues.append(
                    ValidationIssue(
                        .error, "type/def-signature", "/defs/\(field.key)",
                        "A def maps its signature ('name(param: type, ...) -> result') to a "
                            + "body expression string."))
                continue
            }
            do {
                let header = try RulesetTypeNames.parseDefSignature(field.key)
                let parsed = try Parser().parse(bodyText)
                if parsed.nodeCount > Limits.maxASTNodes {
                    issues.append(
                        ValidationIssue(
                            .error, "limits/expression-size", "/defs/\(field.key)",
                            "The body of '\(header.name)' is \(parsed.nodeCount) AST nodes; the "
                                + "limit is \(Limits.maxASTNodes). Split it into smaller defs."))
                }
                defs[header.name] = DefSignature(
                    name: header.name, params: header.params, types: header.types,
                    result: header.result, body: parsed.ast)
            } catch let error as TypeError {
                issues.append(
                    ValidationIssue(
                        .error, "type/def-signature", "/defs/\(field.key)",
                        "\(plain(error.message)) Fix the def's signature: " + "'name(param: type, ...) -> resultType'.")
                )
            } catch let error as ParseError {
                issues.append(
                    ValidationIssue(
                        .error, "type/parse-error", "/defs/\(field.key)",
                        "The body of '\(field.key)' does not parse: \(plain(error.description))"))
            } catch {
                issues.append(
                    ValidationIssue(
                        .error, "type/def-signature", "/defs/\(field.key)", "\(error)"))
            }
        }
        // Ambient names every ruleset may use: zones read bare (hearts passes
        // 'hand' where a card list is expected), and the reserved word
        // 'none' for "no value yet".
        var contextual: [String: ExprType] = [
            "none": .literalNull,
            // The all-pass action words (euchre redeals on a skipped deal).
            "redeal": .literalString,
        ]
        let reserved = Set(options.keys).union(defs.keys).union(names.vars.keys)
        for zone in doc.zones ?? [] where !reserved.contains(zone.id) {
            contextual[zone.id] = .list(.card)
        }
        return TypeContext(
            evaluation: .host, options: options, vars: names.vars, zones: zones,
            natives: nativeRegistry, defs: defs, contextual: contextual)
    }

    mutating func checkDef(_ field: JSONField) {
        guard case .string(_) = field.value else { return }
        guard let header = try? RulesetTypeNames.parseDefSignature(field.key),
            let def = buildContextSnapshot().defs[header.name]
        else { return }
        var checker = TypeChecker(context: buildContextSnapshot())
        do {
            _ = try checker.checkDef(def)
        } catch let error as TypeError {
            issues.append(
                ValidationIssue(
                    .error, "type/expression-error", "/defs/\(field.key)",
                    "\(plain(error.message))"))
        } catch {
            issues.append(
                ValidationIssue(
                    .error, "type/expression-error", "/defs/\(field.key)", "\(error)"))
        }
    }

    // MARK: per-mechanic expression sites

    mutating func checkParams(_ phase: Phase, pointer: String) {
        let p = "\(pointer)/params"
        switch phase.params {
        case .deal(let d):
            for (j, packet) in d.packets.enumerated() {
                expr(packet.each, "\(p)/packets/\(j)/each", .int)
                expr(packet.count, "\(p)/packets/\(j)/count", .int)
            }
        case .exchangePass(let e):
            expr(e.from, "\(p)/from", nil)
            expr(e.via, "\(p)/via", nil)
            expr(e.to, "\(p)/to", nil)
            expr(e.count, "\(p)/count", .int)
            expr(e.target, "\(p)/target", nil)
        case .exchangeKitty(let e):
            expr(e.seat, "\(p)/seat", .seat)
            expr(e.take, "\(p)/take", nil)
            expr(e.discard, "\(p)/discard", nil)
            expr(e.discardTo, "\(p)/discardTo", nil)
            bool(e.skipIf, "\(p)/skipIf")
        case .exchangeDiscardTo(let e):
            expr(e.count, "\(p)/count", .int)
            expr(e.from, "\(p)/from", nil)
            expr(e.to, "\(p)/to", nil)
        case .revealStarter(let r):
            expr(r.cutBy, "\(p)/cutBy", .seat)
            expr(r.from, "\(p)/from", nil)
            expr(r.to, "\(p)/to", nil)
        case .auctionLadder(let a):
            checkLadderParams(a, pointer: p)
        case .auctionRounds(let a):
            checkRoundsParams(a, pointer: p)
        case .trickPlay(let t):
            checkTrickParams(t, pointer: p)
        case .countPlay(let c):
            checkCountParams(c, pointer: p)
        case .show(let s):
            checkShowParams(s, pointer: p)
        default: break
        }
        checkParamEffects(phase, pointer: pointer)
    }

    private mutating func checkLadderParams(_ a: AuctionLadderParams, pointer: String) {
        expr(a.firstBidder, "\(pointer)/firstBidder", .seat)
        expr(a.allPass?.action, "\(pointer)/allPass/action", nil)
        expr(a.result?.contract, "\(pointer)/result/contract", nil)
        expr(a.result?.declarer?.set, "\(pointer)/result/declarer/set", nil)
    }

    private mutating func checkRoundsParams(_ a: AuctionRoundsParams, pointer: String) {
        expr(a.firstBidder, "\(pointer)/firstBidder", .seat)
        bool(a.endWhen, "\(pointer)/endWhen")
        expr(a.allPass?.action, "\(pointer)/allPass/action", nil)
        for (j, round) in a.rounds.enumerated() {
            for (k, call) in round.calls.enumerated() {
                bool(call.allowed, "\(pointer)/rounds/\(j)/calls/\(k)/allowed")
                bool(call.alone, "\(pointer)/rounds/\(j)/calls/\(k)/alone")
                if let sets = call.sets {
                    for (m, assign) in sets.enumerated() {
                        expr(assign.set, "\(pointer)/rounds/\(j)/calls/\(k)/sets/\(m)/set", nil)
                        expr(assign.to, "\(pointer)/rounds/\(j)/calls/\(k)/sets/\(m)/to", nil)
                    }
                }
            }
        }
    }

    private mutating func checkTrickParams(_ t: TrickPlayParams, pointer: String) {
        // suitOf/strength/winner name defs the engine calls per card or
        // per trick (§7.3); they are reference-checked, not type-checked.
        // The remaining sites are expressions in a scope that knows the
        // trick's `winner`.
        let trickScope = Scope(contextual: ["winner": .seat])
        check(t.activeSeats, pointer: "\(pointer)/activeSeats", expected: nil, scope: trickScope)
        check(t.trump, pointer: "\(pointer)/trump", expected: nil, scope: trickScope)
        check(t.firstLeader, pointer: "\(pointer)/firstLeader", expected: .seat, scope: trickScope)
        check(t.nextLeader, pointer: "\(pointer)/nextLeader", expected: .seat, scope: trickScope)
        if let g = t.leadAllowed {
            check(g.expr, pointer: "\(pointer)/leadAllowed/expr", expected: .bool, scope: trickScope)
        }
        if let g = t.playAllowed {
            check(g.expr, pointer: "\(pointer)/playAllowed/expr", expected: .bool, scope: trickScope)
        }
        expr(t.dummy?.seat, "\(pointer)/dummy/seat", .seat, [:])
        expr(t.dummy?.controlledBy, "\(pointer)/dummy/controlledBy", .seat, [:])
        bool(t.claims?.enabled, "\(pointer)/claims/enabled")
        expr(t.claims?.by, "\(pointer)/claims/by", .seat)
        check(
            t.claims?.acceptedBy, pointer: "\(pointer)/claims/acceptedBy",
            expected: nil, scope: Scope(contextual: ["defenders": .team]))
    }

    private mutating func checkCountParams(_ c: CountPlayParams, pointer: String) {
        expr(c.from, "\(pointer)/from", nil)
        expr(c.to, "\(pointer)/to", nil)
        expr(c.firstPlayer, "\(pointer)/firstPlayer", .seat)
        expr(c.valueOf, "\(pointer)/valueOf", .int)
        expr(c.limit, "\(pointer)/limit", .int)
        expr(c.pointsOnPlay, "\(pointer)/pointsOnPlay", .int)
        expr(c.go?.lastCardPoints, "\(pointer)/go/lastCardPoints", .int)
        expr(c.go?.exactLimitPoints, "\(pointer)/go/exactLimitPoints", .int)
    }

    private mutating func checkShowParams(_ s: ShowParams, pointer: String) {
        for (j, entry) in s.order.enumerated() {
            expr(entry.seat, "\(pointer)/order/\(j)/seat", .seat)
            expr(entry.award, "\(pointer)/order/\(j)/award", nil)
        }
        expr(s.with, "\(pointer)/with", nil)
        expr(s.points, "\(pointer)/points", .int)
        bool(s.manual, "\(pointer)/manual")
        bool(s.muggins, "\(pointer)/muggins")
        expr(s.award, "\(pointer)/award", .int)
    }

    /// The mechanic payloads that carry effect lists, checked here so the
    /// per-mechanic dispatch above stays small.
    private mutating func checkParamEffects(_ phase: Phase, pointer: String) {
        if case .deal(let d) = phase.params {
            for effect in d.thenEffects ?? [] {
                checkEffects([effect], pointer: "\(pointer)/params/then", lambdas: [:])
            }
        }
        if case .auctionRounds(let a) = phase.params {
            for effect in a.onCallEffects ?? [] {
                checkEffects([effect], pointer: "\(pointer)/params/onCall", lambdas: [:])
            }
        }
        if case .trickPlay(let t) = phase.params {
            checkEffects(
                t.onCardPlayedEffects ?? [], pointer: "\(pointer)/params/onCardPlayed", lambdas: [:])
            checkEffects(
                t.onTrickEndEffects ?? [], pointer: "\(pointer)/params/onTrickEnd", lambdas: [:])
        }
        if case .revealStarter(let r) = phase.params {
            for effect in r.afterEffects ?? [] {
                checkEffects([effect], pointer: "\(pointer)/params/after", lambdas: [:])
            }
        }
        if case .score(let s) = phase.params {
            checkScorePhase(s, pointer: pointer)
        }
    }

    private mutating func checkScorePhase(_ s: ScoreParams, pointer: String) {
        // Choices run after the phase's effects and may use names the
        // effects bound with `let` (hearts' shooter), at any depth.
        collectedLets = [:]
        let finalLambdas = checkEffects(
            s.effects, pointer: "\(pointer)/params/effects", lambdas: [:])
        let choiceLambdas = finalLambdas.merging(collectedLets) { _, new in new }
        for (j, choice) in (s.choices ?? []).enumerated() {
            expr(choice.seat, "\(pointer)/params/choices/\(j)/seat", .seat, choiceLambdas)
            expr(choice.when, "\(pointer)/params/choices/\(j)/when", .bool, choiceLambdas)
        }
    }

    mutating func guardExpr(_ guardSpec: PlayGuard?, _ pointer: String) {
        guard let guardSpec else { return }
        check(guardSpec.expr, pointer: "\(pointer)/expr", expected: .bool, scope: Scope())
    }

    mutating func bool(_ expr: Expr?, _ pointer: String) {
        check(expr, pointer: pointer, expected: .bool, scope: Scope())
    }

    mutating func expr(_ expr: Expr?, _ pointer: String, _ expected: ExprType?) {
        check(expr, pointer: pointer, expected: expected, scope: Scope())
    }

    mutating func expr(_ numOrExpr: NumOrExpr?, _ pointer: String, _ expected: ExprType?) {
        guard case .expr(let e) = numOrExpr else { return }
        check(e, pointer: pointer, expected: expected, scope: Scope())
    }

    /// A fresh checker per expression keeps inference state isolated; the
    /// context itself is immutable during expression checks.
    var cachedContext: TypeContext?
    mutating func buildContextSnapshot() -> TypeContext {
        if cachedContext == nil { cachedContext = buildContext() }
        return cachedContext!
    }

    /// Rewrites checker messages into plain language where the checker's
    /// wording is terse.
    func plain(_ message: String) -> String {
        var m = message
        if m.hasSuffix(" (§7.2)") || m.hasSuffix(" (§7.3)") || m.hasSuffix(" (§7.5)") {
            m = String(m.dropLast(6))
        }
        return m
    }
}

/// Display form for expected/got pairs in messages.
func typeDisplay(_ type: ExprType) -> String {
    String(describing: type)
}
