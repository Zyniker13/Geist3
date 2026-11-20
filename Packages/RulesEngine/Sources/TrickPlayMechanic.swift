import CardModel

/// A seat named literally, or by a ruleset expression (§5.6).
public enum SeatOrExpr: Codable, Hashable, Sendable {
    case seat(Seat)
    case expr(ExprRef)
}

/// A list of seats named literally, or by a ruleset expression (§5.6).
public enum SeatListOrExpr: Codable, Hashable, Sendable {
    case seats([Seat])
    case expr(ExprRef)
}

/// A suit named literally, or by a ruleset expression (§5.6).
public enum SuitOrExpr: Codable, Hashable, Sendable {
    case suit(String)
    case expr(ExprRef)
}

/// Parameters for the `trick-play` mechanic (§5.6).
///
/// Every ruleset-provided expression is carried as an `ExprRef`; the
/// engine evaluates them through the context's expression runtime and
/// maps any failure onto `RuleViolation.engineFault` (§7.4).
public struct TrickPlayParams: Codable, Hashable, Sendable {
    public let seatCount: Int

    /// How many tricks the phase plays.
    public enum TricksSpec: Codable, Hashable, Sendable {
        /// A fixed number of tricks.
        case count(Int)
        /// Play until every active seat's hand is empty.
        case untilHandsEmpty
    }
    public let tricks: TricksSpec

    /// Rank codes in ascending strength order, used when `strength` is
    /// not provided (e.g. `["2", …, "K", "A"]`).
    public let orderRanks: [String]

    /// Following rules (§5.6): which of must-follow / must-trump-when-void
    /// / must-overtrump / must-head-trick apply.
    public struct Follow: Codable, Hashable, Sendable {
        public let mustFollow: Bool
        public let mustTrumpIfVoid: Bool
        public let mustOvertrump: Bool
        public let mustHeadTrick: Bool
        public let ruleId: String
        public init(
            mustFollow: Bool = true, mustTrumpIfVoid: Bool = false,
            mustOvertrump: Bool = false, mustHeadTrick: Bool = false, ruleId: String
        ) {
            self.mustFollow = mustFollow
            self.mustTrumpIfVoid = mustTrumpIfVoid
            self.mustOvertrump = mustOvertrump
            self.mustHeadTrick = mustHeadTrick
            self.ruleId = ruleId
        }
    }
    public let follow: Follow

    /// An extra play guard: a predicate over the candidate card bound as
    /// `card`. `leadAllowed` applies to the trick's first card,
    /// `playAllowed` to every later play.
    public struct PlayGuard: Codable, Hashable, Sendable {
        public let expr: ExprRef
        public let otherwise: String
        public let ruleId: String?
        public init(expr: ExprRef, otherwise: String, ruleId: String? = nil) {
            self.expr = expr
            self.otherwise = otherwise
            self.ruleId = ruleId
        }
    }
    public let leadAllowed: PlayGuard?
    public let playAllowed: PlayGuard?

    /// Def returning the effective suit of a card (bound as `c`); nil
    /// means the card's printed suit. Needed for e.g. the euchre left
    /// bower.
    public let suitOf: ExprRef?
    /// Def returning a card's trick strength (bound as `c`); nil means
    /// the rank's position in `orderRanks`.
    public let strength: ExprRef?
    /// Trump suit for the deal, or `nil` in a trumpless game.
    public let trump: SuitOrExpr?
    /// Seats dealt in this phase; nil means every seat.
    public let activeSeats: SeatListOrExpr?
    /// Who leads the first trick; nil means the lowest raw seat.
    public let firstLeader: SeatOrExpr?
    /// Who leads the next trick, with `winner` bound to the previous
    /// trick's winner; nil means the winner.
    public let nextLeader: ExprRef?

    /// How the trick winner is decided.
    public enum WinnerSpec: Codable, Hashable, Sendable {
        /// Highest card of the led suit.
        case highestOfLed
        /// Highest trump, else highest of the led suit.
        case highestTrumpElseLed
        /// Def `name(leader, plays)` returning the winner seat; `plays`
        /// is a list of `{seat, card, suit, rank}` records.
        case custom(ExprRef)
    }
    public let winner: WinnerSpec

    /// Dummy play (§5.6): one seat's hand is revealed and played by
    /// another seat (contract bridge).
    public struct DummySpec: Codable, Hashable, Sendable {
        public enum RevealAfter: String, Codable, Hashable, Sendable {
            /// The hand is public from the start of the phase.
            case immediately
            /// The hand becomes public after the opening lead.
            case afterLead
        }
        public let seat: SeatOrExpr
        public let revealAfter: RevealAfter
        public let controlledBy: SeatOrExpr
        public let ruleId: String?
        public init(seat: SeatOrExpr, revealAfter: RevealAfter, controlledBy: SeatOrExpr, ruleId: String? = nil) {
            self.seat = seat
            self.revealAfter = revealAfter
            self.controlledBy = controlledBy
            self.ruleId = ruleId
        }
    }
    public let dummy: DummySpec?

    /// Claims (§5.6): a seat may claim the remaining tricks, accepted by
    /// the given defenders.
    public struct ClaimsSpec: Codable, Hashable, Sendable {
        public let enabled: ExprRef?
        public let by: SeatOrExpr?
        public let acceptedBy: ExprRef?
        public let ruleId: String?
        public init(enabled: ExprRef? = nil, by: SeatOrExpr? = nil, acceptedBy: ExprRef? = nil, ruleId: String? = nil) {
            self.enabled = enabled
            self.by = by
            self.acceptedBy = acceptedBy
            self.ruleId = ruleId
        }
    }
    public let claims: ClaimsSpec?

    /// Effects run after every card is played, with `seat` and `card`
    /// bound.
    public let onCardPlayed: [EngineEffect]
    /// Effects run when a trick is decided, with `trick` (a record
    /// carrying `winner`) bound.
    public let onTrickEnd: [EngineEffect]

    public init(
        seatCount: Int,
        tricks: TricksSpec,
        orderRanks: [String] = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"],
        follow: Follow,
        leadAllowed: PlayGuard? = nil,
        playAllowed: PlayGuard? = nil,
        suitOf: ExprRef? = nil,
        strength: ExprRef? = nil,
        trump: SuitOrExpr? = nil,
        activeSeats: SeatListOrExpr? = nil,
        firstLeader: SeatOrExpr? = nil,
        nextLeader: ExprRef? = nil,
        winner: WinnerSpec = .highestOfLed,
        dummy: DummySpec? = nil,
        claims: ClaimsSpec? = nil,
        onCardPlayed: [EngineEffect] = [],
        onTrickEnd: [EngineEffect] = []
    ) {
        self.seatCount = seatCount
        self.tricks = tricks
        self.orderRanks = orderRanks
        self.follow = follow
        self.leadAllowed = leadAllowed
        self.playAllowed = playAllowed
        self.suitOf = suitOf
        self.strength = strength
        self.trump = trump
        self.activeSeats = activeSeats
        self.firstLeader = firstLeader
        self.nextLeader = nextLeader
        self.winner = winner
        self.dummy = dummy
        self.claims = claims
        self.onCardPlayed = onCardPlayed
        self.onTrickEnd = onTrickEnd
    }
}

/// Mutable trick-play state carried on `GameState`.
public struct TrickSubstate: Codable, Hashable, Sendable {
    public struct Play: Codable, Hashable, Sendable {
        public let seat: Seat
        public let card: CardID
        public init(seat: Seat, card: CardID) {
            self.seat = seat
            self.card = card
        }
    }

    public var trickIndex: Int
    public var leader: Seat
    public var currentPlays: [Play]
    /// Tricks won per seat (raw index).
    public var tricksWon: [Int]
    /// Seats dealt in, resolved from `activeSeats` at phase entry.
    public var activeSeats: [Seat]
    /// Trump suit resolved for this deal, if any.
    public var trumpSuit: String?
    /// Effective suit led in the current trick.
    public var ledSuit: String?
    /// The dummy seat, if the phase uses one.
    public var dummySeat: Seat?
    /// Who plays the dummy's cards.
    public var dummyController: Seat?
    public var dummyRevealed: Bool
    /// Seats that must accept a pending claim.
    public var claimVoters: [Seat]
    /// Votes already cast on a pending claim.
    public var claimVotes: [Seat]
    public var pendingClaim: Seat?
    /// Set once a claim has been accepted by every voter.
    public var claimedBy: Seat?

    public init(leader: Seat, seatCount: Int) {
        trickIndex = 0
        self.leader = leader
        currentPlays = []
        tricksWon = Array(repeating: 0, count: seatCount)
        activeSeats = (0..<seatCount).map(Seat.init)
        trumpSuit = nil
        ledSuit = nil
        dummySeat = nil
        dummyController = nil
        dummyRevealed = false
        claimVoters = []
        claimVotes = []
        pendingClaim = nil
        claimedBy = nil
    }
}

@_spi(HostOnly)
public enum TrickPlayMechanic: Mechanic {
    public static let id = "trick-play"

    public typealias Params = TrickPlayParams

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        var sub = TrickSubstate(leader: Seat(0), seatCount: params.seatCount)

        // Active seats (§5.6): evaluated once; every seat index must be
        // in range and distinct.
        var active = (0..<params.seatCount).map(Seat.init)
        if let spec = params.activeSeats {
            active = try seatList(spec, pointer: "/phases/trick-play/activeSeats", state: state, ctx: ctx)
        }
        guard !active.isEmpty, active.allSatisfy({ $0.raw < params.seatCount }),
            Set(active.map(\.raw)).count == active.count
        else {
            throw RuleViolation.engineFault(
                ruleId: nil, pointer: "/phases/trick-play/activeSeats out of range or repeated")
        }
        sub.activeSeats = active

        // First leader must be one of the active seats.
        if let spec = params.firstLeader {
            let seat = try seatOf(spec, pointer: "/phases/trick-play/firstLeader", state: state, ctx: ctx)
            guard sub.activeSeats.contains(seat) else {
                throw RuleViolation.engineFault(
                    ruleId: nil, pointer: "/phases/trick-play/firstLeader not an active seat")
            }
            sub.leader = seat
        } else {
            sub.leader = sub.activeSeats[0]
        }

        // Trump is resolved once per deal (§5.6).
        if let spec = params.trump {
            switch spec {
            case .suit(let suit):
                if !suit.isEmpty { sub.trumpSuit = suit }
            case .expr(let ref):
                let value = try ctx.evalCall(
                    .init(pointer: "/phases/trick-play/trump", source: ref.source, ruleId: nil),
                    state: state)
                if case .string(let suit) = value, !suit.isEmpty {
                    sub.trumpSuit = suit
                } else if case .null = value {
                    sub.trumpSuit = nil
                } else {
                    throw RuleViolation.engineFault(
                        ruleId: nil, pointer: "/phases/trick-play/trump not a suit")
                }
            }
        }

        // Dummy seat and controller.
        if let dummy = params.dummy {
            let seat = try dummySeat(params, dummy: dummy, state: state, ctx: ctx)
            let controller = try controlledSeat(params, dummy: dummy, state: state, ctx: ctx)
            guard sub.activeSeats.contains(seat) else {
                throw RuleViolation.engineFault(
                    ruleId: dummy.ruleId, pointer: "/phases/trick-play/dummy/seat not an active seat")
            }
            guard sub.activeSeats.contains(controller), controller != seat else {
                throw RuleViolation.engineFault(
                    ruleId: dummy.ruleId,
                    pointer: "/phases/trick-play/dummy/controlledBy not a distinct active seat")
            }
            sub.dummySeat = seat
            sub.dummyController = controller
        }

        // Claim voters (the seats that must accept a claim).
        if let claims = params.claims, let ref = claims.acceptedBy {
            let value = try ctx.evalCall(
                .init(pointer: "/phases/trick-play/claims/acceptedBy", source: ref.source, ruleId: claims.ruleId),
                state: state)
            guard case .list(let names) = value else {
                throw RuleViolation.engineFault(
                    ruleId: claims.ruleId, pointer: "/phases/trick-play/claims/acceptedBy not a seat list")
            }
            var voters: [Seat] = []
            for item in names {
                guard let seat = seatValue(of: item, ctx: ctx), seat.raw < params.seatCount else {
                    throw RuleViolation.engineFault(
                        ruleId: claims.ruleId,
                        pointer: "/phases/trick-play/claims/acceptedBy not a seat list")
                }
                if !voters.contains(seat) { voters.append(seat) }
            }
            sub.claimVoters = voters
        }

        state.setSubstate(sub)

        var events: [GameEvent] = [.phaseStarted("trick-play")]
        // `revealAfter == immediately` publishes the dummy's hand at once.
        if let seat = sub.dummySeat, params.dummy?.revealAfter == .immediately {
            events.append(contentsOf: try revealDummy(&state, seat: seat, pointer: "/phases/trick-play/dummy"))
        }
        return events
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        let sub = state.trickSubstate()
        // Claim acceptance.
        if sub.pendingClaim != nil {
            return sub.claimVoters.contains(seat) ? [.acceptClaim(true), .acceptClaim(false)] : []
        }
        // Claim proposal.
        if let claims = params.claims, sub.claimedBy == nil, sub.currentPlays.isEmpty,
            let claimant = try? claimantSeat(params, claims: claims, state: state, ctx: ctx),
            seat == claimant, remainingTricks(params, state: state) > 0
        {
            return [.claim(remainingTricks(params, state: state))]
        }
        // Normal play.
        guard let turn = nextToAct(params, state: state, ctx: ctx) else { return [] }
        guard actor(for: turn, sub: sub) == seat else { return [] }
        let hand = state.zones.cards(in: handKey(turn))
        let led = sub.ledSuit
        var candidates = hand
        if let led, params.follow.mustFollow {
            let followers = hand.filter { effectiveSuit(params, $0, state: state, ctx: ctx) == led }
            if !followers.isEmpty { candidates = followers }
        }
        // Guard predicates narrow further (failures defer to apply).
        if let guardSpec = (sub.currentPlays.isEmpty ? params.leadAllowed : params.playAllowed) {
            candidates = candidates.filter {
                (try? playAllowed(params, guardSpec, card: $0, state: state, ctx: ctx)) ?? true
            }
        }
        return candidates.map { .play($0.id) }
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        let sub = state.trickSubstate()
        switch intent {
        case .claim:
            return try applyClaim(params, intent: intent, by: seat, state: &state, ctx: ctx)
        case .acceptClaim:
            return try applyAccept(params, intent: intent, by: seat, state: &state, ctx: ctx)
        case .play(let cardID):
            return try applyPlay(params, cardID: cardID, by: seat, sub: sub, state: &state, ctx: ctx)
        default:
            throw RuleViolation.illegal(
                ruleId: "trick.playOnly", detail: .custom("trick-play accepts play/claim intents"))
        }
    }

    public static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome {
        let sub = state.trickSubstate()
        if sub.claimedBy != nil { return .complete }
        switch params.tricks {
        case .count(let n):
            return sub.trickIndex >= n ? .complete : .continue
        case .untilHandsEmpty:
            guard sub.currentPlays.isEmpty else { return .continue }
            let empty = sub.activeSeats.allSatisfy { seat in
                state.zones.cards(in: handKey(seat)).isEmpty
            }
            return empty ? .complete : .continue
        }
    }

    public static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet {
        let sub = state.trickSubstate()
        if sub.pendingClaim != nil { return SeatSet(sub.claimVoters) }
        guard let turn = nextToAct(params, state: state, ctx: ctx) else { return SeatSet() }
        return SeatSet(actor(for: turn, sub: sub))
    }

    // MARK: - Play

    static func applyPlay(
        _ params: Params, cardID: CardID, by seat: Seat, sub: TrickSubstate,
        state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard let turn = nextToAct(params, state: state, ctx: ctx) else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        guard actor(for: turn, sub: sub) == seat else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        let hand = handKey(turn)
        guard state.zones.zoneOf(cardID) == hand else {
            throw RuleViolation.illegal(ruleId: "trick.notInHand", detail: .notInHand(cardID))
        }
        guard let card = state.zones.cards(in: hand).first(where: { $0.id == cardID }) else {
            throw RuleViolation.engineFault(
                ruleId: "trick.notInHand", pointer: "card \(cardID.raw) in hand index")
        }
        let played = effectiveSuit(params, card, state: state, ctx: ctx)
        let handCards = state.zones.cards(in: hand)

        if let led = sub.ledSuit {
            // Must follow the led (effective) suit.
            if params.follow.mustFollow, played != led,
                handCards.contains(where: { effectiveSuit(params, $0, state: state, ctx: ctx) == led })
            {
                throw RuleViolation.illegal(ruleId: params.follow.ruleId, detail: .mustFollow(suit: led))
            }
            let isTrumpPlay = sub.trumpSuit != nil && played == sub.trumpSuit
            // Void in the led suit: must trump if holding trump.
            if params.follow.mustTrumpIfVoid, played != led, !isTrumpPlay,
                handCards.contains(where: { effectiveSuit(params, $0, state: state, ctx: ctx) == sub.trumpSuit })
            {
                throw RuleViolation.illegal(
                    ruleId: params.follow.ruleId, detail: .custom("must trump when void in the led suit"))
            }
            // Overtrump: a trump play must beat the current best trump if able.
            if params.follow.mustOvertrump, isTrumpPlay {
                let bestTrump = bestStrength(
                    params, sub, suit: sub.trumpSuit, pile: pileOf(state, sub), state: state, ctx: ctx)
                if let bestTrump, cardStrength(params, card, state: state, ctx: ctx) < bestTrump,
                    handCards.contains(where: {
                        effectiveSuit(params, $0, state: state, ctx: ctx) == sub.trumpSuit
                            && cardStrength(params, $0, state: state, ctx: ctx) > bestTrump
                    })
                {
                    throw RuleViolation.illegal(
                        ruleId: params.follow.ruleId, detail: .custom("must overtrump"))
                }
            }
            // Head the trick: following must beat the current best led card if able.
            if params.follow.mustHeadTrick, played == led {
                let bestLed = bestStrength(params, sub, suit: led, pile: pileOf(state, sub), state: state, ctx: ctx)
                if let bestLed, cardStrength(params, card, state: state, ctx: ctx) < bestLed,
                    handCards.contains(where: {
                        effectiveSuit(params, $0, state: state, ctx: ctx) == led
                            && cardStrength(params, $0, state: state, ctx: ctx) > bestLed
                    })
                {
                    throw RuleViolation.illegal(
                        ruleId: params.follow.ruleId, detail: .custom("must head the trick"))
                }
            }
        }

        // Lead / play guards.
        if let guardSpec = sub.currentPlays.isEmpty ? params.leadAllowed : params.playAllowed {
            if try !playAllowed(params, guardSpec, card: card, state: state, ctx: ctx) {
                throw RuleViolation.illegal(
                    ruleId: guardSpec.ruleId ?? params.follow.ruleId, detail: .custom(guardSpec.otherwise))
            }
        }

        let trickKey = ZoneKey(scope: .shared, id: "trick\(sub.trickIndex)")
        state.zones.ensureDeclared(trickKey)
        do {
            try state.zones.move(cardID, from: hand, to: trickKey)
        } catch {
            throw RuleViolation.engineFault(ruleId: "trick.move", pointer: "\(error)")
        }
        // A played card is face-up on the table: public knowledge immediately.
        state.knowledge.makePublic(cardID)
        var events: [GameEvent] = [.cardPlayed(seat: turn, card: card)]
        state.mutateSubstate {
            if $0.currentPlays.isEmpty { $0.ledSuit = played }
            $0.currentPlays.append(TrickSubstate.Play(seat: turn, card: cardID))
        }

        // Reveal the dummy after the opening lead.
        if let dummySeat = sub.dummySeat, !sub.dummyRevealed,
            params.dummy?.revealAfter == .afterLead, sub.trickIndex == 0
        {
            events.append(contentsOf: try revealDummy(&state, seat: dummySeat, pointer: "/phases/trick-play/dummy"))
        }

        // Per-play effects, with `seat` and `card` bound.
        if !params.onCardPlayed.isEmpty {
            var effectEvents: [GameEvent] = []
            try ctx.effects?.run(
                params.onCardPlayed, in: &state,
                bindings: ["seat": .string(spelling(turn, ctx)), "card": cardValue(card)],
                events: &effectEvents,
                pointer: "/phases/trick-play/onCardPlayed")
            events.append(contentsOf: effectEvents)
        }

        events.append(contentsOf: try completeTrickIfFull(params, state: &state, ctx: ctx))
        return events
    }

    /// If every active seat has played, decide the trick: publish the faces,
    /// record the winner, advance the leader/index, and run the trick-end
    /// effects with `trick` (a record with `winner` and `index`) bound.
    private static func completeTrickIfFull(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        var events: [GameEvent] = []
        var sub2 = state.trickSubstate()
        guard sub2.currentPlays.count == sub2.activeSeats.count else { return events }
        let trickKey = ZoneKey(scope: .shared, id: "trick\(sub2.trickIndex)")
        // Trick complete: the played faces are public knowledge.
        let trickCards = state.zones.cards(in: trickKey)
        for instance in trickCards { state.knowledge.makePublic(instance.id) }
        let winner = try winnerOf(params, sub: sub2, plays: sub2.currentPlays, pile: trickCards, state: state, ctx: ctx)
        state.mutateSubstate {
            $0.tricksWon[winner.raw] += 1
            $0.leader = winner
            $0.currentPlays = []
            $0.trickIndex += 1
            $0.ledSuit = nil
        }
        events.append(.trickWon(seat: winner, cards: trickCards))
        events.append(.scored(seat: winner, points: 1, reason: "trick", ruleId: "trick.award"))
        // Trick-end effects, with `trick.winner` bound.
        if !params.onTrickEnd.isEmpty {
            var effectEvents: [GameEvent] = []
            try ctx.effects?.run(
                params.onTrickEnd, in: &state,
                bindings: [
                    "trick": .record(
                        name: "trick",
                        fields: [
                            "winner": .string(spelling(winner, ctx)),
                            "index": .int(Int64(sub2.trickIndex)),
                        ])
                ],
                events: &effectEvents,
                pointer: "/phases/trick-play/onTrickEnd")
            events.append(contentsOf: effectEvents)
        }
        return events
    }
}
