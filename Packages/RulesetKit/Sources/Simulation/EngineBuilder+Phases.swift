// EngineBuilder phase mapping: the document's phase list becomes engine
// phase configs, and the P3.1 mechanic params (reveal.starter,
// exchange.pass) are translated to their engine forms. Split out of
// EngineBuilder.swift to keep the builder body under the lint limit.

import CardExpr
import CardModel
@_spi(HostOnly) import RulesEngine

@_spi(HostOnly)
extension EngineBuilder {
    /// Maps the document's phase list to engine phase configs, returning the
    /// configs and the id of the single deal phase.
    static func phaseConfigs(
        _ phases: [Phase], runtime: ExpressionRuntime, seatCount: Int,
        seatZoneIds: Set<String>, sharedZoneIds: Set<String>, deckFaces: [CardFace]?
    ) throws -> (configs: [PhaseConfig], dealPhaseID: String?) {
        var enginePhases: [PhaseConfig] = []
        var dealPhaseID: String? = nil
        for phase in phases {
            guard phase.before == nil, phase.after == nil, phase.next == nil else {
                throw SimulationError.unsupported("phase-level flow control on '\(phase.id)'")
            }
            let gate = try whenGate(phase.when, phaseId: phase.id, runtime: runtime)
            let config: PhaseConfig
            switch (phase.mechanic, phase.params) {
            case ("deal", .deal(let params)):
                guard let sourceId = params.source else {
                    throw SimulationError.config("deal phase '\(phase.id)' has no source")
                }
                guard params.thenEffects == nil else {
                    throw SimulationError.unsupported("deal.then effects")
                }
                if dealPhaseID != nil {
                    throw SimulationError.unsupported("more than one deal phase")
                }
                dealPhaseID = phase.id
                let packets = try dealPackets(
                    params.packets, phaseId: phase.id, seatCount: seatCount,
                    seatZones: seatZoneIds, sharedZones: sharedZoneIds)
                config = PhaseConfig(
                    id: phase.id,
                    mechanic: AnyMechanic(
                        DealMechanic.self,
                        params: RulesEngine.DealParams(
                            source: sourceId, packets: packets, shuffleFirst: true,
                            deckFaces: deckFaces)),
                    gate: gate)
            case ("trick-play", .trickPlay(let params)):
                let engineParams = try trickPlayParams(params, phaseId: phase.id, seatCount: seatCount)
                config = PhaseConfig(
                    id: phase.id,
                    mechanic: AnyMechanic(
                        TrickPlayMechanic.self, params: engineParams),
                    gate: gate)
            case ("reveal.starter", .revealStarter(let params)):
                let engineParams = try revealStarterParams(
                    params, phaseId: phase.id, sharedZones: sharedZoneIds)
                config = PhaseConfig(
                    id: phase.id,
                    mechanic: AnyMechanic(
                        RevealStarterMechanic.self, params: engineParams),
                    gate: gate)
            case ("exchange.pass", .exchangePass(let params)):
                let engineParams = try exchangePassParams(
                    params, phaseId: phase.id, seatCount: seatCount, seatZones: seatZoneIds)
                config = PhaseConfig(
                    id: phase.id,
                    mechanic: AnyMechanic(
                        ExchangePassMechanic.self, params: engineParams),
                    gate: gate)
            case (let mechanic, _):
                throw SimulationError.unsupported("mechanic '\(mechanic)'")
            }
            enginePhases.append(config)
        }
        return (enginePhases, dealPhaseID)
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
        let source = expr.source.trimmingCharacters(in: .whitespaces)
        if declared.contains(source) { return source }
        if let ast = try? parseConstant(source, param: param),
            case .string(let name, _) = ast, declared.contains(name)
        {
            return name
        }
        throw SimulationError.config("\(param) '\(source)' is not a declared \(kind) zone")
    }
}
