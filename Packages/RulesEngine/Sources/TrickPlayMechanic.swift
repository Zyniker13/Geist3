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
                if case .string(let suit) = value, !suit.isEmpty { sub.trumpSuit = suit }
                else if case .null = value { sub.trumpSuit = nil }
                else {
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

        var sub2 = state.trickSubstate()
        if sub2.currentPlays.count == sub2.activeSeats.count {
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
            sub2 = state.trickSubstate()
        }
        return events
    }

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
        guard sub.currentPlays.isEmpty
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
