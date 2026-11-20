import CardModel
import Foundation

/// Match lifecycle (§5.7, §5.8): per-deal reset and rotation, end
/// conditions, match ranking, and variable initialization.
extension Engine {
    /// Per-deal reset and rotation for the next deal (§5.7): run afterDeal
    /// effects, rotate the dealer, clear deal-scoped state, re-stack the
    /// table, reset per-deal vars, then re-enter the deal phase — or close
    /// the match when the end condition (§5.8) holds.
    func finishDeal(_ state: inout GameState, _ events: inout [GameEvent]) throws {
        state.dealIndex += 1

        if try endHolds(state) {
            state.matchOver = true
            state.winners = try rankWinners(state)
            if let runner = effectsRunner, let end, !end.matchEffects.isEmpty {
                try runner.run(
                    end.matchEffects, in: &state, events: &events, pointer: "match/end")
            }
            state.enterPhase("done")
            events.append(.dealEnded)
            return
        }
        // Next deal (§5.7): afterDeal effects, dealer rotation, clear
        // deal-scoped state, re-stack the table, reset per-deal vars,
        // re-enter the deal phase.
        if let runner = effectsRunner, !afterDeal.isEmpty {
            try runner.run(
                afterDeal, in: &state, events: &events, pointer: "match/afterDeal")
        }
        state.dealer = Seat((state.dealer.raw + 1) % seatCount)
        state.zones = ZoneStore()
        state.knowledge = KnowledgeStore()
        try resetPerDealVars(&state)
        if let rebuild {
            do {
                try rebuild(&state)
            } catch {
                throw AnyMechanic.violation(error)
            }
        }
        let dealID = dealPhaseID ?? phases[0].id
        guard let dealConfig = phases.first(where: { $0.id == dealID }) else {
            throw RuleViolation.engineFault(ruleId: nil, pointer: "unknown deal phase \(dealID)")
        }
        state.enterPhase(dealConfig.id)
        events += try dealConfig.mechanic.enter(&state, ctx(state))
    }

    /// §5.8: the match ends when `deals` deals have been played or the
    /// `condition` expression becomes true. No end spec means the phase list
    /// runs once and the match is over after the first deal.
    func endHolds(_ state: GameState) throws -> Bool {
        guard let end else { return true }
        if let deals = end.deals, state.dealIndex >= deals { return true }
        guard let condition = end.condition, !condition.isEmpty else { return false }
        guard let runner = effectsRunner else {
            throw RuleViolation.engineFault(ruleId: nil, pointer: "end/condition without expression runtime")
        }
        let value = try runner.eval(condition, state, bindings: [:], pointer: "end/condition")
        guard case .bool(let flag) = value else {
            throw RuleViolation.engineFault(ruleId: nil, pointer: "end/condition must be boolean")
        }
        return flag
    }

    /// §5.8 rank: order the ranked dimension by its variable and take the
    /// top value. Ranked vars are seat- or team-indexed; team winners expand
    /// back to seats via `teamOfSeat`.
    func rankWinners(_ state: GameState) throws -> [Seat] {
        guard let end else { return [] }
        let name = end.rank.name
        let store: (Int) -> VarValue?
        let positions: [Int]
        switch end.rank.scope {
        case .seatMatch, .seatDeal:
            positions = Array(0..<seatCount)
        case .teamMatch, .teamDeal:
            positions = Array(teamNames.indices)
        case .match, .deal:
            throw RuleViolation.engineFault(
                ruleId: nil, pointer: "rank/\(name) must be seat- or team-indexed")
        }
        store = { index in
            switch end.rank.scope {
            case .seatMatch, .teamMatch, .match: return state.matchVars.get(VarPath(name, index))
            case .seatDeal, .teamDeal, .deal: return state.dealVars.get(VarPath(name, index))
            }
        }
        var ranked: [(position: Int, value: Int)] = []
        for position in positions {
            guard let value = store(position) else {
                throw RuleViolation.engineFault(ruleId: nil, pointer: "rank/\(name) is unset for position \(position)")
            }
            guard case .int(let int) = value else {
                throw RuleViolation.engineFault(ruleId: nil, pointer: "rank/\(name) must be numeric")
            }
            ranked.append((position, int))
        }
        guard !ranked.isEmpty else {
            throw RuleViolation.engineFault(ruleId: nil, pointer: "rank/\(name) has no values")
        }
        let sorted = ranked.sorted { lhs, rhs in
            end.rank.descending ? lhs.value > rhs.value : lhs.value < rhs.value
        }
        let best = sorted[0].value
        let top = end.rank.ties == .shared ? sorted.filter { $0.value == best } : [sorted[0]]
        switch end.rank.scope {
        case .seatMatch, .seatDeal:
            return top.map { Seat($0.position) }
        case .teamMatch, .teamDeal:
            let winners = Set(top.map { $0.position })
            return (0..<seatCount).filter { winners.contains(teamOfSeat[$0]) }.map { Seat($0) }
        case .match, .deal:
            return []
        }
    }

    /// Declare all configured variables and write their initial values.
    func initializeVars(_ state: inout GameState) throws {
        for name in vars.keys.sorted() {
            guard let decl = vars[name] else { continue }
            try declareVar(name, decl, into: &state, reset: false)
        }
    }

    /// §5.7 per-deal reset: re-declare deal-scoped vars with their initial
    /// values; match-scoped vars survive the deal boundary.
    func resetPerDealVars(_ state: inout GameState) throws {
        for name in vars.keys.sorted() {
            guard let decl = vars[name] else { continue }
            switch decl.scope {
            case .deal, .seatDeal, .teamDeal:
                try declareVar(name, decl, into: &state, reset: true)
            case .match, .seatMatch, .teamMatch:
                continue
            }
        }
    }

    func declareVar(
        _ name: String, _ decl: EngineVarDecl,
        into state: inout GameState, reset: Bool
    ) throws {
        if reset {
            // Wipe this variable's entries from the deal store before
            // re-declaring so stale indices cannot survive.
            state.dealVars = VarStore()
        }
        switch decl.scope {
        case .match, .seatMatch, .teamMatch: state.matchVars.declare(name, decl.decl)
        case .deal, .seatDeal, .teamDeal: state.dealVars.declare(name, decl.decl)
        }
        let index = try varIndex(scope: decl.scope, state: state)
        let path = VarPath(name, index)
        switch decl.scope {
        case .match, .seatMatch, .teamMatch: state.matchVars.set(path, decl.decl.initial)
        case .deal, .seatDeal, .teamDeal: state.dealVars.set(path, decl.decl.initial)
        }
    }

    /// Index for the declaration write: plain vars index 0; seat/team vars
    /// start with the dealer's position (the only known owner at deal
    /// start) — effects overwrite the rest per seat/team.
    func varIndex(scope: EngineVarScope, state: GameState) throws -> Int? {
        switch scope {
        case .match, .deal: return nil
        case .seatMatch, .seatDeal: return state.dealer.raw
        case .teamMatch, .teamDeal:
            guard teamOfSeat.indices.contains(state.dealer.raw) else {
                throw RuleViolation.engineFault(ruleId: nil, pointer: "team vars configured without a team layout")
            }
            return teamOfSeat[state.dealer.raw]
        }
    }
}
