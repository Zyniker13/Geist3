// Environment construction for the expression runtime (ARCHITECTURE §7.5):
// each `EvalCall` plus the engine's `GameState` snapshot becomes the
// `EvaluationEnvironment` the evaluator runs against. The environment is a
// pure function of the snapshot and the resolved document (CONVENTIONS §5).

import CardModel
@_spi(HostOnly) import RulesEngine

extension ExpressionRuntime {

    /// Builds the per-call environment out of the state snapshot (§7.5).
    func environment(
        for call: EvalCall, state: GameState
    ) -> EvaluationEnvironment {
        let grouped = Self.zoneGroups(state)
        let zoneContents = Self.zoneContents(from: grouped)
        let trickState = trickSnapshot(state)
        let vars = loadVars(state)

        return EvaluationEnvironment(
            seats: seats,
            activeSeats: Set(seatSpellings),
            teams: teams,
            teamOfSeat: teamOfSeat,
            zoneContents: zoneContents,
            zoneReader: { id, owner in
                self.readZone(id, owner, grouped: grouped, state: state)
            },
            holderOf: { faceId in self.holder(of: faceId, state: state) },
            tricksWon: { target in self.tricksWon(target, wins: trickState.wins) },
            playedBy: { seat in self.playedBy(seat, state: state) },
            choice: { _, _ in .null },
            dealtHands: { [] },
            optionValues: optionValues,
            contextual: contextualBindings(for: call, state: state, zoneContents: zoneContents),
            trick: trickState.trick,
            playersCount: seatCount,
            dealIndex: state.dealIndex,
            plainVars: vars.plain,
            indexedVars: vars.indexed,
            orders: orders,
            natives: StandardNatives.all(teams: teams)
        )
    }

    /// Zone stacks grouped by zone id, keeping each group's raw owner
    /// position so reads can filter by seat or team.
    private static func zoneGroups(
        _ state: GameState
    ) -> [String: [(owner: Int, cards: [CardInstance])]] {
        var groups: [String: [(owner: Int, cards: [CardInstance])]] = [:]
        for (key, cards) in state.zones.zones {
            groups[key.id, default: []].append((owner: key.owner, cards: cards))
        }
        return groups
    }

    /// A bare zone id reads the union of every owner's stack, in seat
    /// order (§7.5).
    private static func zoneContents(
        from groups: [String: [(owner: Int, cards: [CardInstance])]]
    ) -> [String: [Value]] {
        groups.mapValues { entries in
            entries.sorted { $0.owner < $1.owner }
                .flatMap { $0.cards.map(cardValue) }
        }
    }

    /// Canonical roots (`dealer`), the call's contextual bindings, then
    /// every declared zone id exposed as a list value.
    private func contextualBindings(
        for call: EvalCall, state: GameState, zoneContents: [String: [Value]]
    ) -> [String: Value] {
        var contextual: [String: Value] = ["dealer": .string(seatSpelling(state.dealer))]
        for (name, value) in call.contextual {
            contextual[name] = Self.value(from: value)
        }
        for (id, values) in zoneContents where context.contextual[id] != nil {
            contextual[id] = .list(values)
        }
        return contextual
    }

    /// The trick sub-state snapshot, empty when no trick mechanic owns
    /// the current phase.
    private func trickSnapshot(
        _ state: GameState
    ) -> (trick: EvaluationEnvironment.TrickSnapshot, wins: [Int]) {
        guard case .trick(let substate) = state.phase.substate else {
            return (EvaluationEnvironment.TrickSnapshot(), [])
        }
        let trick = EvaluationEnvironment.TrickSnapshot(
            number: .int(Int64(substate.trickIndex)),
            leader: .string(seatSpelling(substate.leader)),
            cards: .list(substate.currentPlays.map { Self.cardInstanceValue($0.card, state: state) }),
            ledSuit: substate.currentPlays.first.flatMap {
                Self.cardInstanceValue($0.card, state: state).cardSuit
            }.map { .string($0) } ?? .null,
            winner: .null)
        return (trick, substate.tricksWon)
    }

    /// Reads every declared variable: plain scopes hold single values;
    /// per-seat and per-team scopes hold positional lists ordered by
    /// their index domain (§7.3). Indexed vars are stored by raw seat
    /// and team position.
    private func loadVars(
        _ state: GameState
    ) -> (plain: [VarRef: Value], indexed: [VarRef: [Value]]) {
        var plainVars: [VarRef: Value] = [:]
        var indexedVars: [VarRef: [Value]] = [:]
        for (name, binding) in context.vars {
            let ref = VarRef(store: binding.scope.store, scope: binding.scope, name: name)
            let store = ref.store == .match ? state.matchVars : state.dealVars
            switch ref.scope {
            case .match, .deal:
                if let value = store.get(VarPath(name)) {
                    plainVars[ref] = Self.value(from: value)
                }
            case .seatMatch, .seatDeal:
                let values = seatSpellings.indices.map { index in
                    store.get(VarPath(name, index)).map(Self.value(from:)) ?? .null
                }
                plainVars[ref] = .list(values)
                indexedVars[ref] = values
            case .teamMatch, .teamDeal:
                let values = teamSpellings.indices.map { index in
                    store.get(VarPath(name, index)).map(Self.value(from:)) ?? .null
                }
                plainVars[ref] = .list(values)
                indexedVars[ref] = values
            }
        }
        return (plainVars, indexedVars)
    }

    /// `zone(id, seat | team)`: filter the zone's stacks to one seat or
    /// to every seat of one team; unknown owners read empty.
    private func readZone(
        _ id: String,
        _ owner: Value?,
        grouped: [String: [(owner: Int, cards: [CardInstance])]],
        state: GameState
    ) -> [Value] {
        guard let entries = grouped[id] else { return [] }
        guard let owner else {
            return entries.sorted { $0.owner < $1.owner }
                .flatMap { $0.cards.map(Self.cardValue) }
        }
        if case .string(let name) = owner {
            if let seat = seatIndex[name] {
                return entries.filter { $0.owner == seat }
                    .flatMap { $0.cards.map(Self.cardValue) }
            }
            if let team = teamIndex[name] {
                let teamName = teamSpellings[team]
                let members =
                    teamOfSeat
                    .filter { $0.value == teamName }
                    .map { seatIndex[$0.key] ?? -1 }
                return entries.filter { members.contains($0.owner) }
                    .flatMap { $0.cards.map(Self.cardValue) }
            }
        }
        return []
    }

    /// First face-up instance with that face id, in zone-scan order; a
    /// shared-deck ruleset never holds one face twice.
    private func holder(of faceId: String, state: GameState) -> Value {
        for instance in state.zones.allInstances where instance.face.id == faceId {
            if let owner = state.zones.zoneOf(instance.id) {
                let raw = owner.owner
                let spelling =
                    raw >= 0 && raw < seatSpellings.count ? seatSpellings[raw] : ""
                return .string(spelling)
            }
        }
        return .null
    }

    /// Tricks won this deal by a seat or a team.
    private func tricksWon(_ target: Value, wins: [Int]) -> Int64 {
        guard case .string(let name) = target else { return 0 }
        if let seat = seatIndex[name] {
            return Int64(wins.indices.contains(seat) ? wins[seat] : 0)
        }
        guard let team = teamIndex[name] else { return 0 }
        let teamName = teamSpellings[team]
        let members =
            teamOfSeat
            .filter { $0.value == teamName }
            .compactMap { seatIndex[$0.key] }
        return Int64(
            members.reduce(0) {
                wins.indices.contains($1) ? $0 + wins[$1] : $0
            })
    }

    /// Cards a seat played into the current trick.
    private func playedBy(_ seat: String, state: GameState) -> [Value] {
        guard case .trick(let substate) = state.phase.substate,
            let index = seatIndex[seat]
        else { return [] }
        return substate.currentPlays
            .filter { $0.seat.raw == index }
            .map { Self.cardInstanceValue($0.card, state: state) }
    }

    /// A seat's spelling (§7.3 `seat(n)`), empty out of range.
    private func seatSpelling(_ seat: Seat) -> String {
        guard seat.raw >= 0, seat.raw < seats.count,
            case .string(let spelling) = seats[seat.raw]
        else { return "" }
        return spelling
    }

    /// Spelling → raw index table; the first occurrence wins on
    /// duplicates (validated documents never repeat spellings).
    static func indexTable(_ spellings: [String]) -> [String: Int] {
        var table: [String: Int] = [:]
        for (index, spelling) in spellings.enumerated() where table[spelling] == nil {
            table[spelling] = index
        }
        return table
    }
}
