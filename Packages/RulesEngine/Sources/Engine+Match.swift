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
            try closeMatch(&state, &events)
            return
        }
        // Next deal (§5.7): afterDeal effects, dealer rotation, clear
        // deal-scoped state, re-stack the table, reset per-deal vars,
        // re-enter the deal phase.
        if let runner = effectsRunner, !afterDeal.isEmpty {
            try runner.run(
                afterDeal, in: &state, events: &events, pointer: "match/afterDeal")
        }
        // Rotate the dealer (§5.7): left/alternate move to the next seat
        // (alternate is only valid for two seats — builder-checked), right
        // wraps backwards, fixed keeps the dealer.
        let delta: Int
        switch dealerRotation {
        case .left, .alternate: delta = 1
        case .right: delta = seatCount - 1
        case .fixed: delta = 0
        }
        if delta > 0 {
            state.dealer = Seat((state.dealer.raw + delta) % seatCount)
        }
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

    /// A mechanic redealt the deal (§5.6 `allPass: redeal`): deal-scoped
    /// state clears, the table re-stacks, and the deal phase re-enters. No
    /// afterDeal effects and no match-end check: a thrown-in deal scores
    /// nothing. Dealer rotation is the mechanic's choice, made before it
    /// reports the redeal (§5.7 redealNextDealer / redealSameDealer).
    func redealDeal(_ state: inout GameState, _ events: inout [GameEvent]) throws {
        state.dealIndex += 1
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

    /// Close the match (§5.8): mark it over, rank the winners, run the
    /// end block's match effects, and enter the done phase.
    func closeMatch(_ state: inout GameState, _ events: inout [GameEvent]) throws {
        state.matchOver = true
        state.winners = try rankWinners(state)
        if let runner = effectsRunner, let end, !end.matchEffects.isEmpty {
            try runner.run(end.matchEffects, in: &state, events: &events, pointer: "match/end")
        }
        state.enterPhase("done")
        events.append(.dealEnded)
    }

    /// §5.3 continuous end check: with `check: "continuous"` a score
    /// crossing the target ends the match immediately, even mid-deal. Runs
    /// after every applied action; a no-op for afterDeal and afterTrick.
    func checkContinuousEnd(_ state: inout GameState, _ events: inout [GameEvent]) throws {
        guard let end, end.check == .continuous, !state.matchOver else { return }
        guard try endHolds(state) else { return }
        try closeMatch(&state, &events)
    }

    /// §5.8: the match ends when `deals` deals have been played or the
    /// `condition` expression becomes true. No end spec means the phase list
    /// runs once and the match is over after the first deal.
    func endHolds(_ state: GameState) throws -> Bool {
        guard let end else { return true }
        if let deals = end.deals, state.dealIndex >= deals { return true }
        guard let condition = end.condition, !condition.isEmpty else { return false }
        guard let runner = effectsRunner else {
            throw RuleViolation.engineFault(ruleId: end.ruleId, pointer: "end/condition without expression runtime")
        }
        let value = try runner.eval(condition, state, bindings: [:], pointer: "end/condition")
        guard case .bool(let flag) = value else {
            throw RuleViolation.engineFault(ruleId: end.ruleId, pointer: "end/condition must be boolean")
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
                ruleId: end.ruleId, pointer: "rank/\(name) must be seat- or team-indexed")
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
                throw RuleViolation.engineFault(
                    ruleId: end.ruleId,
                    pointer: "rank/\(name) is unset for position \(position)")
            }
            guard case .int(let int) = value else {
                throw RuleViolation.engineFault(ruleId: end.ruleId, pointer: "rank/\(name) must be numeric")
            }
            ranked.append((position, int))
        }
        guard !ranked.isEmpty else {
            throw RuleViolation.engineFault(ruleId: end.ruleId, pointer: "rank/\(name) has no values")
        }
        let sorted = ranked.sorted { lhs, rhs in
            end.rank.descending ? lhs.value > rhs.value : lhs.value < rhs.value
        }
        let best = sorted[0].value
        // §5.8 ties: `shared` shares the win; `playOff` (playoffs are not
        // automated in P3) and `impossible` (declared impossible) fault when
        // a tie actually occurs.
        let top: [(position: Int, value: Int)]
        switch end.rank.ties {
        case .shared:
            top = sorted.filter { $0.value == best }
        case .playOff:
            guard sorted.count == 1 || sorted[1].value != best else {
                throw RuleViolation.engineFault(
                    ruleId: end.ruleId,
                    pointer: "rank/\(name) tied at \(best) — playOff is not automated")
            }
            top = [sorted[0]]
        case .impossible:
            guard sorted.count == 1 || sorted[1].value != best else {
                throw RuleViolation.engineFault(
                    ruleId: end.ruleId,
                    pointer: "rank/\(name) tied at \(best) — the ruleset declares ties impossible")
            }
            top = [sorted[0]]
        }
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
        // §5.7: a declaration's initial value applies to every instance of
        // the variable — every seat, every team, or the single plain slot —
        // so reads (match-end ranking included) never see an unset var.
        switch decl.scope {
        case .match:
            state.matchVars.set(VarPath(name), decl.decl.initial)
        case .deal:
            state.dealVars.set(VarPath(name), decl.decl.initial)
        case .seatMatch:
            for seat in 0..<seatCount {
                state.matchVars.set(VarPath(name, seat), decl.decl.initial)
            }
        case .seatDeal:
            for seat in 0..<seatCount {
                state.dealVars.set(VarPath(name, seat), decl.decl.initial)
            }
        case .teamMatch:
            for team in try teamIndices() {
                state.matchVars.set(VarPath(name, team), decl.decl.initial)
            }
        case .teamDeal:
            for team in try teamIndices() {
                state.dealVars.set(VarPath(name, team), decl.decl.initial)
            }
        }
    }

    /// Valid owner indices for team-scoped vars; faults when the ruleset
    /// declares team vars without a team layout.
    private func teamIndices() throws -> [Int] {
        guard !teamNames.isEmpty else {
            throw RuleViolation.engineFault(
                ruleId: nil, pointer: "team vars configured without a team layout")
        }
        return Array(teamNames.indices)
    }
}
