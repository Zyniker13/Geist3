// Schema→engine mapping for the match substrate (§5.2–5.3, §5.6–5.8):
// variables, teams, the end declaration, the effect vocabulary, and the
// first-dealer procedure. The builder itself stays a pure function of the
// document (CONVENTIONS §5); the first-dealer draw consumes the run's own
// seeded RNG inside the setup step, so a seed replays the pick exactly.
//
// Anything the P3 reference games do not need is reported as
// `SimulationError.unsupported` — the simulator never fakes a rule.

import CardExpr
import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine

extension EngineBuilder {
    // MARK: - Variables (§5.7)

    /// Map the document's `vars` block to engine declarations. P3.1
    /// supports literal initials (integers, booleans, `null`, quoted
    /// strings); expression-initial variables are out of scope until a
    /// reference game needs them.
    static func mapVars(_ fields: [JSONField]?) throws(SimulationError) -> [String: EngineVarDecl] {
        guard let fields else { return [:] }
        var out: [String: EngineVarDecl] = [:]
        for field in fields {
            let decl: VarDecl
            do {
                decl = try VarDecl(json: field.value, path: "vars.\(field.key)")
            } catch {
                throw .config(describeSchemaError(error, for: field.key))
            }
            guard let scope = EngineVarScope(rawValue: decl.scope) else {
                throw .unsupported("var scope \(decl.scope) for \(field.key)")
            }
            let initial = try literalInitial(decl.initial, name: field.key)
            out[field.key] = EngineVarDecl(
                name: field.key, scope: scope, type: decl.type,
                isHidden: false, initial: initial)
        }
        return out
    }

    /// Convert a literal initial expression to an engine `VarValue`.
    /// Anything that is not a literal comes back as unsupported.
    private static func literalInitial(
        _ expr: Expr, name: String
    ) throws(SimulationError) -> VarValue {
        let ast: AST
        do {
            ast = try Parser().parse(expr.source).ast
        } catch {
            throw .config("var initial for \(name) does not parse: \(expr.source)")
        }
        switch ast {
        case .int(let v, _): return .int(Int(v))
        case .bool(let v, _): return .bool(v)
        case .null: return .null
        case .string(let v, _): return .string(v)
        case .unary(let op, let inner, _):
            guard op == .negate, case .int(let v, _) = inner else {
                throw .unsupported("var initial of \(name)")
            }
            return .int(-Int(v))
        default:
            throw .unsupported("var initial of \(name)")
        }
    }

    /// Render a SchemaError as a config message; the mapper never surfaces
    /// schema internals past this point.
    private static func describeSchemaError(_ error: any Error, for key: String) -> String {
        guard let schema = error as? SchemaError else {
            return "unreadable var \(key)"
        }
        switch schema {
        case .parse(let message):
            return "ruleset parse error: \(message)"
        case .notObject(let path):
            return "wrong shape at \(path)"
        case .missingKey(let key, let path):
            return "missing \(key) at \(path)"
        case .wrongType(let expected, let path):
            return "expected \(expected) at \(path)"
        case .formatMismatch(let expected, let actual):
            return "format marker \(actual), expected \(expected)"
        }
    }

    // MARK: - Teams (§5.2)

    /// Map `players.teams` to engine team layout. `partnershipOpposite`
    /// pairs seat i with seat i%2 and spells each team by concatenating
    /// its seat names (the spelling P2 established); `none` runs solo.
    static func mapTeams(
        _ players: PlayersSpec?, seatCount: Int
    ) throws(SimulationError) -> (names: [String], teamOfSeat: [Int]) {
        guard let teams = players?.teams else { return ([], []) }
        switch teams {
        case "none":
            return ([], [])
        case "partnershipOpposite":
            guard seatCount % 2 == 0 else {
                throw .config("partnershipOpposite needs an even seat count (got \(seatCount))")
            }
            var names: [String] = []
            let seatNames = players?.seatNames ?? []
            for half in 0..<2 {
                let seats = (half..<seatCount).filter { $0 % 2 == half }
                names.append(seats.map { seatName($0, seatNames) }.joined())
            }
            return (names, (0..<seatCount).map { $0 % 2 })
        default:
            throw .unsupported("team layout \(teams)")
        }
    }

    /// Spell one seat for team-name concatenation: the declared seat name
    /// when present, otherwise a positional fallback.
    private static func seatName(_ seat: Int, _ seatNames: [String]) -> String {
        guard seat < seatNames.count else { return "Seat \(seat)" }
        return seatNames[seat]
    }

    // MARK: - Match end (§5.8)

    /// Map the document's `end` block to the engine end configuration:
    /// one of a `when` condition or a `maxDeals` cap, plus the rank used
    /// to pick winners and any match effects to run at close.
    static func mapEnd(
        _ end: EndDecl?, vars: [String: EngineVarDecl]
    ) throws(SimulationError) -> EngineEndSpec? {
        guard let end else { return nil }
        if end.maxDeals != nil && end.when != nil {
            throw .config("end declares both maxDeals and when")
        }
        if end.maxDeals == nil && end.when == nil {
            throw .config("end declares neither maxDeals nor when")
        }
        let condition = end.when.map(\.source)
        let rank = try mapRank(end, vars: vars)
        let effects = try mapEffects(end.matchEffects)
        return EngineEndSpec(
            condition: condition, deals: end.maxDeals, rank: rank,
            check: try mapEndCheck(end.check), ruleId: end.rule,
            matchEffects: effects)
    }

    /// Map the `check` string to the engine's end-check timing.
    private static func mapEndCheck(_ raw: String) throws(SimulationError) -> EngineEndCheck {
        guard let check = EngineEndCheck(rawValue: raw) else {
            throw .unsupported("end.check \(raw)")
        }
        return check
    }

    /// Parse the `rank` string ("descending(match.score)") into the
    /// engine rank spec: direction, scope+name, tie policy.
    private static func mapRank(
        _ end: EndDecl, vars: [String: EngineVarDecl]
    ) throws(SimulationError) -> EngineRankSpec {
        let rank = end.rank
        let open = rank.firstIndex(of: "(")
        let close = rank.lastIndex(of: ")")
        guard let open, let close, open < close, close == rank.index(before: rank.endIndex) else {
            throw .config("end.rank must look like descending(match.score), got \(rank)")
        }
        let direction = String(rank[rank.startIndex..<open])
        let path = String(rank[rank.index(after: open)..<close])
        guard direction == "descending" || direction == "ascending" else {
            throw .unsupported("rank direction \(direction)")
        }
        let (family, name) = try splitVarPath(path)
        // The path prefix ("match." / "deal.") is the read surface; the
        // ranked scope is the declared variable's own scope.
        guard let declared = vars[name] else {
            throw .config("end.rank names undeclared var \(name)")
        }
        let expectedFamily: String
        switch declared.scope {
        case .match, .seatMatch, .teamMatch: expectedFamily = "match"
        case .deal, .seatDeal, .teamDeal: expectedFamily = "deal"
        }
        guard family == expectedFamily else {
            throw .config("end.rank path \(path) disagrees with var \(name) scope \(declared.scope.rawValue)")
        }
        guard let ties = EngineTiePolicy(rawValue: end.ties) else {
            throw .unsupported("tie policy \(end.ties)")
        }
        return EngineRankSpec(
            scope: declared.scope, name: name, descending: direction == "descending",
            ties: ties)
    }

    /// Split "match.score" (or a bracketed "deal.taken[0]") into scope
    /// word and variable name.
    private static func splitVarPath(_ path: String) throws(SimulationError) -> (String, String) {
        let trimmed = path.split(separator: "[", omittingEmptySubsequences: true).first.map(String.init) ?? path
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            throw .config("rank path must be scope.name, got \(path)")
        }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: - Effects (§5.3–5.4)

    /// Map a schema effect list to the engine vocabulary. The rule tags
    /// stay on the document side; the engine keeps only what it can act on.
    static func mapEffects(_ effects: [Effect]?) throws(SimulationError) -> [EngineEffect] {
        guard let effects else { return [] }
        var mapped: [EngineEffect] = []
        for effect in effects {
            mapped.append(try mapEffect(effect))
        }
        return mapped
    }

    private static func mapEffect(_ effect: Effect) throws(SimulationError) -> EngineEffect {
        switch effect {
        case .set(let path, let to, _):
            let (name, index) = try splitSetPath(path)
            return .set(name: name, index: index, value: to.source)
        case .add(let path, let value, let event, _):
            let (name, index) = try splitSetPath(path)
            return .add(name: name, index: index, value: value.source, event: event)
        case .letBinding(let name, let be, _):
            return .letBinding(name: name, be: be.source)
        case .ifElse(let condition, let thenBranch, let elseBranch, _):
            var mappedElse: [EngineEffect] = []
            if let elseBranch {
                mappedElse = try mapEffects(elseBranch)
            }
            return .ifElse(
                condition: condition.source,
                thenBranch: try mapEffects(thenBranch),
                elseBranch: mappedElse)
        case .forEach(let kind, let body, _):
            let owner: EngineOwnerKind
            switch kind {
            case "seats": owner = .seat
            case "teams": owner = .team
            default: throw .unsupported("forEach over \(kind)")
            }
            return .forEach(owner: owner, body: try mapEffects(body))
        case .move(let spec, _):
            return try mapMove(spec)
        case .reveal(let zone, let seatExpr, let to, _):
            return .reveal(
                zone: zone, seat: seatExpr?.source, to: try revealTarget(to))
        case .emit(let name, let data, _):
            if data != nil {
                throw .unsupported("emit with data payload")
            }
            return .emit(name: name)
        }
    }

    /// Split a var path "deal.taken[s]" into ("deal.taken", "s");
    /// "match.score" becomes ("match.score", nil).
    private static func splitSetPath(
        _ path: String
    ) throws(SimulationError) -> (name: String, index: String?) {
        guard path.hasSuffix("]") else { return (path, nil) }
        guard let open = path.lastIndex(of: "[") else {
            throw .config("malformed var path \(path)")
        }
        let name = String(path[path.startIndex..<open])
        let index = String(path[path.index(after: open)..<path.index(before: path.endIndex)])
        return (name, index)
    }

    private static func mapMove(_ spec: MoveSpec) throws(SimulationError) -> EngineEffect {
        guard let from = spec.from.stringValue, let to = spec.to.stringValue else {
            throw .config("move zones must be plain strings")
        }
        if spec.toSeat != nil && spec.toTeam != nil {
            throw .config("move declares both toSeat and toTeam")
        }
        let owner: EngineEffect.OwnerTarget?
        if let seatExpr = spec.toSeat {
            owner = .seat(seatExpr.source)
        } else if let teamExpr = spec.toTeam {
            owner = .team(teamExpr.source)
        } else {
            owner = nil
        }
        return .move(from: from, to: to, owner: owner, cards: try mapCardCount(spec.cards))
    }

    private static func mapCardCount(_ count: CardCount) throws(SimulationError) -> EngineEffect.MoveCards {
        switch count {
        case .all: return .all
        case .top(let n): return .top(n)
        case .expr(let e): return .expr(e.source)
        }
    }

    /// Map the `reveal.to` field: absent or "all" reveals to everyone;
    /// a string is a seat-list expression; an array of seat expressions
    /// joins into one list expression. Seat-scoped reveals name a single
    /// owner seat via `seat`.
    private static func revealTarget(_ to: JSON?) throws(SimulationError) -> EngineEffect.RevealTarget {
        guard let to else { return .all }
        if let s = to.stringValue {
            if s == "all" { return .all }
            return .seats(s)
        }
        if let items = to.arrayValue {
            let sources = try items.map { (item: JSON) throws(SimulationError) in
                guard let source = item.stringValue else {
                    throw .config("reveal.to entries must be seat expressions")
                }
                return source
            }
            return .seats("[\(sources.joined(separator: ", "))]")
        }
        throw .config("reveal.to must be \"all\" or seat expression(s)")
    }

    // MARK: - First dealer (§5.6)

    /// Build the setup step that picks the first dealer and returns the
    /// rotation policy. Picks draw from the run's seeded RNG; the
    /// procedure only consults the deck's face list, so nothing it does
    /// touches the zones the deal mechanic will restack.
    static func firstDealerSetup(
        _ setup: SetupSpec?, seatCount: Int, deckFaces: [CardFace],
        orders: [String: [String]]
    ) throws(SimulationError) -> (@Sendable (inout GameState) throws -> Void, EngineDealerRotation) {
        guard let setup else {
            // No setup block (P2-era fixtures): seat 0 deals, rotating left.
            return ({ _ in }, .left)
        }
        let rotation = try dealerRotation(setup.dealerRotation)
        let pick = try makePick(
            setup.firstDealer, seatCount: seatCount, deckFaces: deckFaces, orders: orders)
        return ({ state in try pick(&state) }, rotation)
    }

    /// Resolve the rotation policy string to the engine's policy.
    private static func dealerRotation(
        _ raw: String
    ) throws(SimulationError) -> EngineDealerRotation {
        switch raw {
        case "left": return .left
        case "right": return .right
        case "alternate": return .alternate
        case "fixed": return .fixed
        default:
            throw .unsupported("dealerRotation \(raw)")
        }
    }

    /// Build the first-dealer pick closure for the setup vocabulary.
    private static func makePick(
        _ pick: String, seatCount: Int, deckFaces: [CardFace], orders: [String: [String]]
    ) throws(SimulationError) -> @Sendable (inout GameState) throws(RuleViolation) -> Void {
        switch pick {
        case "randomCut":
            return { state in
                state.dealer = Seat(state.rng.below(seatCount))
            }
        case "highCut", "lowCut":
            guard let natural = orders["natural"] else {
                throw .config("firstDealer \(pick) needs a natural order")
            }
            let lowWins = pick == "lowCut"
            return { state in
                try cutForPosition(&state, seatCount: seatCount, faces: deckFaces, order: natural, lowWins: lowWins)
            }
        case "firstJack":
            return { state in
                try dealForFirstJack(&state, seatCount: seatCount, faces: deckFaces)
            }
        default:
            throw .unsupported("firstDealer \(pick)")
        }
    }

    /// One card per seat; the seat whose card sits at the extreme of the
    /// natural order wins, ties among the extreme redraw. Comparison runs
    /// in the ruleset's own rank order (bridge counts ace high, cribbage
    /// ace low), so the per-game difference lives in the ruleset's
    /// `orders` map rather than in the engine.
    private static func cutForPosition(
        _ state: inout GameState, seatCount: Int, faces: [CardFace], order: [String],
        lowWins: Bool
    ) throws(RuleViolation) {
        let positions = positionMap(order: order)
        var contenders = Array(0..<seatCount)
        while contenders.count > 1 {
            var best: (seat: Int, position: Int)? = nil
            var next: [Int] = []
            for seat in contenders {
                let face = try drawFace(&state.rng, faces)
                let position = positions[face.rank.code] ?? 0
                if let current = best {
                    if better(position, current.position, lowWins) {
                        next = [seat]
                        best = (seat, position)
                    } else if position == current.position {
                        next.append(seat)
                    }
                } else {
                    best = (seat, position)
                    next = [seat]
                }
            }
            contenders = next
        }
        state.dealer = Seat(contenders[0])
    }

    /// Deal cards one at a time around the table until a jack is dealt;
    /// that seat becomes dealer (euchre).
    private static func dealForFirstJack(
        _ state: inout GameState, seatCount: Int, faces: [CardFace]
    ) throws(RuleViolation) {
        var seat = 0
        while true {
            let face = try drawFace(&state.rng, faces)
            if face.rank.code == "J" {
                state.dealer = Seat(seat % seatCount)
                return
            }
            seat += 1
        }
    }

    /// Draw one face uniformly at random without replacement.
    private static func drawFace(
        _ rng: inout SeededRNG, _ faces: [CardFace]
    ) throws(RuleViolation) -> CardFace {
        guard !faces.isEmpty else {
            throw RuleViolation.engineFault(
                ruleId: nil, pointer: "first-dealer draw ran out of cards")
        }
        let index = rng.below(faces.count)
        return faces[index]
    }

    private static func positionMap(
        order: [String]
    ) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, rank) in order.enumerated() { map[rank] = index }
        return map
    }

    private static func better(_ a: Int, _ b: Int, _ lowWins: Bool) -> Bool {
        lowWins ? a < b : a > b
    }
}
