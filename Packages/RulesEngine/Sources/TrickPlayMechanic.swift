// The `trick-play` mechanic (ARCHITECTURE §5.6), P1 minimal Swift-configured
// form: clockwise trick-taking with must-follow-suit and a configurable
// winner rule. Trump, overtrump rules, dummy and claims arrive with the
// ruleset DSL (P2/P3).

import CardModel

public enum TrickWinnerRule: Codable, Hashable, Sendable {
    /// Highest card of the led suit wins.
    case highestOfLed
    /// Highest card of the trump suit if any were played, else highest of led.
    case highestWithTrump(trump: String)
}

public struct TrickPlayParams: Codable, Hashable, Sendable {
    public let seatCount: Int
    /// Number of tricks in this phase.
    public let tricks: Int
    /// Seats that take part, in turn order.
    public let activeSeats: [Seat]
    /// First leader of the first trick.
    public let firstLeader: Seat
    public let winnerRule: TrickWinnerRule
    /// Rule ID reported when a seat must follow suit and does not.
    public let followRuleId: String

    public init(seatCount: Int, tricks: Int, activeSeats: [Seat], firstLeader: Seat, winnerRule: TrickWinnerRule, followRuleId: String) {
        self.seatCount = seatCount
        self.tricks = tricks
        self.activeSeats = activeSeats
        self.firstLeader = firstLeader
        self.winnerRule = winnerRule
        self.followRuleId = followRuleId
    }
}

/// Mechanic sub-state (lives in PhaseCursor; Codable for replays).
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

    public init(leader: Seat, seatCount: Int) {
        trickIndex = 0
        self.leader = leader
        currentPlays = []
        tricksWon = Array(repeating: 0, count: seatCount)
    }
}

@_spi(HostOnly)
public enum TrickPlayMechanic: Mechanic {
    public static let id = "trick-play"

    public typealias Params = TrickPlayParams

    public static func enter(_ params: Params, state: inout GameState, ctx: EvalContext) throws(RuleViolation) -> [GameEvent] {
        state.setSubstate(TrickSubstate(leader: params.firstLeader, seatCount: params.seatCount))
        return [.phaseStarted("trick-play")]
    }

    public static func legalIntents(_ params: Params, state: GameState, seat: Seat, ctx: EvalContext) -> [ActionIntent] {
        guard pendingSeats(params, state: state, ctx: ctx).contains(seat) else { return [] }
        let hand = state.zones.cards(in: handKey(seat))
        if let led = ledSuit(state) {
            let followers = hand.filter { $0.face.suit?.code == led }
            if !followers.isEmpty { return followers.map { .play($0.id) } }
        }
        return hand.map { .play($0.id) }
    }

    public static func apply(_ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext) throws(RuleViolation) -> [GameEvent] {
        guard case .play(let cardID) = intent else {
            throw RuleViolation.illegal(ruleId: "trick.playOnly", detail: .custom("trick-play accepts .play intents"))
        }
        guard pendingSeats(params, state: state, ctx: ctx).contains(seat) else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        let hand = handKey(seat)
        guard state.zones.zoneOf(cardID) == hand else {
            throw RuleViolation.illegal(ruleId: "trick.notInHand", detail: .notInHand(cardID))
        }
        guard let card = state.zones.cards(in: hand).first(where: { $0.id == cardID }) else {
            throw RuleViolation.engineFault(ruleId: "trick.notInHand", pointer: "card \(cardID.raw) in hand index")
        }
        if let led = ledSuit(state), card.face.suit?.code != led {
            let followers = state.zones.cards(in: hand).filter { $0.face.suit?.code == led }
            if !followers.isEmpty {
                throw RuleViolation.illegal(ruleId: params.followRuleId, detail: .mustFollow(suit: led))
            }
        }
        let sub = state.trickSubstate()
        let trickKey = ZoneKey(scope: .shared, id: "trick\(sub.trickIndex)")
        state.zones.ensureDeclared(trickKey) // fresh pile for this trick
        do {
            try state.zones.move(cardID, from: hand, to: trickKey)
        } catch {
            throw RuleViolation.engineFault(ruleId: "trick.move", pointer: "\(error)")
        }
        // A played card is face-up on the table: public knowledge immediately.
        state.knowledge.makePublic(cardID)
        var events: [GameEvent] = [.cardPlayed(seat: seat, card: card)]
        state.mutateSubstate { $0.currentPlays.append(TrickSubstate.Play(seat: seat, card: cardID)) }

        let plays = state.trickSubstate().currentPlays
        if plays.count == params.activeSeats.count {
            // Trick complete: the played faces are public knowledge.
            let trickCards = state.zones.cards(in: trickKey)
            for instance in trickCards { state.knowledge.makePublic(instance.id) }
            let winner = winnerOf(params, plays: plays, pile: trickCards)
            state.mutateSubstate {
                $0.tricksWon[winner.raw] += 1
                $0.leader = winner
                $0.currentPlays = []
                $0.trickIndex += 1
            }
            events.append(.trickWon(seat: winner, cards: trickCards))
            events.append(.scored(seat: winner, points: 1, reason: "trick", ruleId: "trick.award"))
        }
        return events
    }

    public static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome {
        state.trickSubstate().trickIndex >= params.tricks ? .complete : .continue
    }

    public static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet {
        guard let seat = nextToAct(params, state: state) else { return SeatSet() }
        return SeatSet(seat)
    }

    // MARK: - Internals

    static func handKey(_ seat: Seat) -> ZoneKey {
        ZoneKey(scope: .seat, owner: seat.raw, id: "hand")
    }

    static func ledSuit(_ state: GameState) -> String? {
        let sub = state.trickSubstate()
        guard let first = sub.currentPlays.first else { return nil }
        // The led card is the first entry of the current trick pile.
        let pile = state.zones.cards(in: ZoneKey(scope: .shared, id: "trick\(sub.trickIndex)"))
        return pile.first(where: { $0.id == first.card })?.face.suit?.code
    }

    static func nextToAct(_ params: Params, state: GameState) -> Seat? {
        let sub = state.trickSubstate()
        guard sub.trickIndex < params.tricks else { return nil }
        guard sub.currentPlays.count < params.activeSeats.count else { return nil }
        guard let leaderIndex = params.activeSeats.firstIndex(of: sub.leader) else { return params.activeSeats.first }
        return params.activeSeats[(leaderIndex + sub.currentPlays.count) % params.activeSeats.count]
    }

    static func winnerOf(_ params: Params, plays: [TrickSubstate.Play], pile: [CardInstance]) -> Seat {
        // Highest card of the trump suit (if any, per rule) else highest of
        // the led suit (the first played card's suit). Rank order: A high,
        // then K Q J 10 9 8 7 6 5 4 3 2; German U/O rank under K/A.
        func strength(_ code: String) -> Int {
            let order = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "U", "Q", "O", "K", "A"]
            return order.firstIndex(of: code).map { $0 + 1 } ?? 0
        }
        let ledSuit = pile.first { $0.id == plays.first?.card }?.face.suit?.code
        let trumpSuit: String?
        if case .highestWithTrump(let t) = params.winnerRule { trumpSuit = t } else { trumpSuit = nil }
        var best: (seat: Seat, strength: Int)?
        for play in plays {
            guard let instance = pile.first(where: { $0.id == play.card }) else { continue }
            let suit = instance.face.suit?.code
            let isTrump = trumpSuit != nil && suit == trumpSuit
            let counts = isTrump || suit == ledSuit
            guard counts else { continue }
            let value = strength(instance.face.rank.code)
            if best == nil || value > best!.strength {
                best = (play.seat, value)
            }
        }
        return best?.seat ?? plays.first?.seat ?? params.firstLeader
    }
}
