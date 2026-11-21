// The effect language runtime (§5.6 "effects" blocks, §5.8 score).
//
// Ruleset effects are a closed vocabulary (`set`, `add`, `let`, `if`,
// `forEach`, `move`, `emit`) that phases run at their edges: after the
// deal, when a trick ends, on each score visit, and at match end. The
// RulesetKit schema layer owns the JSON shape and maps it into the engine
// AST below; the engine owns the interpreter so effects execute against
// `GameState` inside `RulesEngine`.
//
// Expressions inside effects (values, conditions, indices, card lists)
// evaluate through the same `EvalContext.eval` bridge as every mechanic
// expression, so effects and rules share one evaluator. Any failure is a
// broken ruleset and surfaces as `RuleViolation.engineFault` (§7.4): an
// effect never fails silently.

import CardModel

/// Storage scopes for a ruleset variable, mirroring `VarScope` values.
public enum EngineVarScope: String, Sendable {
    case match
    case deal
    case seatMatch
    case seatDeal
    case teamMatch
    case teamDeal
}

/// An engine-side variable declaration: the addressable name plus the
/// schema-derived declaration it initializes stores with.
public struct EngineVarDecl: Sendable {
    public let name: String
    public let scope: EngineVarScope
    /// Declared value type (`int`, `bool`, `string`, `suit`, `seat`, `team`).
    public let type: String
    public let decl: VarDecl

    public init(name: String, scope: EngineVarScope, type: String, isHidden: Bool, initial: VarValue) {
        self.name = name
        self.scope = scope
        self.type = type
        self.decl = VarDecl(scope: VarScope(rawValue: scope.rawValue) ?? .match, isHidden: isHidden, initial: initial)
    }
}

/// The index owner kind for `forEach`.
public enum EngineOwnerKind: Codable, Hashable, Sendable {
    case seat
    case team
}

/// The engine effect AST (§5.6). Expression fragments keep their verbatim
/// source and evaluate at run time.
public enum EngineEffect: Codable, Hashable, Sendable {
    /// `set <var> to <expr>`
    case set(name: String, index: String?, value: String)
    /// `add <expr> to <var>` (numeric deltas only).
    case add(name: String, index: String?, value: String, event: String?)
    /// `let <name> = <expr>` — scopes over the remainder of the list.
    case letBinding(name: String, be: String)
    /// `if <expr> then ... else ...`
    case ifElse(condition: String, thenBranch: [EngineEffect], elseBranch: [EngineEffect])
    /// `forEach <seat|team> ...` — binds `s` (seat) or `t` (team) spelling.
    case forEach(owner: EngineOwnerKind, body: [EngineEffect])
    /// `move <cards> from <zone> to <zone>` with an optional seat/team owner.
    case move(from: String, to: String, owner: OwnerTarget?, cards: MoveCards)
    /// `reveal <zone>` to a seat (or everyone).
    case reveal(zone: String, seat: String?, to: RevealTarget)
    /// `emit <name>`
    case emit(name: String)

    public enum OwnerTarget: Codable, Hashable, Sendable {
        case seat(String)
        case team(String)
    }

    /// Who learns the revealed contents: everyone, or the seats the
    /// expression produces (a list of seat spellings).
    public enum RevealTarget: Codable, Hashable, Sendable {
        case all
        case seats(String)
    }

    public enum MoveCards: Codable, Hashable, Sendable {
        case all
        case top(Int)
        case expr(String)
    }
}

/// Runs effect lists against `GameState` inside `RulesEngine`. One runner
/// is enough for the whole engine; effect blocks never run concurrently.
@_spi(HostOnly)
public final class EffectsRunner: Sendable {
    private let ctx: EvalContext
    /// Seat spellings, in seat order: index expressions resolve against
    /// this list exactly like the expression runtime's indexed variable
    /// reads (§7.3).
    private let seatNames: [String]
    /// Team spellings, in team order.
    private let teamNames: [String]
    private let varDecls: [String: EngineVarDecl]

    public init(ctx: EvalContext, seatNames: [String], teamNames: [String], varDecls: [String: EngineVarDecl]) {
        self.ctx = ctx
        self.seatNames = seatNames
        self.teamNames = teamNames
        self.varDecls = varDecls
    }

    /// Execute effects in order, appending to `events`. `bindings` carries
    /// `let` names and `forEach` loop variables; bindings from `let` stay
    /// visible to the remainder of the list.
    public func run(
        _ effects: [EngineEffect],
        in state: inout GameState,
        bindings: [String: EvalValue] = [:],
        events: inout [GameEvent],
        pointer: String
    ) throws(RuleViolation) {
        var bound = bindings
        try runList(effects, in: &state, bindings: &bound, events: &events, pointer: pointer)
    }

    private func runList(
        _ effects: [EngineEffect],
        in state: inout GameState,
        bindings: inout [String: EvalValue],
        events: inout [GameEvent],
        pointer: String
    ) throws(RuleViolation) {
        for (offset, effect) in effects.enumerated() {
            try runOne(
                effect, in: &state, bindings: &bindings, events: &events,
                pointer: "\(pointer)/\(offset)")
        }
    }

    private func runOne(
        _ effect: EngineEffect,
        in state: inout GameState,
        bindings: inout [String: EvalValue],
        events: inout [GameEvent],
        pointer: String
    ) throws(RuleViolation) {
        switch effect {
        case .set(let name, let index, let value):
            let decl = try self.decl(name, pointer: pointer)
            let target = try varPath(decl, index, state, bindings, pointer)
            let evalValue = try evaluate(value, bindings, state, pointer)
            let stored = try coerce(evalValue, to: decl.type, pointer: pointer)
            switch decl.scope {
            case .match, .seatMatch, .teamMatch: state.matchVars.set(target, stored)
            case .deal, .seatDeal, .teamDeal: state.dealVars.set(target, stored)
            }

        case .add(let name, let index, let value, let event):
            let decl = try self.decl(name, pointer: pointer)
            let target = try varPath(decl, index, state, bindings, pointer)
            let evalValue = try evaluate(value, bindings, state, pointer)
            guard case .int(let delta) = evalValue, let delta = Int(exactly: delta) else {
                throw fault(pointer, "add needs an int, got \(evalValue)")
            }
            if let current = varStore(scope: decl.scope, state: state).get(target), !isInt(current) {
                throw fault(pointer, "add to non-int variable '\(name)'")
            }
            switch decl.scope {
            case .match, .seatMatch, .teamMatch: state.matchVars.add(target, delta)
            case .deal, .seatDeal, .teamDeal: state.dealVars.add(target, delta)
            }
            if let event {
                events.append(.emitted(name: event))
            }

        case .letBinding(let name, let be):
            bindings[name] = try evaluate(be, bindings, state, pointer)

        case .ifElse(let condition, let thenBranch, let elseBranch):
            let value = try evaluate(condition, bindings, state, pointer)
            guard case .bool(let flag) = value else {
                throw fault(pointer, "if condition must be bool, got \(value)")
            }
            try runList(
                flag ? thenBranch : elseBranch, in: &state, bindings: &bindings,
                events: &events, pointer: "\(pointer)/if")

        case .forEach(let owner, let body):
            let loopVar = owner == .seat ? "s" : "t"
            let previous = bindings[loopVar]
            defer { bindings[loopVar] = previous }
            for spelling in owner == .seat ? seatNames : teamNames {
                bindings[loopVar] = .string(spelling)
                try runList(
                    body, in: &state, bindings: &bindings, events: &events,
                    pointer: "\(pointer)/\(spelling)")
            }

        case .move(let from, let to, let owner, let cards):
            try runMove(
                from: from, to: to, owner: owner, cards: cards,
                in: &state, bindings: bindings, events: &events, pointer: pointer)

        case .reveal(let zone, let seatExpr, let target):
            try runReveal(
                zone: zone, seat: seatExpr, target: target,
                in: &state, bindings: bindings, events: &events, pointer: pointer)

        case .emit(let name):
            events.append(.emitted(name: name))
        }
    }

    // MARK: - Internals

    private func fault(_ pointer: String, _ detail: String) -> RuleViolation {
        .engineFault(ruleId: nil, pointer: "\(pointer): \(detail)")
    }

    /// Evaluates one expression through the host runtime (used for §5.8
    /// end conditions and by mechanics that run effects ad hoc).
    public func eval(
        _ source: String, _ state: GameState,
        bindings: [String: EvalValue] = [:], pointer: String
    ) throws(RuleViolation) -> EvalValue {
        try evaluate(source, bindings, state, pointer)
    }

    private func evaluate(_ source: String, _ bindings: [String: EvalValue], _ state: GameState, _ pointer: String)
        throws(RuleViolation) -> EvalValue
    {
        guard let eval = ctx.eval else {
            throw fault(pointer, "effects require an expression runtime")
        }
        do {
            return try eval(EvalCall(pointer: pointer, source: source, ruleId: nil, contextual: bindings), state)
        } catch {
            throw fault(pointer, "expression '\(source)' failed: \(error)")
        }
    }

    private func decl(_ name: String, pointer: String) throws(RuleViolation) -> EngineVarDecl {
        if let direct = varDecls[name] { return direct }
        // Effects spell variables as scope-qualified paths ("deal.trump",
        // "match.score[t]"): the prefix is the read/write surface, the
        // declared name is bare (§5.3). Resolve the bare name and check the
        // prefix agrees with the declared scope so authoring errors surface.
        let parts = name.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count == 2, let bare = parts.last.map(String.init) else {
            throw fault(pointer, "unknown variable '\(name)'")
        }
        guard let decl = varDecls[bare] else {
            throw fault(pointer, "unknown variable '\(name)'")
        }
        switch (parts.first.map(String.init), decl.scope) {
        case ("match", .match), ("match", .seatMatch), ("match", .teamMatch),
            ("deal", .deal), ("deal", .seatDeal), ("deal", .teamDeal):
            return decl
        default:
            throw fault(pointer, "variable '\(name)' does not match its declared scope")
        }
    }

    private func varPath(
        _ decl: EngineVarDecl, _ index: String?, _ state: GameState, _ bindings: [String: EvalValue], _ pointer: String
    ) throws(RuleViolation) -> VarPath {
        switch (decl.scope, index) {
        case (.match, nil), (.deal, nil):
            return VarPath(decl.name)
        case (.match, .some), (.deal, .some):
            throw fault(pointer, "variable '\(decl.name)' takes no index")
        case (.seatMatch, let index?), (.seatDeal, let index?):
            let value = try evaluate(index, bindings, state, pointer)
            return VarPath(decl.name, try position(of: value, in: seatNames, domain: "seat", pointer: pointer))
        case (.teamMatch, let index?), (.teamDeal, let index?):
            let value = try evaluate(index, bindings, state, pointer)
            return VarPath(decl.name, try position(of: value, in: teamNames, domain: "team", pointer: pointer))
        case (_, nil):
            throw fault(pointer, "variable '\(decl.name)' is seat/team indexed but no index was given")
        }
    }

    private func position(of value: EvalValue, in names: [String], domain: String, pointer: String)
        throws(RuleViolation) -> Int
    {
        guard case .string(let spelling) = value,
            let position = names.firstIndex(of: spelling)
        else {
            throw fault(pointer, "'\(value)' is not in the \(domain) order")
        }
        return position
    }

    /// Reveal a zone's current contents to the target seats (or everyone):
    /// §5.4 `{ reveal: { zone, seat?, to } }`. `seat` scopes the zone to one
    /// seat's copy; `to: "all"` makes the contents public knowledge.
    private func runReveal(
        zone: String,
        seat: String?,
        target: EngineEffect.RevealTarget,
        in state: inout GameState,
        bindings: [String: EvalValue],
        events: inout [GameEvent],
        pointer: String
    ) throws(RuleViolation) {
        let sourceKey: ZoneKey
        if let seatExpr = seat {
            let value = try evaluate(seatExpr, bindings, state, pointer)
            let position = try position(of: value, in: seatNames, domain: "seat", pointer: pointer)
            sourceKey = ZoneKey(scope: .seat, owner: position, id: zone)
        } else {
            sourceKey = ZoneKey(scope: .shared, owner: 0, id: zone)
        }
        guard state.zones.zones[sourceKey] != nil else {
            throw fault(pointer, "unknown zone '\(zone)'")
        }
        let instances = state.zones.cards(in: sourceKey)
        let viewers: SeatSet
        switch target {
        case .all:
            viewers = SeatSet((0..<seatNames.count).map(Seat.init))
        case .seats(let source):
            let value = try evaluate(source, bindings, state, pointer)
            guard case .list(let items) = value else {
                throw fault(pointer, "reveal target must be a seat list, got \(value)")
            }
            var set = SeatSet()
            for item in items {
                guard case .string(let spelling) = item else {
                    throw fault(pointer, "reveal target produced a non-seat value \(item)")
                }
                guard let seatPosition = seatNames.firstIndex(of: spelling) else {
                    throw fault(pointer, "'\(spelling)' is not in the seat order")
                }
                set.insert(Seat(seatPosition))
            }
            viewers = set
        }
        for instance in instances {
            state.knowledge.reveal(instance.id, to: viewers)
        }
        events.append(.revealed(zone: zone, cards: instances))
    }

    private func varStore(scope: EngineVarScope, state: GameState) -> VarStore {
        switch scope {
        case .match, .seatMatch, .teamMatch: return state.matchVars
        case .deal, .seatDeal, .teamDeal: return state.dealVars
        }
    }

    private func isInt(_ value: VarValue) -> Bool {
        if case .int = value { return true }
        return false
    }

    private func coerce(_ value: EvalValue, to type: String, pointer: String) throws(RuleViolation) -> VarValue {
        // Declared types are plain strings; a trailing `?` marks an optional
        // variable, which accepts the same values as its base type.
        let base = type.hasSuffix("?") ? String(type.dropLast()) : type
        switch (base, value) {
        case ("int", .int(let v)):
            guard let v = Int(exactly: v) else { throw fault(pointer, "int overflow") }
            return .int(v)
        case ("bool", .bool(let b)):
            return .bool(b)
        case ("seat", .string(let spelling)):
            guard let position = seatNames.firstIndex(of: spelling) else {
                throw fault(pointer, "'\(spelling)' is not a seat")
            }
            return .seat(Seat(position))
        case (_, .record(let name, let fields)):
            var stored: [String: VarValue] = [:]
            for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
                stored[key] = try coerceRecordField(field, pointer: pointer)
            }
            return .record(name: name, fields: stored)
        case (_, .string(let s)):
            return .string(s)
        case (_, .null):
            return .null
        default:
            throw fault(pointer, "cannot set a \(type) variable to \(value)")
        }
    }

    private func runMove(
        from: String,
        to: String,
        owner: EngineEffect.OwnerTarget?,
        cards: EngineEffect.MoveCards,
        in state: inout GameState,
        bindings: [String: EvalValue],
        events: inout [GameEvent],
        pointer: String
    ) throws(RuleViolation) {
        let sourceKeys = state.zones.zones.keys.filter { $0.id == from }.sorted { $0.storageKey < $1.storageKey }
        guard sourceKeys.count == 1, let source = sourceKeys.first else {
            throw fault(pointer, "source zone '\(from)' is not unique")
        }
        let destination: ZoneKey
        switch owner {
        case .seat(let expr):
            let value = try evaluate(expr, bindings, state, pointer)
            let position = try position(of: value, in: seatNames, domain: "seat", pointer: pointer)
            destination = ZoneKey(scope: .seat, owner: position, id: to)
        case .team(let expr):
            let value = try evaluate(expr, bindings, state, pointer)
            let position = try position(of: value, in: teamNames, domain: "team", pointer: pointer)
            destination = ZoneKey(scope: .team, owner: position, id: to)
        case nil:
            destination = ZoneKey(scope: .shared, owner: 0, id: to)
        }
        guard state.zones.zones[destination] != nil else {
            throw fault(pointer, "unknown destination zone '\(to)'")
        }

        let moved: [CardID]
        switch cards {
        case .all:
            moved = state.zones.cards(in: source).map(\.id)
            do {
                try state.zones.move(moved, from: source, to: destination)
            } catch {
                throw fault(pointer, "move from '\(from)' failed: \(error)")
            }
        case .top(let count):
            guard count >= 0 else { throw fault(pointer, "top count must be non-negative") }
            // Preserve order: pop the topmost cards, then place them so the
            // first-popped card ends up on top of the destination.
            var popped: [CardInstance] = []
            for _ in 0..<count {
                do {
                    guard let instance = try state.zones.popTop(from: source) else {
                        throw fault(pointer, "zone '\(from)' has fewer than \(count) cards")
                    }
                    popped.append(instance)
                } catch {
                    throw fault(pointer, "pop from '\(from)' failed: \(error)")
                }
            }
            for instance in popped.reversed() {
                do {
                    try state.zones.place(instance, in: destination)
                } catch {
                    throw fault(pointer, "place into '\(to)' failed: \(error)")
                }
            }
            moved = popped.map(\.id)
        case .expr(let selector):
            let value = try evaluate(selector, bindings, state, pointer)
            guard case .list(let items) = value else {
                throw fault(pointer, "card selector must be a list, got \(value)")
            }
            var ids: [CardID] = []
            for item in items {
                guard case .card(let id, _, _) = item else {
                    throw fault(pointer, "card selector produced a non-card value \(item)")
                }
                guard let instance = state.zones.allInstances.first(where: { $0.face.id == id }) else {
                    throw fault(pointer, "no card in play with id '\(id)'")
                }
                ids.append(instance.id)
            }
            do {
                try state.zones.move(ids, from: source, to: destination)
            } catch {
                throw fault(pointer, "move from '\(from)' failed: \(error)")
            }
            moved = ids
        }
        events.append(.cardsMoved(from: from, to: to, count: moved.count))
    }
}

// MARK: - Record coercion

extension EffectsRunner {
    /// Records declared with plain string types (e.g. `contract?`) carry no
    /// per-field schema in the engine, so record fields convert structurally:
    /// each value keeps its own kind, nested records recurse, and only an
    /// out-of-range integer or an un-storable card/list faults.
    private func coerceRecordField(
        _ field: EvalValue, pointer: String
    ) throws(RuleViolation) -> VarValue {
        switch field {
        case .int(let v):
            guard let v = Int(exactly: v) else { throw fault(pointer, "int overflow") }
            return .int(v)
        case .bool(let b):
            return .bool(b)
        case .string(let s):
            return .string(s)
        case .record(let name, let fields):
            var nested: [String: VarValue] = [:]
            for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
                nested[key] = try coerceRecordField(field, pointer: pointer)
            }
            return .record(name: name, fields: nested)
        case .null:
            return .null
        case .card, .list:
            throw fault(pointer, "cannot store \(field) in a record field")
        }
    }
}
