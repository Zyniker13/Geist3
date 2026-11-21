// Actions, events, violations, transitions, viewers (ARCHITECTURE §9.2–§9.7).

import CardModel

/// What a seat asks to do (§9.2).
public enum ActionIntent: Codable, Hashable, Sendable {
    case play(CardID)
    case call(String)  // bid / contract call (P1: opaque tag)
    case pass([CardID])  // exchange.pass
    case discard([CardID])  // exchange.kitty / discardTo
    case drawFrom(String)  // ZoneKey id
    case meld([CardID])
    case choose(String)
    case claim(Int)
    case acceptClaim(Bool)
    case cut(depth: Int)  // reveal.starter
    case count(points: Int)  // count-play
    case confirm
}

/// A seat's intent wrapped with the version the caller observed. Stale
/// versions are rejected (§9.2).
public struct Action: Codable, Hashable, Sendable {
    public let seat: Seat
    public let intent: ActionIntent
    public let expectedVersion: UInt64

    public init(seat: Seat, intent: ActionIntent, expectedVersion: UInt64) {
        self.seat = seat
        self.intent = intent
        self.expectedVersion = expectedVersion
    }
}

/// The narrative of play (§9.4). Events carry card IDs and faces; the
/// Redactor strips faces the viewer may not see.
public enum GameEvent: Codable, Hashable, Sendable {
    case dealt(to: Seat, cards: [CardInstance])
    case passed(from: Seat, to: Seat, cards: [CardInstance])
    case received(seat: Seat, count: Int)
    case called(seat: Seat, call: String)
    case contractSet(String)
    case cardPlayed(seat: Seat, card: CardInstance)
    case trickWon(seat: Seat, cards: [CardInstance])
    case cardsMoved(from: String, to: String, count: Int)
    case revealed(zone: String, cards: [CardInstance])
    case scored(seat: Seat?, points: Int, reason: String, ruleId: String?)
    case phaseStarted(String)
    case dealEnded
    case matchEnded
    case emitted(name: String)
}

/// Why an action was rejected (§9.7). Every illegal intent carries a rule ID.
public enum RuleViolation: Error, Codable, Hashable, Sendable {
    case notYourTurn(expected: SeatSet)
    case staleVersion(current: UInt64)
    case illegal(ruleId: String, detail: ViolationDetail)
    case engineFault(ruleId: String?, pointer: String)
}

public enum ViolationDetail: Codable, Hashable, Sendable {
    case mustFollow(suit: String)
    case cannotLead(suit: String)
    case exceedsLimit(Int)
    case notInHand(CardID)
    case custom(String)
}

public struct Transition: Sendable {
    @_spi(HostOnly) public let state: GameState
    public let events: [GameEvent]

    @_spi(HostOnly)
    public init(state: GameState, events: [GameEvent]) {
        self.state = state
        self.events = events
    }
}

/// Who is looking (§9.6). `.coachOf(s)` equals `.seat(s)` without `legal`.
public enum Viewer: Hashable, Sendable {
    case seat(Seat)
    case coachOf(Seat)
    case table
    case spectator
    case replayAll
}

/// Phase completion outcome (§5.6 `isComplete`).
public enum PhaseOutcome: Hashable, Sendable {
    case `continue`
    case complete
    case redeal
    case endDeal
    /// ADR-0032: the mechanic has internal automatic steps left (no seat
    /// acts); the engine applies one `step` at a time and runs the
    /// continuous end check between steps (§5.3), so a win mid-sequence
    /// (e.g. cribbage counting one hand at a time) ends the deal at once.
    case autoStep
}
