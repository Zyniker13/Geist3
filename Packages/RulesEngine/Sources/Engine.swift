// The reducer (ARCHITECTURE §9.3): Engine.start/apply/legalIntents/observation.
// `apply` is pure: same (ruleset, state, action) always gives the same
// Transition. P1 runs a Swift-configured phase list (no JSON yet).
// Host-only: `apply`/`start`/`replay` take and return the full GameState.

import CardModel
import Foundation

/// Tie policy for the §5.8 match rank: `shared` (all top scorers win
/// together), `playOff` (a playoff deal decides; P3's engine does not
/// automate playoffs, so a tie under this policy is an engineFault), or
/// `impossible` (the ruleset declares ties cannot occur; one occurring is
/// an engineFault).
public enum EngineTiePolicy: String, Sendable {
    case shared
    case playOff = "playOff"
    case impossible
}

/// When the §5.8 end condition is checked: after each deal completes
/// (default), after every applied action (a score crossing the target ends
/// the match mid-deal), or after each trick (not automated in P3 — the
/// builder refuses it).
public enum EngineEndCheck: String, Sendable {
    case afterDeal
    case continuous
    case afterTrick
}

/// The §5.8 rank: a seat- or team-indexed variable, ordered ascending or
/// descending, with a tie policy.
public struct EngineRankSpec: Sendable {
    public let scope: EngineVarScope
    public let name: String
    public let descending: Bool
    public let ties: EngineTiePolicy

    public init(scope: EngineVarScope, name: String, descending: Bool, ties: EngineTiePolicy) {
        self.scope = scope
        self.name = name
        self.descending = descending
        self.ties = ties
    }
}

/// The §5.8 end configuration: when the match closes and what runs then.
/// `deals` counts completed deals; `condition` is an expression evaluated
/// through the host runtime. Exactly one of the two must be configured.
/// `ruleId` attributes end-condition faults to the ruleset rule that owns
/// the check.
public struct EngineEndSpec: Sendable {
    public let condition: String?
    public let deals: Int?
    public let rank: EngineRankSpec
    public let check: EngineEndCheck
    public let ruleId: String?
    public let matchEffects: [EngineEffect]

    public init(
        condition: String? = nil, deals: Int? = nil, rank: EngineRankSpec,
        check: EngineEndCheck = .afterDeal, ruleId: String? = nil,
        matchEffects: [EngineEffect] = []
    ) {
        self.condition = condition
        self.deals = deals
        self.rank = rank
        self.check = check
        self.ruleId = ruleId
        self.matchEffects = matchEffects
    }
}

/// §5.7 dealership: how the dealer moves between deals. `alternate` is the
/// two-seat form of `left` (the builder rejects it with other seat counts);
/// `fixed` keeps the same dealer every deal.
public enum EngineDealerRotation: String, Sendable {
    case left, right, alternate, fixed
}

/// One configured phase of the P1 phase list.
@_spi(HostOnly)
public struct PhaseConfig: Sendable {
    public let id: String
    public let mechanic: AnyMechanic
    /// A `when` gate: the phase is skipped while this evaluates false
    /// (§5.6). Evaluated each time the phase would be entered. Nil
    /// means unconditional.
    let gate: (@Sendable (GameState) throws -> Bool)?

    public init(
        id: String, mechanic: AnyMechanic,
        gate: (@Sendable (GameState) throws -> Bool)? = nil
    ) {
        self.id = id
        self.mechanic = mechanic
        self.gate = gate
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
        act = { intent, seat, state, ctx in
            try mechanic.apply(params, intent: intent, by: seat, state: &state, ctx: ctx)
        }
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
    /// Runs once on the fresh state before the first phase enters: ruleset
    /// zone setup (declare zones, stack the stock from the deck spec).
    public let setup: (@Sendable (inout GameState) throws -> Void)?
    /// Host-mediated expression runtime (§7.5): the host installs its
    /// evaluator; mechanics reach it through `ctx.eval`. Null when the
    /// host has no runtime — mechanics must then fault on expression
    /// parameters rather than invent values.
    public let expressionRuntime: (@Sendable (EvalCall, GameState) throws(EvalFailure) -> EvalValue)?
    /// SHA-256 of the resolved ruleset (P1: hash of the phase configuration).
    public let rulesetHash: Data
    /// Ruleset variables (§5.5): name → declaration.
    public let vars: [String: EngineVarDecl]
    /// Seat spellings in seat order (§7.3).
    public let seatNames: [String]
    /// Team spellings in team order; empty means the ruleset has no teams.
    public let teamNames: [String]
    /// Maps a seat position to its team position.
    public let teamOfSeat: [Int]
    /// The phase whose completion closes one deal and re-enters itself (§5.7).
    public let dealPhaseID: String?
    /// Match end configuration (§5.8).
    public let end: EngineEndSpec?
    /// Effects run when a deal completes, before rotation and reset (§5.6).
    public let afterDeal: [EngineEffect]
    /// Rebuilds the table between deals: zones and deck restacking.
    public let rebuild: (@Sendable (inout GameState) throws -> Void)?
    /// Table options (§5.9).
    public let options: [String: String]
    /// How the dealer moves between deals (§5.7).
    public let dealerRotation: EngineDealerRotation

    public init(
        phases: [PhaseConfig], seatCount: Int,
        setup: (@Sendable (inout GameState) throws -> Void)? = nil,
        expressionRuntime: (@Sendable (EvalCall, GameState) throws(EvalFailure) -> EvalValue)? = nil,
        vars: [String: EngineVarDecl] = [:],
        seatNames: [String] = [],
        teamNames: [String] = [],
        teamOfSeat: [Int] = [],
        dealPhaseID: String? = nil,
        end: EngineEndSpec? = nil,
        afterDeal: [EngineEffect] = [],
        rebuild: (@Sendable (inout GameState) throws -> Void)? = nil,
        options: [String: String] = [:],
        dealerRotation: EngineDealerRotation = .left
    ) {
        self.phases = phases
        self.seatCount = seatCount
        self.setup = setup
        self.expressionRuntime = expressionRuntime
        self.vars = vars
        self.seatNames = seatNames.isEmpty ? (0..<seatCount).map { "S\($0 + 1)" } : seatNames
        self.teamNames = teamNames
        self.teamOfSeat = teamOfSeat
        self.dealPhaseID = dealPhaseID
        self.end = end
        self.afterDeal = afterDeal
        self.rebuild = rebuild
        self.options = options
        self.dealerRotation = dealerRotation
        self.rulesetHash = Engine.hash(
            of: phases, expressionRuntime: expressionRuntime, vars: vars,
            seatNames: self.seatNames, teamNames: teamNames, teamOfSeat: teamOfSeat,
            dealPhaseID: dealPhaseID, end: end, afterDeal: afterDeal, options: options,
            dealerRotation: dealerRotation)
    }

    /// Configuration hash: phase ids plus the identity of the installed
    /// expression runtime (§ P1: cache invalidation across builds). The
    /// ruleset-level configuration (vars, teams, end, effects, options)
    /// changes game behavior, so it joins the hash (§10.4).
    public static func hash(
        of phases: [PhaseConfig],
        expressionRuntime: (@Sendable (EvalCall, GameState) throws(EvalFailure) -> EvalValue)?,
        vars: [String: EngineVarDecl] = [:],
        seatNames: [String] = [],
        teamNames: [String] = [],
        teamOfSeat: [Int] = [],
        dealPhaseID: String? = nil,
        end: EngineEndSpec? = nil,
        afterDeal: [EngineEffect] = [],
        options: [String: String] = [:],
        dealerRotation: EngineDealerRotation = .left
    ) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = phases.map { $0.id }
        for name in vars.keys.sorted() {
            guard let decl = vars[name] else { continue }
            lines.append(
                "var:\(name):\(decl.decl.scope.rawValue):\(decl.decl.isHidden ? "hidden" : "open")")
        }
        lines.append("seats:\(seatNames.joined(separator: ","))")
        lines.append("teams:\(teamNames.joined(separator: ","))")
        lines.append("teamOfSeat:\(teamOfSeat.map(String.init).joined(separator: ","))")
        lines.append("dealPhase:\(dealPhaseID ?? "-")")
        lines.append(
            "options:\(options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        lines.append("afterDeal:\(afterDeal.count)")
        lines.append("dealerRotation:\(dealerRotation.rawValue)")
        if let end {
            let rank = end.rank
            let deals = end.deals.map(String.init) ?? "-"
            lines.append(
                "end:\(end.condition ?? "-"):\(deals):\(rank.scope.rawValue):"
                    + "\(rank.name):\(rank.descending ? "desc" : "asc"):\(rank.ties.rawValue):"
                    + "\(end.check.rawValue):\(end.matchEffects.count)"
            )
        }
        let payload = (try? encoder.encode(lines)) ?? Data()
        var digest = SHA256()
        digest.update(data: payload)
        digest.update(data: Data("runtime:\(expressionRuntime != nil)".utf8))
        return Data(digest.finalize())
    }

    func ctx(_ state: GameState) -> EvalContext {
        EvalContext(
            seatCount: seatCount, dealer: state.dealer, eval: expressionRuntime,
            seatNames: seatNames, teamNames: teamNames, teamOfSeat: teamOfSeat,
            options: options, effects: effectsRunner)
    }

    /// One runner per call site is cheap: `EffectsRunner` only captures
    /// context; all state it touches is passed per invocation.
    var effectsRunner: EffectsRunner? {
        guard expressionRuntime != nil else { return nil }
        let bare = EvalContext(seatCount: seatCount, eval: expressionRuntime)
        return EffectsRunner(
            ctx: bare, seatNames: seatNames, teamNames: teamNames, varDecls: vars)
    }

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
        if let setup {
            do {
                try setup(&state)
            } catch {
                throw AnyMechanic.violation(error)
            }
        }
        try initializeVars(&state)
        guard let first = phases.first else {
            throw RuleViolation.engineFault(ruleId: nil, pointer: "engine has no phases")
        }
        try enterPhase(first, state: &state, events: &events)
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
            if state.matchOver {
                state.enterPhase("done")
                events.append(.dealEnded)
                continue
            }
            guard let config = phases.first(where: { $0.id == state.phase.phaseID }) else {
                throw RuleViolation.engineFault(ruleId: nil, pointer: "unknown phase \(state.phase.phaseID)")
            }
            let outcome = config.mechanic.complete(state, ctx(state))
            let pending = config.mechanic.pending(state, ctx(state))
            if outcome == .continue || !pending.isEmpty { return }
            if outcome == .redeal {
                // §5.6: a mechanic may throw the deal in and redeal it —
                // deal-scoped state clears and the deal phase re-enters. No
                // afterDeal effects and no match-end check: a thrown-in deal
                // scores nothing. Dealer rotation is the mechanic's choice
                // (e.g. bridge's redealNextDealer option), not the engine's.
                try redealDeal(&state, &events)
                continue
            }
            if outcome == .endDeal {
                // §5.6: end the deal early and run the normal deal end —
                // afterDeal effects, rotation, resets, next deal or match end.
                try finishDeal(&state, &events)
                continue
            }
            if let next = nextStateIndex(after: config.id) {
                try enterPhase(phases[next], state: &state, events: &events)
            } else {
                // Last phase of the deal list completes → the deal ends
                // (§5.7): afterDeal effects, dealer rotation, per-deal
                // resets, re-enter the deal phase or close the match.
                try finishDeal(&state, &events)
            }
        }
    }

    /// Enters a phase, skipping it while its `when` gate is false (§5.6).
    /// The gate is evaluated before the phase runs any of its mechanics.
    private func enterPhase(
        _ config: PhaseConfig, state: inout GameState, events: inout [GameEvent]
    ) throws {
        var current = config
        var skipped = 0
        while let gate = current.gate {
            let open = try gate(state)
            guard !open else { break }
            guard let next = nextStateIndex(after: current.id) else {
                // Every later phase is gated shut and the deal list is
                // exhausted: the deal simply ends.
                return try finishDeal(&state, &events)
            }
            skipped += 1
            if skipped > phases.count {
                throw RuleViolation.engineFault(
                    ruleId: nil,
                    pointer: "phases when-gates skip every phase in a loop at '\(current.id)'")
            }
            current = phases[next]
        }
        state.enterPhase(current.id)
        events += try current.mechanic.enter(&state, ctx(state))
    }

    private func nextStateIndex(after id: String) -> Int? {
        guard let index = phases.firstIndex(where: { $0.id == id }) else { return nil }
        let next = phases.index(after: index)
        return next < phases.count ? next : nil
    }

    public func legalIntents(for seat: Seat, in state: GameState) -> [ActionIntent] {
        guard let config = phases.first(where: { $0.id == state.phase.phaseID }) else { return [] }
        return config.mechanic.legal(state, seat, ctx(state))
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
        let pending = config.mechanic.pending(state, ctx(state))
        guard pending.contains(action.seat) else {
            throw RuleViolation.notYourTurn(expected: pending)
        }
        events += try config.mechanic.act(action.intent, action.seat, &state, ctx(state))
        state.history.append(LoggedAction(seat: action.seat, intent: action.intent, version: state.version))
        state.version += 1
        try checkContinuousEnd(&state, &events)
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
                let transition = try apply(
                    Action(seat: logged.seat, intent: logged.intent, expectedVersion: logged.version), to: state)
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
        return config.mechanic.pending(state, ctx(state))
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
    @_spi(HostOnly) public static func redactCards(
        _ cards: [CardInstance], key: ZoneKey, viewer: Viewer, knowledge: KnowledgeStore
    ) -> ObservedZone {
        _ = key  // zone-level visibility defaults arrive with ruleset-driven zones in P2
        let known = cards.filter { Redactor.maySee($0.id, viewer: viewer, knowledge: knowledge, publicCard: false) }
        if known.count == cards.count { return .visible(cards) }
        return .hidden(count: cards.count, known: known)
    }
}
