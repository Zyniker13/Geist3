// EngineBuilder phase mapping: the document's phase list becomes engine
// phase configs, and the P3.1 mechanic params (reveal.starter,
// exchange.pass) are translated to their engine forms. Split out of
// EngineBuilder.swift to keep the builder body under the lint limit.

import CardExpr
import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine

/// Bundled inputs for `phaseConfigs`: the mapping reads these values
/// read-only, so one struct keeps the function under the pure-config
/// parameter-count limit.
struct PhaseInputs {
    let runtime: ExpressionRuntime
    let seatCount: Int
    let seatZoneIds: Set<String>
    let sharedZoneIds: Set<String>
    let deckFaces: [CardFace]?
    let dealOverride: [CardFace]?
    let orders: [String: [String]]
    let vars: [String: EngineVarDecl]
}

@_spi(HostOnly)
extension EngineBuilder {
    /// Maps the document's phase list to engine phase configs, returning the
    /// configs and the id of the single deal phase.
    static func phaseConfigs(
        _ phases: [Phase], _ inputs: PhaseInputs
    ) throws -> (configs: [PhaseConfig], dealPhaseID: String?) {
        let runtime = inputs.runtime
        let seatCount = inputs.seatCount
        let seatZoneIds = inputs.seatZoneIds
        let sharedZoneIds = inputs.sharedZoneIds
        let deckFaces = inputs.deckFaces
        let dealOverride = inputs.dealOverride
        let orders = inputs.orders
        let vars = inputs.vars
        var enginePhases: [PhaseConfig] = []
        var dealPhaseID: String? = nil
        for phase in phases {
            // Phase-level flow control (`before`/`next`) is not simulated
            // yet; a phase-level `after` is a post-effect list and runs
            // when the phase completes (§8.1).
            guard phase.before == nil, phase.next == nil else {
                throw SimulationError.unsupported("phase-level flow control on '\(phase.id)'")
            }
            let post: (@Sendable (inout GameState, EvalContext) throws -> [GameEvent])? =
                (phase.after?.isEmpty ?? true) ? nil : try postEffects(phase.after ?? [], phaseId: phase.id)
            let gate = try whenGate(phase.when, phaseId: phase.id, runtime: runtime)
            let config: PhaseConfig
            switch (phase.mechanic, phase.params) {
            case ("deal", .deal(let params)):
                // The deal source defaults to the deck zone, which every
                // shipped ruleset names `deck`.
                guard let sourceId = params.source ?? "deck" as String? else {
                    throw SimulationError.config("deal phase '\(phase.id)' has no source")
                }
                let thenPost = try params.thenEffects.map {
                    try postEffects($0, phaseId: phase.id)
                }
                if dealPhaseID != nil {
                    throw SimulationError.unsupported("more than one deal phase")
                }
                dealPhaseID = phase.id
                let packets = try dealPackets(
                    params.packets, phaseId: phase.id, seatCount: seatCount,
                    seatZones: seatZoneIds, sharedZones: sharedZoneIds)
                config = mechanicConfig(
                    phase.id, gate, DealMechanic.self,
                    RulesEngine.DealParams(
                        source: sourceId, packets: packets,
                        // P3.4 conformance hook: an override stacks the source
                        // zone with the exact given faces in dealing order
                        // (reversed here because the deal pops from the zone
                        // end) and suppresses the shuffle; production keeps
                        // the seeded shuffle (§5.6).
                        shuffleFirst: dealOverride == nil,
                        deckFaces: dealOverride.map({ Array($0.reversed()) }) ?? deckFaces),
                    post: thenPost ?? post)
            case ("trick-play", .trickPlay(let params)):
                config = mechanicConfig(
                    phase.id, gate, TrickPlayMechanic.self,
                    try trickPlayParams(params, phaseId: phase.id, seatCount: seatCount),
                    post: post)
            case ("auction.ladder", .auctionLadder(let params)):
                config = mechanicConfig(
                    phase.id, gate, AuctionLadderMechanic.self,
                    try auctionLadderParams(params, phaseId: phase.id, orders: orders, vars: vars),
                    post: post)
            case ("auction.rounds", .auctionRounds(let params)):
                config = mechanicConfig(
                    phase.id, gate, AuctionRoundsMechanic.self,
                    try auctionRoundsParams(params, phaseId: phase.id, deckFaces: deckFaces),
                    post: post)
            case ("reveal.starter", .revealStarter(let params)):
                config = mechanicConfig(
                    phase.id, gate, RevealStarterMechanic.self,
                    try revealStarterParams(params, phaseId: phase.id, sharedZones: sharedZoneIds),
                    post: post)
            case ("exchange.pass", .exchangePass(let params)):
                config = mechanicConfig(
                    phase.id, gate, ExchangePassMechanic.self,
                    try exchangePassParams(
                        params, phaseId: phase.id, seatCount: seatCount, seatZones: seatZoneIds),
                    post: post)
            case ("exchange.kitty", .exchangeKitty(let params)):
                config = mechanicConfig(
                    phase.id, gate, ExchangeKittyMechanic.self,
                    try exchangeKittyParams(params, phaseId: phase.id),
                    post: post)
            case ("exchange.discardTo", .exchangeDiscardTo(let params)):
                config = mechanicConfig(
                    phase.id, gate, ExchangeDiscardToMechanic.self,
                    try exchangeDiscardToParams(
                        params, phaseId: phase.id, seatZones: seatZoneIds, sharedZones: sharedZoneIds),
                    post: post)
            case ("count-play", .countPlay(let params)):
                config = mechanicConfig(
                    phase.id, gate, CountPlayMechanic.self,
                    try countPlayParams(params, phaseId: phase.id, seatZones: seatZoneIds),
                    post: post)
            case ("show", .show(let params)):
                config = mechanicConfig(
                    phase.id, gate, ShowMechanic.self,
                    try showParams(params, phaseId: phase.id, sharedZones: sharedZoneIds),
                    post: post)
            case ("score", .score(let params)):
                config = mechanicConfig(
                    phase.id, gate, ScoreMechanic.self,
                    try scoreParams(params, phaseId: phase.id),
                    post: post)
            case (let mechanic, _):
                throw SimulationError.unsupported("mechanic '\(mechanic)'")
            }
            enginePhases.append(config)
        }
        return (enginePhases, dealPhaseID)
    }

    /// Compiles a phase-level post-effect list (§8.1 `after` / deal
    /// `then`) into the closure `PhaseConfig.post` runs at phase end.
    /// Effects run through the `EffectsRunner` the engine puts on every
    /// `EvalContext` (engine-managed expression evaluation, §7.5).
    static func postEffects(
        _ effects: [Effect], phaseId: String
    ) throws(SimulationError) -> (@Sendable (inout GameState, EvalContext) throws -> [GameEvent]) {
        let mapped = try mapEffects(effects)
        guard !mapped.isEmpty else {
            throw SimulationError.config("phase '\(phaseId)' has an empty post-effect list")
        }
        return { state, ctx in
            guard let runner = ctx.effects else {
                throw RuleViolation.engineFault(
                    ruleId: nil, pointer: "/phases/\(phaseId)/after: no effect runner")
            }
            var events: [GameEvent] = []
            try runner.run(
                mapped, in: &state, events: &events, pointer: "/phases/\(phaseId)/after")
            return events
        }
    }

    private static func mechanicConfig<M: Mechanic>(
        _ phaseId: String, _ gate: (@Sendable (GameState) throws -> Bool)?,
        _ mechanic: M.Type, _ params: M.Params,
        post: (@Sendable (inout GameState, EvalContext) throws -> [GameEvent])? = nil
    ) -> PhaseConfig {
        PhaseConfig(
            id: phaseId, mechanic: AnyMechanic(mechanic, params: params), gate: gate,
            post: post)
    }

    // MARK: - when gates

    /// Compiles a phase `when` gate (§5.6): a closure evaluated on each
    /// entry attempt that reports whether the phase may run. Gate
    /// failures surface as engine faults, never as a silent skip.
    static func whenGate(
        _ when: Expr?, phaseId: String, runtime: ExpressionRuntime
    ) throws -> (@Sendable (GameState) throws -> Bool)? {
        guard let when else { return nil }
        let source = when.source
        let pointer = "/phases/\(phaseId)/when"
        return { state in
            let value: EvalValue
            do {
                value = try runtime.evaluate(EvalCall(pointer: pointer, source: source), state)
            } catch let failure as EvalFailure {
                throw RuleViolation.engineFault(
                    ruleId: nil, pointer: "\(faultPointer(failure)): \(faultDetail(failure))")
            }
            guard case .bool(let open) = value else {
                throw RuleViolation.engineFault(
                    ruleId: nil,
                    pointer: "\(pointer): when gate produced \(value), not a boolean")
            }
            return open
        }
    }

    static func faultPointer(_ failure: EvalFailure) -> String {
        switch failure {
        case .budget(let pointer): return pointer
        case .fault(let pointer, _): return pointer
        }
    }

    static func faultDetail(_ failure: EvalFailure) -> String {
        switch failure {
        case .budget: return "expression exceeded the fuel budget"
        case .fault(_, let detail): return detail
        }
    }

    // MARK: - reveal.starter

    static func revealStarterParams(
        _ params: RevealStarterParams, phaseId: String, sharedZones: Set<String>
    ) throws -> RulesEngine.RevealStarterParams {
        let from = try zoneName(
            params.from, param: "\(phaseId).from", declared: sharedZones, kind: "shared")
        let to = try zoneName(
            params.to, param: "\(phaseId).to", declared: sharedZones, kind: "shared")
        let after = try mapEffects(params.afterEffects)
        return RulesEngine.RevealStarterParams(
            cutBy: params.cutBy.map {
                ExprRef(pointer: "/phases/\(phaseId)/cutBy", source: $0.source)
            },
            from: from, to: to, minCutDepth: params.minCutDepth, afterEffects: after)
    }

    // MARK: - exchange.pass

    static func exchangePassParams(
        _ params: ExchangePassParams, phaseId: String, seatCount: Int, seatZones: Set<String>
    ) throws -> RulesEngine.ExchangePassParams {
        let from = try zoneName(
            params.from, param: "\(phaseId).from", declared: seatZones, kind: "seat")
        let to = try zoneName(
            params.to, param: "\(phaseId).to", declared: seatZones, kind: "seat")
        let via = try params.via.map {
            try zoneName($0, param: "\(phaseId).via", declared: seatZones, kind: "seat")
        }
        guard let target = params.target else {
            throw SimulationError.config("exchange.pass phase '\(phaseId)' has no target")
        }
        let countPointer = "/phases/\(phaseId)/count"
        let count: ExprRef
        switch params.count {
        case .int(let n):
            count = ExprRef(pointer: countPointer, source: "\(n)")
        case .expr(let expr):
            count = ExprRef(pointer: countPointer, source: expr.source)
        case nil:
            throw SimulationError.config("exchange.pass phase '\(phaseId)' has no count")
        }
        let revealTo: String
        switch params.revealTo?.stringValue {
        case "nobody", nil:
            revealTo = "nobody"
        case "recipient":
            revealTo = "recipient"
        case "all":
            revealTo = "all"
        case let other?:
            throw SimulationError.config(
                "revealTo '\(other)' is not nobody, recipient or all")
        }
        return RulesEngine.ExchangePassParams(
            from: from, via: via, to: to, count: count,
            target: ExprRef(pointer: "/phases/\(phaseId)/target", source: target.source),
            simultaneous: params.simultaneous ?? false, revealTo: revealTo)
    }

    /// Resolves a zone reference to a declared zone id. Rulesets name
    /// zones with bare identifiers (`from: "stock"`); a string literal
    /// is also accepted.
    static func zoneName(
        _ expr: Expr?, param: String, declared: Set<String>, kind: String
    ) throws -> String {
        guard let expr else { throw SimulationError.config("\(param) is missing") }
        return try zoneName(expr.source, param: param, declared: declared, kind: kind)
    }

    static func zoneName(
        _ source: String?, param: String, declared: Set<String>, kind: String
    ) throws -> String {
        guard let source else { throw SimulationError.config("\(param) is missing") }
        let name = source.trimmingCharacters(in: .whitespaces)
        if declared.contains(name) { return name }
        if let ast = try? parseConstant(name, param: param),
            case .string(let string, _) = ast, declared.contains(string)
        {
            return string
        }
        throw SimulationError.config("\(param) '\(source)' is not a declared \(kind) zone")
    }

    /// Zone parameter that accepts a JSON int as well (NumOrExpr).
    static func zoneName(
        _ value: NumOrExpr?, param: String, declared: Set<String>, kind: String
    ) throws -> String {
        let source: String?
        switch value {
        case .int(let n): source = "\(n)"
        case .expr(let expr): source = expr.source
        case nil: source = nil
        }
        return try zoneName(source, param: param, declared: declared, kind: kind)
    }

    // MARK: - exchange.kitty / exchange.discardTo

    static func exchangeKittyParams(
        _ params: ExchangeKittyParams, phaseId: String
    ) throws -> RulesEngine.ExchangeKittyParams {
        func ref(_ expr: Expr?, _ key: String) throws -> ExprRef? {
            guard let expr else { return nil }
            return ExprRef(pointer: "/phases/\(phaseId)/\(key)", source: expr.source)
        }
        func numRef(_ value: NumOrExpr?, _ key: String) throws -> ExprRef? {
            let source: String?
            switch value {
            case .int(let n): source = "\(n)"
            case .expr(let expr): source = expr.source
            case nil: source = nil
            }
            guard let source else { return nil }
            return ExprRef(pointer: "/phases/\(phaseId)/\(key)", source: source)
        }
        return RulesEngine.ExchangeKittyParams(
            seat: try ref(params.seat, "seat"),
            take: try numRef(params.take, "take"),
            discard: try numRef(params.discard, "discard"),
            discardTo: try ref(params.discardTo, "discardTo"),
            skipIf: try ref(params.skipIf, "skipIf"))
    }

    static func exchangeDiscardToParams(
        _ params: ExchangeDiscardToParams, phaseId: String, seatZones: Set<String>,
        sharedZones: Set<String>
    ) throws -> RulesEngine.ExchangeDiscardToParams {
        let from = try zoneName(params.from, param: "\(phaseId).from", declared: seatZones, kind: "seat")
        let to = try zoneName(
            params.to, param: "\(phaseId).to", declared: sharedZones.union(seatZones), kind: "zone")
        guard let count = params.count else {
            throw SimulationError.config("exchange.discardTo phase '\(phaseId)' has no count")
        }
        let countSource: String
        switch count {
        case .int(let n): countSource = "\(n)"
        case .expr(let expr): countSource = expr.source
        }
        let revealTo: String
        switch params.revealTo?.stringValue {
        case "nobody", nil: revealTo = "nobody"
        case "all": revealTo = "all"
        case let other?: throw SimulationError.config("revealTo '\(other)' is not nobody or all")
        }
        return RulesEngine.ExchangeDiscardToParams(
            from: from, to: to, toScope: sharedZones.contains(to) ? "shared" : "seat",
            count: ExprRef(pointer: "/phases/\(phaseId)/count", source: countSource),
            revealTo: revealTo, simultaneous: params.simultaneous ?? false)
    }

    // MARK: - count-play

    static func countPlayParams(
        _ params: CountPlayParams, phaseId: String, seatZones: Set<String>
    ) throws -> RulesEngine.CountPlayParams {
        guard let firstPlayer = params.firstPlayer else {
            throw SimulationError.config("count-play phase '\(phaseId)' has no firstPlayer")
        }
        guard let valueOf = params.valueOf else {
            throw SimulationError.config("count-play phase '\(phaseId)' has no valueOf")
        }
        guard let limit = try intParam(params.limit, param: "\(phaseId).limit") else {
            throw SimulationError.config("count-play phase '\(phaseId)' has no limit")
        }
        let award = try params.award.map { try splitLValue($0, param: "\(phaseId).award") }
        return RulesEngine.CountPlayParams(
            from: try zoneName(params.from, param: "\(phaseId).from", declared: seatZones, kind: "seat"),
            to: try zoneName(params.to, param: "\(phaseId).to", declared: seatZones, kind: "seat"),
            firstPlayer: ExprRef(
                pointer: "/phases/\(phaseId)/firstPlayer", source: firstPlayer.source),
            valueOf: ExprRef(pointer: "/phases/\(phaseId)/valueOf", source: valueOf.source),
            limit: limit,
            goLastCardPoints: try intParam(
                params.go?.lastCardPoints, param: "\(phaseId).go.lastCardPoints") ?? 0,
            goExactLimitPoints: try intParam(
                params.go?.exactLimitPoints, param: "\(phaseId).go.exactLimitPoints") ?? 0,
            pointsOnPlay: params.pointsOnPlay.map {
                ExprRef(pointer: "/phases/\(phaseId)/pointsOnPlay", source: $0.source)
            },
            pointsRule: params.pointsRule,
            awardName: award?.name, awardIndex: award?.index,
            returnCards: params.returnCards ?? false)
    }

    /// Constant integer parameter: a JSON int or a literal expression.
    static func intParam(_ value: NumOrExpr?, param: String) throws -> Int? {
        switch value {
        case .int(let n): return n
        case .expr(let expr):
            guard case .int(let raw, _) = try? parseConstant(expr.source, param: param) else {
                throw SimulationError.config("\(param) must be a constant")
            }
            return Int(raw)
        case nil: return nil
        }
    }

    /// Splits an award lvalue like `match.score[seat]` into variable name
    /// and index-expression source.
    static func splitLValue(_ source: String, param: String) throws -> (name: String, index: String) {
        guard let open = source.firstIndex(of: "["), source.hasSuffix("]") else {
            throw SimulationError.config("\(param) '\(source)' is not an lvalue")
        }
        let name = source[..<open].trimmingCharacters(in: .whitespaces)
        let index = source[source.index(after: open)..<source.index(before: source.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, source[open...].filter({ $0 == "[" }).count == 1 else {
            throw SimulationError.config("\(param) '\(source)' is not a simple lvalue")
        }
        return (name, index)
    }

    // MARK: - show

    static func showParams(
        _ params: ShowParams, phaseId: String, sharedZones: Set<String>
    ) throws -> RulesEngine.ShowParams {
        let order = params.order.map { entry in
            RulesEngine.ShowEntryParams(
                zone: entry.zone,
                seat: entry.seat.map {
                    ExprRef(pointer: "/phases/\(phaseId)/order/seat", source: $0.source)
                },
                award: entry.award.map {
                    ExprRef(pointer: "/phases/\(phaseId)/order/award", source: $0.source)
                },
                isCrib: entry.isCrib)
        }
        let award = try splitLValue(
            params.award?.source ?? "match.score[awardee]", param: "\(phaseId).award")
        return RulesEngine.ShowParams(
            order: order,
            with: try params.with.map {
                try zoneName($0, param: "\(phaseId).with", declared: sharedZones, kind: "shared")
            },
            points: params.points.map {
                ExprRef(pointer: "/phases/\(phaseId)/points", source: $0.source)
            },
            pointsRule: params.pointsRule,
            manual: params.manual.map {
                ExprRef(pointer: "/phases/\(phaseId)/manual", source: $0.source)
            },
            muggins: params.muggins.map {
                ExprRef(pointer: "/phases/\(phaseId)/muggins", source: $0.source)
            },
            awardName: award.name, awardIndex: award.index)
    }

    // MARK: - score

    static func scoreParams(_ params: ScoreParams, phaseId: String) throws -> RulesEngine.ScoreParams {
        let effects = try mapEffects(params.effects)
        let choices = try params.choices.map { list in
            try list.map { choice in
                RulesEngine.ScoreChoiceRef(
                    id: choice.id,
                    seat: ExprRef(
                        pointer: "/phases/\(phaseId)/choices/\(choice.id)/seat",
                        source: choice.seat.source),
                    when: ExprRef(
                        pointer: "/phases/\(phaseId)/choices/\(choice.id)/when",
                        source: choice.when.source),
                    values: choice.values)
            }
        }
        return RulesEngine.ScoreParams(effects: effects, choices: choices)
    }
}
