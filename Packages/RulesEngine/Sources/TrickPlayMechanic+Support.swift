import CardModel

// Trick-play support: claims, turn order, winner selection, card
// strength, dummy reveals, and small helpers (§5.6).
extension TrickPlayMechanic {
    // MARK: - Claims

    static func applyClaim(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard case .claim(let n) = intent else {
            throw RuleViolation.engineFault(ruleId: "trick.claim", pointer: "claim intent shape")
        }
        let sub = state.trickSubstate()
        guard sub.pendingClaim == nil, sub.claimedBy == nil, sub.currentPlays.isEmpty else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        guard let claims = params.claims, !sub.claimVoters.contains(seat) else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        guard let enabled = claims.enabled else {
            throw RuleViolation.illegal(
                ruleId: claims.ruleId ?? "trick.claim", detail: .custom("claims are not enabled"))
        }
        let on = try ctx.evalCall(
            .init(pointer: "/phases/trick-play/claims/enabled", source: enabled.source, ruleId: claims.ruleId),
            state: state)
        guard on == .bool(true) else {
            throw RuleViolation.illegal(
                ruleId: claims.ruleId ?? "trick.claim", detail: .custom("claims are not enabled"))
        }
        guard let claimant = try? claimantSeat(params, claims: claims, state: state, ctx: ctx),
            seat == claimant
        else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        let remaining = remainingTricks(params, state: state)
        guard remaining > 0, n == remaining else {
            throw RuleViolation.illegal(
                ruleId: claims.ruleId ?? "trick.claim", detail: .custom("claim must cover the remaining tricks"))
        }
        state.mutateSubstate { $0.pendingClaim = seat }
        return [.emitted(name: "claim.made")]
    }

    static func applyAccept(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard case .acceptClaim(let accepted) = intent else {
            throw RuleViolation.engineFault(ruleId: "trick.claim", pointer: "acceptClaim intent shape")
        }
        var sub = state.trickSubstate()
        guard let claimant = sub.pendingClaim else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        guard sub.claimVoters.contains(seat), !sub.claimVotes.contains(seat) else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        if !accepted {
            state.mutateSubstate {
                $0.pendingClaim = nil
                $0.claimVotes = []
            }
            return [.emitted(name: "claim.rejected")]
        }
        state.mutateSubstate { $0.claimVotes.append(seat) }
        sub = state.trickSubstate()
        guard sub.claimVotes.count == sub.claimVoters.count else {
            return [.emitted(name: "claim.accepted")]
        }
        // Every voter accepted: award the remaining tricks to the claimant.
        let remaining = remainingTricks(params, state: state)
        state.mutateSubstate {
            $0.tricksWon[claimant.raw] += remaining
            $0.claimedBy = claimant
            $0.pendingClaim = nil
            $0.claimVotes = []
            $0.currentPlays = []
        }
        return [
            .scored(
                seat: claimant, points: remaining, reason: "claim",
                ruleId: params.claims?.ruleId),
            .emitted(name: "claim.awarded"),
        ]
    }

    /// The seats who may propose a claim right now.
    static func claimantSeat(
        _ params: Params, claims: TrickPlayParams.ClaimsSpec, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat? {
        guard let spec = claims.by else { return nil }
        return try seatOf(spec, pointer: "/phases/trick-play/claims/by", state: state, ctx: ctx)
    }

    /// How many tricks remain to be played.
    static func remainingTricks(_ params: Params, state: GameState) -> Int {
        let sub = state.trickSubstate()
        switch params.tricks {
        case .count(let n): return max(0, n - sub.trickIndex)
        case .untilHandsEmpty:
            let cards = sub.activeSeats.reduce(0) { $0 + state.zones.cards(in: handKey($1)).count }
            let perTrick = max(1, sub.activeSeats.count)
            return (cards + perTrick - 1) / perTrick
        }
    }

    // MARK: - Turn order

    /// The seat whose turn it is to play (may be the dummy).
    static func nextToAct(_ params: Params, state: GameState, ctx: EvalContext) -> Seat? {
        let sub = state.trickSubstate()
        if sub.claimedBy != nil || sub.pendingClaim != nil { return nil }
        guard sub.currentPlays.count < sub.activeSeats.count else { return nil }
        let index = sub.activeSeats.firstIndex(of: sub.leader) ?? 0
        let seat = sub.activeSeats[(index + sub.currentPlays.count) % sub.activeSeats.count]
        // A seat with no cards cannot act; if nobody holds cards and no plays are
        // pending, the trick has nothing left to resolve.
        guard
            sub.currentPlays.isEmpty
                ? !state.zones.cards(in: handKey(seat)).isEmpty
                : true
        else { return nil }
        return seat
    }

    /// Who issues the intents for a turn seat: the controller plays for
    /// the dummy.
    static func actor(for turn: Seat, sub: TrickSubstate) -> Seat {
        if let dummy = sub.dummySeat, turn == dummy { return sub.dummyController ?? turn }
        return turn
    }

    // MARK: - Winner

    static func winnerOf(
        _ params: Params, sub: TrickSubstate, plays: [TrickSubstate.Play], pile: [CardInstance],
        state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        switch params.winner {
        case .highestOfLed, .highestTrumpElseLed:
            let led = sub.ledSuit
            var best: (seat: Seat, strength: Int)?
            for play in plays {
                guard let instance = pile.first(where: { $0.id == play.card }) else { continue }
                let suit = effectiveSuit(params, instance, state: state, ctx: ctx)
                let isTrump = sub.trumpSuit != nil && suit == sub.trumpSuit
                let counts = params.winner == .highestOfLed ? suit == led : (isTrump || suit == led)
                guard counts else { continue }
                let value = cardStrength(params, instance, state: state, ctx: ctx)
                if best == nil || value > best!.strength { best = (play.seat, value) }
            }
            return best?.seat ?? plays.first?.seat ?? sub.leader
        case .custom(let ref):
            var playRecords: [EvalValue] = []
            for play in plays {
                guard let instance = pile.first(where: { $0.id == play.card }) else { continue }
                playRecords.append(
                    .record(
                        name: "play",
                        fields: [
                            "seat": .string(spelling(play.seat, ctx)),
                            "card": .string(String(instance.id.raw)),
                            "suit": .string(effectiveSuit(params, instance, state: state, ctx: ctx)),
                            "rank": .string(instance.face.rank.code),
                        ]))
            }
            let value = try ctx.evalCall(
                .init(
                    pointer: "/phases/trick-play/winner", source: ref.source, ruleId: nil,
                    contextual: [
                        "leader": .string(spelling(sub.leader, ctx)),
                        "plays": .list(playRecords),
                    ]),
                state: state)
            guard let seat = seatValue(of: value, ctx: ctx) else {
                throw RuleViolation.engineFault(
                    ruleId: nil, pointer: "/phases/trick-play/winner not a seat")
            }
            return seat
        }
    }

    // MARK: - Card strength

    /// The effective suit of a card: `suitOf` def if provided, else the
    /// printed suit.
    static func effectiveSuit(
        _ params: Params, _ instance: CardInstance, state: GameState, ctx: EvalContext
    ) -> String {
        guard let ref = params.suitOf else { return instance.face.suit?.code ?? "" }
        guard
            case .string(let suit)? = try? ctx.evalCall(
                .init(
                    pointer: "/phases/trick-play/suitOf", source: ref.source, ruleId: nil,
                    contextual: ["c": cardValue(instance)]),
                state: state)
        else { return instance.face.suit?.code ?? "" }
        return suit
    }

    /// A card's trick strength: `strength` def if provided, else the
    /// rank's position in `orderRanks`.
    static func cardStrength(
        _ params: Params, _ instance: CardInstance, state: GameState, ctx: EvalContext
    ) -> Int {
        guard let ref = params.strength else {
            return params.orderRanks.firstIndex(of: instance.face.rank.code).map { $0 + 1 } ?? 0
        }
        guard
            case .int(let raw)? = try? ctx.evalCall(
                .init(
                    pointer: "/phases/trick-play/strength", source: ref.source, ruleId: nil,
                    contextual: ["c": cardValue(instance)]),
                state: state)
        else { return params.orderRanks.firstIndex(of: instance.face.rank.code).map { $0 + 1 } ?? 0 }
        return Int(exactly: raw) ?? 0
    }

    /// Highest strength among the trick's cards of one effective suit.
    static func bestStrength(
        _ params: Params, _ sub: TrickSubstate, suit: String?, pile: [CardInstance],
        state: GameState, ctx: EvalContext
    ) -> Int? {
        guard let suit else { return nil }
        var best: Int?
        for play in sub.currentPlays {
            guard let instance = pile.first(where: { $0.id == play.card }) else { continue }
            guard effectiveSuit(params, instance, state: state, ctx: ctx) == suit else { continue }
            let value = cardStrength(params, instance, state: state, ctx: ctx)
            if best == nil || value > best! { best = value }
        }
        return best
    }

    static func pileOf(_ state: GameState, _ sub: TrickSubstate) -> [CardInstance] {
        state.zones.cards(in: ZoneKey(scope: .shared, id: "trick\(sub.trickIndex)"))
    }

    /// Evaluates a guard predicate over the candidate card.
    static func playAllowed(
        _ params: Params, _ guardSpec: TrickPlayParams.PlayGuard, card: CardInstance,
        state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Bool {
        let value = try ctx.evalCall(
            .init(
                pointer: "/phases/trick-play/playAllowed", source: guardSpec.expr.source,
                ruleId: guardSpec.ruleId,
                contextual: ["card": cardValue(card)]),
            state: state)
        guard case .bool(let allowed) = value else {
            throw RuleViolation.engineFault(
                ruleId: guardSpec.ruleId, pointer: "/phases/trick-play/playAllowed not a bool")
        }
        return allowed
    }

    // MARK: - Dummy

    static func dummySeat(
        _ params: Params, dummy: TrickPlayParams.DummySpec, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        try seatOf(dummy.seat, pointer: "/phases/trick-play/dummy/seat", state: state, ctx: ctx)
    }

    static func controlledSeat(
        _ params: Params, dummy: TrickPlayParams.DummySpec, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        try seatOf(
            dummy.controlledBy, pointer: "/phases/trick-play/dummy/controlledBy", state: state, ctx: ctx)
    }

    static func revealDummy(
        _ state: inout GameState, seat: Seat, pointer: String
    ) throws(RuleViolation) -> [GameEvent] {
        let hand = handKey(seat)
        let cards = state.zones.cards(in: hand)
        for instance in cards { state.knowledge.makePublic(instance.id) }
        return [.revealed(zone: "hand[\(seat.raw)]", cards: cards)]
    }

    // MARK: - Helpers

    static func handKey(_ seat: Seat) -> ZoneKey {
        ZoneKey(scope: .seat, owner: seat.raw, id: "hand")
    }

    static func cardValue(_ instance: CardInstance) -> EvalValue {
        .card(
            id: instance.face.id,
            suit: instance.face.suit?.code ?? "",
            rank: instance.face.rank.code)
    }

    static func spelling(_ seat: Seat, _ ctx: EvalContext) -> String {
        ctx.seatNames.indices.contains(seat.raw) ? ctx.seatNames[seat.raw] : "S\(seat.raw + 1)"
    }

    /// Resolves a seat spec: a literal seat, or an evaluated expression.
    static func seatOf(
        _ spec: SeatOrExpr, pointer: String, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        switch spec {
        case .seat(let seat): return seat
        case .expr(let ref):
            let value = try ctx.evalCall(
                .init(pointer: pointer, source: ref.source, ruleId: nil), state: state)
            guard let seat = seatValue(of: value, ctx: ctx) else {
                throw RuleViolation.engineFault(ruleId: nil, pointer: "\(pointer) not a seat")
            }
            return seat
        }
    }

    /// Resolves a seat-list spec: literal seats, or an evaluated expression.
    static func seatList(
        _ spec: SeatListOrExpr, pointer: String, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [Seat] {
        switch spec {
        case .seats(let seats): return seats
        case .expr(let ref):
            let value = try ctx.evalCall(
                .init(pointer: pointer, source: ref.source, ruleId: nil), state: state)
            guard case .list(let names) = value, !names.isEmpty else {
                throw RuleViolation.engineFault(
                    ruleId: nil, pointer: "\(pointer) not a non-empty seat list")
            }
            var seats: [Seat] = []
            for item in names {
                guard let seat = seatValue(of: item, ctx: ctx) else {
                    throw RuleViolation.engineFault(
                        ruleId: nil, pointer: "\(pointer) not a seat list")
                }
                seats.append(seat)
            }
            return seats
        }
    }

    /// Parses a seat value back: a setup seat spelling, or the `S<n>`
    /// fallback spelling.
    static func seatValue(of value: EvalValue, ctx: EvalContext) -> Seat? {
        guard case .string(let name) = value else { return nil }
        if let index = ctx.seatNames.firstIndex(of: name) { return Seat(index) }
        guard name.hasPrefix("S"), let raw = Int(name.dropFirst()), raw >= 1,
            raw <= ctx.seatCount
        else { return nil }
        return Seat(raw - 1)
    }
}
