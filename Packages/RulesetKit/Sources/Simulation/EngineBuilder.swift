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

        // Zone keys: seat-scoped zones fan out per seat; team-scoped zones
        // need a team layout the P2.8 simulator does not model.
        var seatZoneIds: Set<String> = []
        var sharedZoneIds: Set<String> = []
        var capacities: [ZoneKey: Int?] = [:]
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
            default:
                throw SimulationError.unsupported("team-scoped zone '\(decl.id)'")
            }
        }

        // Deck → faces; the deal phase must name the shared zone to fill.
        var deckFaces: [CardFace]?
        if let deck = document.deck {
            deckFaces = try DeckCatalog.resolve(cardModelDeck(deck))
        }

        var enginePhases: [PhaseConfig] = []
        for phase in phases {
            guard phase.when == nil, phase.before == nil, phase.after == nil, phase.next == nil else {
                throw SimulationError.unsupported("phase-level flow control on '\(phase.id)'")
            }
            let config: PhaseConfig
            switch (phase.mechanic, phase.params) {
            case ("deal", .deal(let params)):
                guard let sourceId = params.source else {
                    throw SimulationError.config("deal phase '\(phase.id)' has no source")
                }
                guard params.thenEffects == nil else {
                    throw SimulationError.unsupported("deal.then effects")
                }
                let packets = try dealPackets(
                    params.packets, seatCount: seatCount,
                    seatZones: seatZoneIds, sharedZones: sharedZoneIds)
                config = PhaseConfig(
                    id: phase.id,
                    mechanic: AnyMechanic(
                        DealMechanic.self,
                        params: RulesEngine.DealParams(
                            source: sourceId, packets: packets, shuffleFirst: true,
                            deckFaces: deckFaces)))
            case ("trick-play", .trickPlay(let params)):
                let engineParams = try trickPlayParams(params, phaseId: phase.id, seatCount: seatCount)
                config = PhaseConfig(
                    id: phase.id,
                    mechanic: AnyMechanic(
                        TrickPlayMechanic.self, params: engineParams))
            case (let mechanic, _):
                throw SimulationError.unsupported("mechanic '\(mechanic)'")
            }
            enginePhases.append(config)
        }

        let zoneCaps = capacities
        let setup: @Sendable (inout GameState) throws -> Void = { state in
            for (key, capacity) in zoneCaps {
                state.zones.ensureDeclared(key, capacity: capacity ?? nil)
            }
            // The deck itself is stacked by DealMechanic from `deckFaces`
            // (declares the source if empty, then shuffles and assigns fresh
            // deal-order CardIDs); setup only declares zones here.
        }
        return Engine(phases: enginePhases, seatCount: seatCount, setup: setup)
    }

    // MARK: - deal

    private static func dealPackets(
        _ packets: [DealPacket], seatCount: Int,
        seatZones: Set<String>, sharedZones: Set<String>
    ) throws -> [RulesEngine.DealPacket] {
        var out: [RulesEngine.DealPacket] = []
        for packet in packets {
            let faceUp = packet.faceUp ?? false
            if faceUp { throw SimulationError.unsupported("face-up deal packets") }
            let each = try constant(packet.each, param: "each")
            let count = try constant(packet.count, param: "count")
            if seatZones.contains(packet.to) {
                for seat in 0..<seatCount {
                    out.append(
                        RulesEngine.DealPacket(
                            to: ZoneKey(scope: .seat, owner: seat, id: packet.to),
                            each: each ?? 0, packets: 1, count: count, faceUp: faceUp))
                }
            } else if sharedZones.contains(packet.to) {
                out.append(
                    RulesEngine.DealPacket(
                        to: ZoneKey(scope: .shared, id: packet.to),
                        each: each ?? 0, packets: 1, count: count, faceUp: faceUp))
            } else {
                throw SimulationError.config("deal packet target '\(packet.to)' is not a declared zone")
            }
        }
        return out
    }

    // MARK: - trick-play

    private static func trickPlayParams(
        _ params: TrickPlayParams, phaseId: String,
        seatCount: Int
    ) throws -> RulesEngine.TrickPlayParams {
        try rejectUnsupportedTrickPlay(params)

        let tricks: Int
        switch params.tricks {
        case .count(let n): tricks = n
        case .text(let text): tricks = try constantInt(text, param: "\(phaseId).tricks")
        case nil: throw SimulationError.config("trick-play phase '\(phaseId)' has no tricks count")
        }
        guard tricks > 0 else {
            throw SimulationError.config("trick count \(tricks) must be positive")
        }

        let activeSeats: [Seat]
        if let expr = params.activeSeats {
            activeSeats = try constantSeats(expr.source, param: "activeSeats")
        } else {
            activeSeats = (0..<seatCount).map { Seat($0) }
        }
        guard !activeSeats.isEmpty else {
            throw SimulationError.config("trick-play phase '\(phaseId)' has no active seats")
        }

        let firstLeader: Seat
        if let expr = params.firstLeader {
            firstLeader = try constantSeat(expr.source, param: "firstLeader")
        } else {
            firstLeader = Seat(0)
        }

        let winnerRule = try trickWinnerRule(params)
        let followRuleId = try trickFollowRule(params.follow)

        return RulesEngine.TrickPlayParams(
            seatCount: seatCount, tricks: tricks,
            activeSeats: activeSeats, firstLeader: firstLeader,
            winnerRule: winnerRule, followRuleId: followRuleId)
    }

    /// Rejected extras: anything the P1 engine does not model.
    private static func rejectUnsupportedTrickPlay(_ params: TrickPlayParams) throws {
        for (name, present) in [
            ("suitOf", params.suitOf), ("strength", params.strength),
            ("winner", params.winner), ("nextLeader", params.nextLeader),
        ] where present != nil {
            throw SimulationError.unsupported("trick-play.\(name) expression")
        }
        if params.leadAllowed != nil || params.playAllowed != nil {
            throw SimulationError.unsupported("trick-play play guards")
        }
        if params.dummy != nil { throw SimulationError.unsupported("trick-play dummy") }
        if params.claims != nil { throw SimulationError.unsupported("trick-play claims") }
        if params.onCardPlayedEffects != nil || params.onTrickEndEffects != nil {
            throw SimulationError.unsupported("trick-play effects")
        }
        if let order = params.order, order != "desc" {
            throw SimulationError.unsupported("card order '\(order)'")
        }
        if let firstLeaderRule = params.firstLeaderRule {
            throw SimulationError.unsupported("firstLeaderRule '\(firstLeaderRule)'")
        }
    }

    private static func trickWinnerRule(_ params: TrickPlayParams) throws -> TrickWinnerRule {
        switch params.winnerRule {
        case "highestOfLedSuit", nil:
            if params.trump != nil {
                throw SimulationError.config("trump set but winnerRule is not 'highestTrumpElseLedSuit'")
            }
            return .highestOfLed
        case "highestTrumpElseLedSuit":
            guard let trumpExpr = params.trump else {
                throw SimulationError.config("winnerRule 'highestTrumpElseLedSuit' needs a trump expression")
            }
            let trump = try constantString(trumpExpr.source, param: "trump")
            return .highestWithTrump(trump: trump)
        case let other:
            throw SimulationError.unsupported("winnerRule '\(other)'")
        }
    }

    private static func trickFollowRule(_ follow: FollowRules?) throws -> String {
        var followRuleId = "follow"
        if let follow = follow {
            if follow.mustFollow == false {
                throw SimulationError.unsupported("follow.mustFollow = false")
            }
            if follow.mustTrumpIfVoid == true || follow.mustOvertrump == true || follow.mustHeadTrick == true {
                throw SimulationError.unsupported("trump-follow obligations")
            }
            if let rule = follow.rule { followRuleId = rule }
        }
        return followRuleId
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

    private static func parseConstant(_ source: String, param: String) throws -> AST {
        do {
            return try Parser().parse(source).ast
        } catch {
            throw SimulationError.config("\(param): cannot parse '\(source)' (\(error))")
        }
    }
}
