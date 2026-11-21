// P2.8: turn a validated document into a runnable engine for the simulator
// (ROADMAP §P2.8). Only the P1 engine mechanics are supported; anything a
// reference game needs beyond them is reported as `SimulationError
// .unsupported` — the simulator never fakes a rule.
//
// Determinism (CONVENTIONS §5): the builder is a pure function of the
// document; all randomness lives in the engine's seeded deal.

import CardExpr
import CardModel
@_spi(HostOnly) import RulesEngine

@_spi(HostOnly)
public enum EngineBuilder {
    /// Builds an engine for `ruleset`. Throws `SimulationError` when the
    /// document uses something the simulator does not model yet.
    public static func build(from ruleset: ResolvedRuleset) throws -> Engine {
        let document = ruleset.document
        guard let phases = document.phases, !phases.isEmpty else {
            throw SimulationError.config("document has no phases")
        }
        let players = document.players
        guard let seatCount = players?.defaultCount ?? players?.counts.first, seatCount > 0 else {
            throw SimulationError.config("no player count to simulate")
        }

        // Host-mediated expression evaluation (§7.5): mechanics and phase
        // `when` gates reach the runtime through closures built here.
        let runtime = try ExpressionRuntime(doc: document, seatCount: seatCount)

        // Zone keys: seat-scoped zones fan out per seat, team-scoped zones
        // per team, shared zones once. The team layout is mapped first so
        // team-scoped zones can fan out to the declared team count.
        var seatZoneIds: Set<String> = []
        var sharedZoneIds: Set<String> = []
        var capacities: [ZoneKey: Int?] = [:]
        let teams = try EngineBuilder.mapTeams(players, seatCount: seatCount)
        let teamCount = Set(teams.teamOfSeat).count
        for decl in document.zones ?? [] {
            switch decl.scope {
            case "seat":
                seatZoneIds.insert(decl.id)
                for seat in 0..<seatCount {
                    let key = ZoneKey(scope: .seat, owner: seat, id: decl.id)
                    capacities[key] = decl.capacity
                }
            case "shared":
                sharedZoneIds.insert(decl.id)
                let key = ZoneKey(scope: .shared, id: decl.id)
                capacities[key] = decl.capacity
            case "team":
                for team in 0..<max(1, teamCount) {
                    let key = ZoneKey(scope: .team, owner: team, id: decl.id)
                    capacities[key] = decl.capacity
                }
            default:
                throw SimulationError.unsupported("zone scope '\(decl.scope)' for '\(decl.id)'")
            }
        }

        // Deck → faces; the deal phase must name the shared zone to fill.
        var deckFaces: [CardFace]?
        if let deck = document.deck {
            deckFaces = try DeckCatalog.resolve(cardModelDeck(deck))
        }

        // Variables, teams, and rank orders are substrate data the phase
        // mappers read (auction ladders name an order; result paths name a
        // var), so they map before the phases. Teams are already mapped
        // above for team-scoped zones.
        let vars = try EngineBuilder.mapVars(document.vars)
        var orders: [String: [String]] = [:]
        for field in document.orders ?? [] {
            guard let ranks = field.value.arrayValue?.compactMap(\.stringValue) else {
                throw SimulationError.config("order '\(field.key)' must be an array of rank names")
            }
            orders[field.key] = ranks
        }

        let (enginePhases, dealPhaseID) = try phaseConfigs(
            phases, runtime: runtime, seatCount: seatCount,
            seatZoneIds: seatZoneIds, sharedZoneIds: sharedZoneIds, deckFaces: deckFaces,
            orders: orders, vars: vars)

        // Match substrate (§5.2–5.3, §5.6–5.8): the end declaration and the
        // first-dealer procedure. A ruleset without a `setup` block (the
        // P2-era fixtures) deals from seat 0, rotating left.
        let endSpec = try EngineBuilder.mapEnd(document.end, vars: vars)
        let (firstDealer, rotation) = try EngineBuilder.firstDealerSetup(
            document.setup, seatCount: seatCount, deckFaces: deckFaces ?? [], orders: orders)

        let zoneCaps = capacities
        let dealerPick = firstDealer
        let setup: @Sendable (inout GameState) throws -> Void = { state in
            for (key, capacity) in zoneCaps {
                state.zones.ensureDeclared(key, capacity: capacity ?? nil)
            }
            // First-dealer pick (§5.6): draws from the run's own seeded RNG,
            // so a seed replays the pick exactly.
            try dealerPick(&state)
            // The deck itself is stacked by DealMechanic from `deckFaces`
            // (declares the source if empty, then shuffles and assigns fresh
            // deal-order CardIDs); setup only declares zones here.
        }

        // Per-deal reset (§5.7): finishDeal wipes the zone store between
        // deals, so the engine calls `rebuild` to re-declare every zone.
        // The deck is re-stacked by DealMechanic; first-dealer picking is
        // a setup-only step (the deal phase's rotation moves the dealer).
        let rebuild: @Sendable (inout GameState) throws -> Void = { state in
            for (key, capacity) in zoneCaps {
                state.zones.ensureDeclared(key, capacity: capacity ?? nil)
            }
        }

        // Host-mediated expression evaluation (§7.5): mechanics reach the
        // runtime through `ctx.eval`.
        let eval: @Sendable (EvalCall, GameState) throws(EvalFailure) -> EvalValue = { call, state in
            try runtime.evaluate(call, state)
        }
        return Engine(
            phases: enginePhases, seatCount: seatCount, setup: setup,
            expressionRuntime: eval, vars: vars, seatNames: players?.seatNames ?? [],
            teamNames: teams.names, teamOfSeat: teams.teamOfSeat,
            dealPhaseID: dealPhaseID, end: endSpec, rebuild: rebuild,
            dealerRotation: rotation)
    }

    // MARK: - deal

    static func dealPackets(
        _ packets: [DealPacket], phaseId: String, seatCount: Int,
        seatZones: Set<String>, sharedZones: Set<String>
    ) throws -> [RulesEngine.DealPacket] {
        var out: [RulesEngine.DealPacket] = []
        for (index, packet) in packets.enumerated() {
            let faceUp = packet.faceUp ?? false
            let each = try countValue(packet.each, pointer: "/phases/\(phaseId)/packets/\(index)/each")
            let count = try countValue(packet.count, pointer: "/phases/\(phaseId)/packets/\(index)/count")
            if seatZones.contains(packet.to) {
                for seat in 0..<seatCount {
                    out.append(
                        RulesEngine.DealPacket(
                            to: ZoneKey(scope: .seat, owner: seat, id: packet.to),
                            each: each.fixed ?? 0, packets: 1, count: count.fixed, faceUp: faceUp,
                            eachExpr: each.expr, countExpr: count.expr))
                }
            } else if sharedZones.contains(packet.to) {
                out.append(
                    RulesEngine.DealPacket(
                        to: ZoneKey(scope: .shared, id: packet.to),
                        each: each.fixed ?? 0, packets: 1, count: count.fixed, faceUp: faceUp,
                        eachExpr: each.expr, countExpr: count.expr))
            } else {
                throw SimulationError.config("deal packet target '\(packet.to)' is not a declared zone")
            }
        }
        return out
    }

    /// Wraps a JSON `each`/`count` value: integers pass through as fixed
    /// counts, expressions are kept in source form for deal-time evaluation.
    private static func countValue(
        _ value: NumOrExpr?, pointer: String
    ) throws -> (fixed: Int?, expr: RulesEngine.DealCountExpr?) {
        switch value {
        case .int(let n): return (n, nil)
        case .expr(let expr): return (nil, RulesEngine.DealCountExpr(source: expr.source, pointer: pointer))
        case nil: return (nil, nil)
        }
    }

    // MARK: - trick-play

    static func trickPlayParams(
        _ params: TrickPlayParams, phaseId: String,
        seatCount: Int
    ) throws -> RulesEngine.TrickPlayParams {
        // How many tricks the phase plays: a count, the `untilHandsEmpty`
        // keyword, or a constant expression.
        let tricks: RulesEngine.TrickPlayParams.TricksSpec
        switch params.tricks {
        case .count(let n):
            guard n > 0 else {
                throw SimulationError.config("trick count \(n) must be positive")
            }
            tricks = .count(n)
        case .text("untilHandsEmpty"):
            tricks = .untilHandsEmpty
        case .text(let text):
            let n = try constantInt(text, param: "\(phaseId).tricks")
            guard n > 0 else {
                throw SimulationError.config("trick count \(n) must be positive")
            }
            tricks = .count(n)
        case nil:
            throw SimulationError.config("trick-play phase '\(phaseId)' has no tricks count")
        }

        // Rank order: "natural" (or absent) means standard ascending order,
        // which the engine models with its default `orderRanks`.
        if let order = params.order {
            guard order == "natural" else {
                throw SimulationError.unsupported("card order '\(order)'")
            }
        }

        let follow = RulesEngine.TrickPlayParams.Follow(
            mustFollow: params.follow?.mustFollow ?? true,
            mustTrumpIfVoid: params.follow?.mustTrumpIfVoid ?? false,
            mustOvertrump: params.follow?.mustOvertrump ?? false,
            mustHeadTrick: params.follow?.mustHeadTrick ?? false,
            ruleId: params.follow?.rule ?? "follow")

        // Trump: the literal "none" means no trump suit; anything else is a
        // runtime expression evaluated at phase entry.
        let trump: RulesEngine.SuitOrExpr?
        if let t = params.trump, t.source != "none" {
            trump = .expr(ExprRef(pointer: "\(phaseId).trump", source: t.source))
        } else {
            trump = nil
        }

        let winner = try trickWinner(params, trump: trump, phaseId: phaseId)

        return RulesEngine.TrickPlayParams(
            seatCount: seatCount,
            tricks: tricks,
            follow: follow,
            leadAllowed: try params.leadAllowed.map {
                try playGuard($0, phaseId: phaseId, key: "leadAllowed")
            },
            playAllowed: try params.playAllowed.map {
                try playGuard($0, phaseId: phaseId, key: "playAllowed")
            },
            suitOf: params.suitOf.map {
                ExprRef(pointer: "\(phaseId).suitOf", source: $0.source)
            },
            strength: params.strength.map {
                ExprRef(pointer: "\(phaseId).strength", source: $0.source)
            },
            trump: trump,
            activeSeats: params.activeSeats.map {
                .expr(ExprRef(pointer: "\(phaseId).activeSeats", source: $0.source))
            },
            firstLeader: params.firstLeader.map {
                .expr(ExprRef(pointer: "\(phaseId).firstLeader", source: $0.source))
            },
            nextLeader: params.nextLeader.map {
                ExprRef(pointer: "\(phaseId).nextLeader", source: $0.source)
            },
            winner: winner,
            dummy: try params.dummy.map {
                try dummySpec($0, phaseId: phaseId)
            },
            claims: try params.claims.map {
                try claimsSpec($0, phaseId: phaseId)
            },
            onCardPlayed: try mapEffects(params.onCardPlayedEffects),
            onTrickEnd: try mapEffects(params.onTrickEndEffects))
    }

    /// The trick winner rule: a built-in name (`highestOfLedSuit`,
    /// `highestTrumpElseLedSuit`) or a user definition referenced by name.
    private static func trickWinner(
        _ params: TrickPlayParams, trump: RulesEngine.SuitOrExpr?,
        phaseId: String
    ) throws -> RulesEngine.TrickPlayParams.WinnerSpec {
        switch params.winner?.source {
        case "highestOfLedSuit", nil:
            if trump != nil {
                throw SimulationError.config(
                    "trump set but winnerRule is not 'highestTrumpElseLedSuit'")
            }
            return .highestOfLed
        case "highestTrumpElseLedSuit":
            guard trump != nil else {
                throw SimulationError.config(
                    "winnerRule 'highestTrumpElseLedSuit' needs a trump expression")
            }
            return .highestTrumpElseLed
        case let custom?:
            return .custom(ExprRef(pointer: "\(phaseId).winner", source: custom))
        }
    }

    private static func playGuard(
        _ guardSpec: PlayGuard, phaseId: String, key: String
    ) throws -> RulesEngine.TrickPlayParams.PlayGuard {
        RulesEngine.TrickPlayParams.PlayGuard(
            expr: ExprRef(pointer: "\(phaseId).\(key).expr", source: guardSpec.expr.source),
            otherwise: guardSpec.otherwise,
            ruleId: guardSpec.rule)
    }

    private static func dummySpec(
        _ spec: DummySpec, phaseId: String
    ) throws -> RulesEngine.TrickPlayParams.DummySpec {
        let revealAfter: RulesEngine.TrickPlayParams.DummySpec.RevealAfter
        switch spec.revealAfter {
        case "openingLead": revealAfter = .afterLead
        case "immediately": revealAfter = .immediately
        case let other: throw SimulationError.unsupported("dummy.revealAfter '\(other)'")
        }
        return RulesEngine.TrickPlayParams.DummySpec(
            seat: .expr(ExprRef(pointer: "\(phaseId).dummy.seat", source: spec.seat.source)),
            revealAfter: revealAfter,
            controlledBy: .expr(
                ExprRef(pointer: "\(phaseId).dummy.controlledBy", source: spec.controlledBy.source)),
            ruleId: spec.rule)
    }

    private static func claimsSpec(
        _ spec: ClaimsSpec, phaseId: String
    ) throws -> RulesEngine.TrickPlayParams.ClaimsSpec {
        RulesEngine.TrickPlayParams.ClaimsSpec(
            enabled: spec.enabled.map {
                ExprRef(pointer: "\(phaseId).claims.enabled", source: $0.source)
            },
            by: spec.by.map {
                .expr(ExprRef(pointer: "\(phaseId).claims.by", source: $0.source))
            },
            acceptedBy: spec.acceptedBy.map {
                ExprRef(pointer: "\(phaseId).claims.acceptedBy", source: $0.source)
            },
            ruleId: spec.rule)
    }

    // MARK: - deck conversion

    /// Schema deck spec (§5.2) → CardModel spec. Bases are built-in pack
    /// template ids resolved through `DeckCatalog.spec`; `custom`/`faces`
    /// inline packs are not modeled by the simulator yet.
    private static func cardModelDeck(_ deck: DeckSpec) throws -> CardModel.DeckSpec {
        guard let base = deck.base, base != "custom" else {
            throw SimulationError.unsupported("inline deck (custom/faces)")
        }
        guard let template = DeckCatalog.spec(for: base) else {
            throw SimulationError.config("unknown deck base '\(base)'")
        }
        let extraAdd = try (deck.add ?? []).map(parseFace)
        return CardModel.DeckSpec(
            base: template.base, copies: deck.copies ?? template.copies,
            remove: template.remove + (deck.remove ?? []),
            add: template.add + extraAdd)
    }

    /// Suit codes across all suit systems (CardModel.Suit codes).
    static let suitCodes: Set<String> = [
        "S", "H", "D", "C", "T", "Ei", "Gr", "Hz", "Sc", "Or", "Co", "Es", "Ba", "De", "Sp",
    ]

    /// Parse a face id such as "QS", "10H", "OEi", "T21", "JokerBig" into a
    /// CardFace: longest matching suit-code suffix wins; trumps are suit-first.
    static func parseFace(_ id: String) throws -> CardFace {
        if id.hasPrefix("T"), id.count > 1,
            id.dropFirst().allSatisfy(\.isNumber)
        {
            return CardFace(suit: Suit("T"), rank: Rank(String(id.dropFirst())))
        }
        let maxSuffix = min(2, max(0, id.count - 1))
        if maxSuffix >= 1 {
            for length in stride(from: maxSuffix, through: 1, by: -1) {
                let idx = id.index(id.endIndex, offsetBy: -length)
                let suffix = String(id[idx...])
                if suitCodes.contains(suffix) {
                    let rankCode = String(id[..<idx])
                    if !rankCode.isEmpty {
                        return CardFace(suit: Suit(suffix), rank: Rank(rankCode))
                    }
                }
            }
        }
        return CardFace(suit: nil, rank: Rank(id))
    }

    // MARK: - constants

    /// Numeric constant from a NumOrExpr; expressions are unsupported.
    private static func constant(_ value: NumOrExpr?, param: String) throws -> Int? {
        switch value {
        case .int(let n): return n
        case .expr(let expr): return try constantInt(expr.source, param: param)
        case nil: return nil
        }
    }

    private static func constantInt(_ source: String, param: String) throws -> Int {
        let ast = try parseConstant(source, param: param)
        guard case .int(let n, _) = ast else {
            throw SimulationError.unsupported("non-constant \(param) expression '\(source)'")
        }
        guard n >= 0, n <= Int.max else {
            throw SimulationError.config("\(param) \(n) is out of range")
        }
        return Int(n)
    }

    private static func constantSeat(_ source: String, param: String) throws -> Seat {
        Seat(try constantInt(source, param: param))
    }

    private static func constantSeats(_ source: String, param: String) throws -> [Seat] {
        let ast = try parseConstant(source, param: param)
        guard case .list(let items, _) = ast else {
            throw SimulationError.unsupported("non-constant \(param) expression '\(source)'")
        }
        var seats: [Seat] = []
        for item in items {
            guard case .int(let n, _) = item, n >= 0, n <= Int.max else {
                throw SimulationError.unsupported("\(param) entries must be seat indexes")
            }
            seats.append(Seat(Int(n)))
        }
        return seats
    }

    private static func constantString(_ source: String, param: String) throws -> String {
        let ast = try parseConstant(source, param: param)
        guard case .string(let s, _) = ast else {
            throw SimulationError.unsupported("non-constant \(param) expression '\(source)'")
        }
        return s
    }

    static func parseConstant(_ source: String, param: String) throws -> AST {
        do {
            return try Parser().parse(source).ast
        } catch {
            throw SimulationError.config("\(param): cannot parse '\(source)' (\(error))")
        }
    }
}
