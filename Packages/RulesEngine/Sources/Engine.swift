// The reducer (ARCHITECTURE §9.3): Engine.start/apply/legalIntents/observation.
// `apply` is pure: same (ruleset, state, action) always gives the same
// Transition. P1 runs a Swift-configured phase list (no JSON yet).
// Host-only: `apply`/`start`/`replay` take and return the full GameState.

import CardModel
import Foundation

/// One configured phase of the P1 phase list.
@_spi(HostOnly)
public struct PhaseConfig: Sendable {
    public let id: String
    public let mechanic: AnyMechanic

    public init(id: String, mechanic: AnyMechanic) {
        self.id = id
        self.mechanic = mechanic
    }
}

/// Type-erased mechanic + params pair.
@_spi(HostOnly)
public struct AnyMechanic: Sendable {
    let enter: @Sendable (inout GameState, EvalContext) throws -> [GameEvent]
    let legal: @Sendable (GameState, Seat, EvalContext) -> [ActionIntent]
    let act: @Sendable (ActionIntent, Seat, inout GameState, EvalContext) throws -> [GameEvent]
    let complete: @Sendable (GameState, EvalContext) -> PhaseOutcome
    let pending: @Sendable (GameState, EvalContext) -> SeatSet

    public init<M: Mechanic>(_ mechanic: M.Type, params: M.Params) {
        enter = { state, ctx in try mechanic.enter(params, state: &state, ctx: ctx) }
        legal = { state, seat, ctx in mechanic.legalIntents(params, state: state, seat: seat, ctx: ctx) }
        act = { intent, seat, state, ctx in try mechanic.apply(params, intent: intent, by: seat, state: &state, ctx: ctx) }
        complete = { state, ctx in mechanic.isComplete(params, state: state, ctx: ctx) }
        pending = { state, ctx in mechanic.pendingSeats(params, state: state, ctx: ctx) }
    }

    /// Normalize any thrown error into a RuleViolation.
    static func violation(_ error: Error) -> RuleViolation {
        (error as? RuleViolation) ?? .engineFault(ruleId: nil, pointer: String(describing: error))
    }
}

/// Replay record (§10.4): the resolved configuration is identified by hash;
/// P1 stores the seed and the action list.
public struct Replay: Codable, Hashable, Sendable {
    public let format: String
    public let rulesetHash: Data
    public let seed: UInt64
    public let seatCount: Int
    public let actions: [LoggedAction]

    public init(rulesetHash: Data, seed: UInt64, seatCount: Int, actions: [LoggedAction]) {
        self.format = "parlor.replay/1"
        self.rulesetHash = rulesetHash
        self.seed = seed
        self.seatCount = seatCount
        self.actions = actions
    }
}

/// The reducer (ARCHITECTURE §9.3).
@_spi(HostOnly)
public struct Engine: Sendable {
    public let phases: [PhaseConfig]
    public let seatCount: Int
    /// SHA-256 of the resolved ruleset (P1: hash of the phase configuration).
    public let rulesetHash: Data

    public init(phases: [PhaseConfig], seatCount: Int) {
        self.phases = phases
        self.seatCount = seatCount
        self.rulesetHash = Engine.hash(of: phases)
    }

    public static func hash(of phases: [PhaseConfig]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ids = phases.map { $0.id }
        let payload = (try? encoder.encode(ids)) ?? Data()
        var digest = SHA256()
        digest.update(data: payload)
        return Data(digest.finalize())
    }

    private var ctx: EvalContext { EvalContext(seatCount: seatCount) }

    /// Fresh state: seed → RNG, dealer seat 0, phase 0 entered.
    public func start(seed: UInt64) throws(RuleViolation) -> Transition {
        do {
            return try startUnchecked(seed: seed)
        } catch {
            throw AnyMechanic.violation(error)
        }
    }

    private func startUnchecked(seed: UInt64) throws -> Transition {
        var state = GameState(rng: SeededRNG(seed: seed), dealer: Seat(0))
        var events: [GameEvent] = []
        guard let first = phases.first else {
            throw RuleViolation.engineFault(ruleId: nil, pointer: "engine has no phases")
        }
        state.enterPhase(first.id)
        events += try first.mechanic.enter(&state, ctx)
        try advanceIfAutomatic(&state, &events)
        state.recentEvents = events.suffix(GameState.recentEventLimit).map { $0 }
        return Transition(state: state, events: events)
    }

    /// Advance through phases that need no player action (`deal`, finished
    /// trick phases, the end of the deal).
    private func advanceIfAutomatic(_ state: inout GameState, _ events: inout [GameEvent]) throws(RuleViolation) {
        do {
            try advanceIfAutomaticInner(&state, &events)
        } catch {
            throw AnyMechanic.violation(error)
        }
    }

    private func advanceIfAutomaticInner(_ state: inout GameState, _ events: inout [GameEvent]) throws {
        while state.phase.phaseID != "done" {
            guard let config = phases.first(where: { $0.id == state.phase.phaseID }) else {
                throw RuleViolation.engineFault(ruleId: nil, pointer: "unknown phase \(state.phase.phaseID)")
            }
            let outcome = config.mechanic.complete(state, ctx)
            let pending = config.mechanic.pending(state, ctx)
            if outcome == .continue || !pending.isEmpty { return }
            if let next = nextStateIndex(after: config.id) {
                state.enterPhase(phases[next].id)
                events += try phases[next].mechanic.enter(&state, ctx)
            } else {
                state.enterPhase("done")
                events.append(.dealEnded)
            }
        }
    }

    private func nextStateIndex(after id: String) -> Int? {
        guard let index = phases.firstIndex(where: { $0.id == id }) else { return nil }
        let next = phases.index(after: index)
        return next < phases.count ? next : nil
    }

    public func legalIntents(for seat: Seat, in state: GameState) -> [ActionIntent] {
        guard let config = phases.first(where: { $0.id == state.phase.phaseID }) else { return [] }
        return config.mechanic.legal(state, seat, ctx)
    }

    public func apply(_ action: Action, to state: GameState) throws(RuleViolation) -> Transition {
        do {
            return try applyUnchecked(action, to: state)
        } catch {
            throw AnyMechanic.violation(error)
        }
    }

    private func applyUnchecked(_ action: Action, to state: GameState) throws -> Transition {
        var state = state
        var events: [GameEvent] = []
        guard action.expectedVersion == state.version else {
            throw RuleViolation.staleVersion(current: state.version)
        }
        guard let config = phases.first(where: { $0.id == state.phase.phaseID }) else {
            throw RuleViolation.engineFault(ruleId: nil, pointer: "unknown phase \(state.phase.phaseID)")
        }
        let pending = config.mechanic.pending(state, ctx)
        guard pending.contains(action.seat) else {
            throw RuleViolation.notYourTurn(expected: pending)
        }
        events += try config.mechanic.act(action.intent, action.seat, &state, ctx)
        state.history.append(LoggedAction(seat: action.seat, intent: action.intent, version: state.version))
        state.version += 1
        try advanceIfAutomatic(&state, &events)
        state.recentEvents = (state.recentEvents + events).suffix(GameState.recentEventLimit).map { $0 }
        return Transition(state: state, events: events)
    }

    /// Replay a stored action list from the seed; returns the final state.
    public func replay(_ replay: Replay) throws(RuleViolation) -> GameState {
        do {
            let start = try start(seed: replay.seed)
            var state = start.state
            for logged in replay.actions {
                let transition = try apply(Action(seat: logged.seat, intent: logged.intent, expectedVersion: logged.version), to: state)
                state = transition.state
            }
            return state
        } catch {
            throw AnyMechanic.violation(error)
        }
    }

    // MARK: - Observation (§9.6)

    public func observation(of state: GameState, for viewer: Viewer) -> Observation {
        var zones: [String: ObservedZone] = [:]
        for (key, cards) in state.zones.zones.sorted(by: { $0.key.storageKey < $1.key.storageKey }) {
            let observed = ObservedZone.redactCards(cards, key: key, viewer: viewer, knowledge: state.knowledge)
            zones[key.storageKey] = observed
        }
        let events = state.recentEvents.map { Redactor.redact($0, viewer: viewer, knowledge: state.knowledge) }
        let legal: [ActionIntent]
        switch viewer {
        case .seat(let s):
            legal = pendingSeats(in: state).contains(s) ? legalIntents(for: s, in: state) : []
        case .coachOf, .table, .spectator, .replayAll:
            legal = []
        }
        return Observation(
            rulesetHash: rulesetHash,
            version: state.version,
            viewer: viewer.observed,
            dealIndex: state.dealIndex,
            dealer: state.dealer,
            phase: ObservedPhase(phaseID: state.phase.phaseID, pendingSeats: pendingSeats(in: state)),
            zones: zones,
            legal: legal,
            lastEvents: events
        )
    }

    public func pendingSeats(in state: GameState) -> SeatSet {
        guard let config = phases.first(where: { $0.id == state.phase.phaseID }) else { return SeatSet() }
        return config.mechanic.pending(state, ctx)
    }

    /// Final-state hash for replay verification (§10.4).
    public static func finalStateHash(_ state: GameState) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(state)) ?? Data()
        var digest = SHA256()
        digest.update(data: payload)
        return Data(digest.finalize())
    }
}

extension Viewer {
    var observed: ObservedViewer {
        switch self {
        case .seat(let s): return .seat(s.raw)
        case .coachOf(let s): return .coachOf(s.raw)
        case .table: return .table
        case .spectator: return .spectator
        case .replayAll: return .replayAll
        }
    }
}

extension ZoneKey {
    /// Stable dictionary key for observations: "scope:owner:id" (see
    /// `storageKey`).
    var observationKey: String {
        storageKey
    }
}

extension ObservedZone {
    /// Redact a zone's cards for a viewer (§9.6 rule 1): a face is included
    /// only if the viewer knows it (knowledge contains the viewer's seat) or
    /// the card is public; `.replayAll` sees everything.
    static func redactCards(_ cards: [CardInstance], key: ZoneKey, viewer: Viewer, knowledge: KnowledgeStore) -> ObservedZone {
        _ = key // zone-level visibility defaults arrive with ruleset-driven zones in P2
        let known = cards.filter { Redactor.maySee($0.id, viewer: viewer, knowledge: knowledge, publicCard: false) }
        if known.count == cards.count { return .visible(cards) }
        return .hidden(count: cards.count, known: known)
    }
}
