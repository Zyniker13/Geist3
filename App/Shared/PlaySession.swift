// Dev play session (P3.7): drives any resolved ruleset pass-and-play in the
// app. One human seat acts through the UI; every other seat is a random-legal
// bot. All randomness comes from the engine's own SeededRNG via the seed, so
// a session is reproducible from its (ruleset, seed, human seat) triple.

import CardModel
import Foundation
import RulesEngine
// EngineBuilder and Engine are HostOnly SPI: the app is a host process, so it
// takes the same @_spi path rules-cli and the test harnesses do.
@_spi(HostOnly) import RulesEngine
@_spi(HostOnly) import RulesetKit
import SwiftUI

/// One running game plus the bookkeeping the dev UI needs around it.
@MainActor
public final class PlaySession: ObservableObject {
    /// The ruleset stem the session was built from ("hearts.standard", …).
    public let rulesetName: String

    /// The seat the human plays; all other seats auto-play.
    public let humanSeat: Seat

    /// Spellings from the ruleset's players block (§7.3), positional fallback.
    public let seatNames: [String]

    /// The last violation a human tap produced, shown verbatim in the UI.
    @Published public private(set) var lastViolation: String?

    /// The events the human's own viewer saw from the last action.
    @Published public private(set) var lastEvents: [GameEvent] = []

    /// How many deals have completed since the session started. The engine
    /// bumps `dealIndex` at every deal boundary (finishDeal/redealDeal); a
    /// completed deal that is followed by the next one does NOT emit
    /// `.dealEnded` (that event marks match close), so the index is the
    /// reliable deal counter for the dev UI.
    public var dealsCompleted: Int { state.dealIndex }

    private let engine: Engine
    private(set) var state: GameState
    private var botRNG: SeededRNG

    /// Creates and starts a session. `seed` controls the shuffle, the
    /// first-dealer pick, and the bot moves; the same triple always produces
    /// the same match (determinism, CONVENTIONS §5).
    public init(ruleset: ResolvedRuleset, seed: UInt64, humanSeat: Seat) throws {
        let engine = try EngineBuilder.build(from: ruleset)
        self.engine = engine
        self.rulesetName = ruleset.document.id
        self.humanSeat = humanSeat
        self.seatNames = engine.seatNames.isEmpty
            ? (0..<engine.seatCount).map { "S\($0 + 1)" }
            : engine.seatNames
        let start = try engine.start(seed: seed)
        self.state = start.state
        // The bot lane derives from the session seed; the constant keeps bot
        // choices independent of anything host-side.
        self.botRNG = SeededRNG(seed: seed ^ 0xfeed_face_face_face)
        // The opening phase may already wait on bots only (e.g. euchre's
        // auction starts left of the dealer); run the bot lane now, exactly
        // as after every human action.
        runBots()
    }

    // MARK: - Reading the game

    /// The human's current observation.
    public var observation: Observation {
        engine.observation(of: state, for: .seat(humanSeat))
    }

    /// Whether the human's seat is among the seats the phase waits on.
    public var waitingOnHuman: Bool {
        engine.pendingSeats(in: state).contains(humanSeat)
    }

    /// The match is over (an end condition held).
    public var matchOver: Bool { state.matchOver }

    // MARK: - Acting

    /// Applies a legal intent for the human seat. An illegal intent is NOT
    /// applied; the rule violation text lands in `lastViolation` so the UI
    /// can explain the rejected tap (P3.7 accept criterion).
    public func play(_ intent: ActionIntent) {
        lastViolation = nil
        do {
            let transition = try engine.apply(
                Action(seat: humanSeat, intent: intent, expectedVersion: state.version),
                to: state)
            state = transition.state
            lastEvents = transition.events
            runBots()
        } catch {
            lastViolation = Self.violationText(error)
        }
    }

    /// "Explain a tap before it happens": the UI can ask whether an intent
    /// is currently legal and why not, without mutating state.
    public func explanation(for intent: ActionIntent) -> String? {
        engine.legalIntents(for: humanSeat, in: state).contains(intent)
            ? nil
            : "Not a legal move for \(seatNames[humanSeat.raw]) right now."
    }

    /// Plays bot seats until the phase waits on a seat again or the match
    /// ends. Bot choices are a uniform draw over legal intents, seeded.
    private func runBots() {
        while !state.matchOver {
            let pending = engine.pendingSeats(in: state).sorted()
            guard let seat = pending.first(where: { $0 != humanSeat }) else { break }
            let legal = engine.legalIntents(for: seat, in: state)
            guard !legal.isEmpty else { break }
            let pick = legal[botRNG.below(legal.count)]
            // A bot only plays legal intents, so this cannot throw; if the
            // engine disagrees the match stops advancing rather than looping.
            guard let transition = try? engine.apply(
                Action(seat: seat, intent: pick, expectedVersion: state.version),
                to: state
            )
            else { break }
            state = transition.state
        }
    }

    /// Human-readable violation text (§9.7): rule id plus the specific reason.
    public static func violationText(_ error: Error) -> String {
        guard let violation = error as? RuleViolation else {
            return "Rejected: \(error)"
        }
        switch violation {
        case .notYourTurn(let expected):
            let seats = (0..<64).compactMap { Seat($0) }
                .filter { expected.contains($0) }
                .map { "seat \($0.raw + 1)" }
            return "Not your turn — waiting on \(seats.joined(separator: ", "))."
        case .staleVersion(let current):
            return "Stale screen — the game moved on (now at step \(current)). Try again."
        case .illegal(let ruleId, let detail):
            return "Illegal (\(ruleId)): \(detailText(detail))"
        case .engineFault(let ruleId, let pointer):
            return "Engine fault (\(ruleId ?? "-")): \(pointer)"
        }
    }

    private static func detailText(_ detail: ViolationDetail) -> String {
        switch detail {
        case .mustFollow(let suit): return "you must follow \(suit)"
        case .cannotLead(let suit): return "\(suit) is not led-legal for you"
        case .exceedsLimit(let n): return "more than the \(n) you may play"
        case .notInHand(let id): return "that card (id \(id.raw)) is not in your hand"
        case .custom(let text): return text
        }
    }
}
