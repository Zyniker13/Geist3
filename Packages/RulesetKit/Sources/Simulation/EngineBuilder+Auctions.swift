// EngineBuilder auction mapping: `auction.ladder` and `auction.rounds`
// phase params become their engine forms. Split out of EngineBuilder+Phases
// to keep each file focused and the types under the lint limit.

import CardExpr
import CardModel
@_spi(HostOnly) import RulesEngine

@_spi(HostOnly)
extension EngineBuilder {
    // MARK: - auction.ladder

    static func auctionLadderParams(
        _ params: AuctionLadderParams, phaseId: String, orders: [String: [String]],
        vars: [String: EngineVarDecl]
    ) throws -> RulesEngine.AuctionLadderParams {
        guard let ladder = params.ladder else {
            throw SimulationError.config("auction.ladder '\(phaseId)' has no ladder")
        }
        guard ladder.levels.count == 2, ladder.levels[0] <= ladder.levels[1] else {
            throw SimulationError.config(
                "ladder levels must be [min, max] in '\(phaseId)'")
        }
        var strainOrder: [String] = []
        if let strains = ladder.strains {
            guard let order = orders[strains] else {
                throw SimulationError.config(
                    "ladder strains names unknown order '\(strains)' in '\(phaseId)'")
            }
            strainOrder = order
        }
        var extraCalls: [String] = []
        for call in params.calls ?? [] {
            guard ["pass", "double", "redouble"].contains(call) else {
                throw SimulationError.unsupported("ladder call '\(call)' in '\(phaseId)'")
            }
            extraCalls.append(call)
        }
        let contractPath = try resultPath(
            params.result?.contract, name: "contract", phaseId: phaseId, vars: vars)
        var declarerPath: String? = nil
        if let declarer = params.result?.declarer {
            guard declarer.rule == "firstOfWinningSideToNameStrain" else {
                throw SimulationError.unsupported(
                    "declarer rule '\(declarer.rule)' in '\(phaseId)'")
            }
            declarerPath = try resultPath(declarer.set, name: "declarer", phaseId: phaseId, vars: vars)
        }
        return RulesEngine.AuctionLadderParams(
            firstBidder: exprRef(params.firstBidder, phaseId: phaseId, key: "firstBidder"),
            firstBidderRuleId: nil,
            minLevel: ladder.levels[0], maxLevel: ladder.levels[1],
            strainOrder: strainOrder, ladderRuleId: ladder.rule,
            extraCalls: extraCalls, doubleRuleId: params.doubleRule,
            consecutivePasses: params.end?.consecutivePassesAfterBid,
            endRuleId: params.end?.rule,
            allPass: params.allPass.map {
                ExprRef(pointer: "/phases/\(phaseId)/allPass", source: $0.action.source)
            },
            allPassRuleId: params.allPass?.rule,
            contractPath: contractPath, declarerPath: declarerPath,
            declarerRuleId: params.result?.declarer?.ruleId)
    }

    /// An optional schema expression as an engine `ExprRef`, pointer spelled
    /// for faults (§7.4).
    static func exprRef(
        _ expr: Expr?, phaseId: String, key: String
    ) -> ExprRef? {
        expr.map { ExprRef(pointer: "/phases/\(phaseId)/\(key)", source: $0.source) }
    }

    /// `result.contract` / `result.declarer.set` name the destination
    /// variable: a scope-qualified declared var path.
    static func resultPath(
        _ expr: Expr?, name: String, phaseId: String, vars: [String: EngineVarDecl]
    ) throws -> String? {
        guard let expr else { return nil }
        let parts = expr.source.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            throw SimulationError.config(
                "result.\(name) must be a scope-qualified var path in '\(phaseId)'")
        }
        let bare = String(parts[1])
        guard let decl = vars[bare] else {
            throw SimulationError.config(
                "result.\(name) names undeclared var '\(expr.source)' in '\(phaseId)'")
        }
        let family = String(parts[0])
        let expected: String
        switch decl.scope {
        case .match, .seatMatch, .teamMatch: expected = "match"
        case .deal, .seatDeal, .teamDeal: expected = "deal"
        }
        guard family == expected else {
            throw SimulationError.config(
                "result.\(name) path '\(expr.source)' disagrees with var scope in '\(phaseId)'")
        }
        return expr.source
    }

    // MARK: - auction.rounds

    static func auctionRoundsParams(
        _ params: AuctionRoundsParams, phaseId: String, deckFaces: [CardFace]?
    ) throws -> RulesEngine.AuctionRoundsParams {
        var rounds: [RulesEngine.AuctionRoundsParams.Round] = []
        for round in params.rounds {
            var calls: [RulesEngine.AuctionRoundsParams.Call] = []
            for call in round.calls {
                let values = call.param != nil ? suitCandidates(deckFaces, phaseId: phaseId) : []
                if call.param != nil, values.isEmpty {
                    throw SimulationError.config(
                        "call '\(call.id)' in '\(phaseId)' has a param but the deck has no suits")
                }
                calls.append(
                    .init(
                        id: call.id,
                        allowed: exprRef(call.allowed, phaseId: "\(phaseId)/\(round.id)/\(call.id)", key: "allowed"),
                        ruleId: round.rule,
                        param: call.param, paramValues: values,
                        sets: try setAssignments(call.sets, phaseId: phaseId),
                        alone: exprRef(call.alone, phaseId: "\(phaseId)/\(round.id)/\(call.id)", key: "alone")))
            }
            rounds.append(
                .init(
                    id: round.id, ruleId: round.rule,
                    before: try EngineBuilder.mapEffects(round.beforeEffects), calls: calls))
        }
        return RulesEngine.AuctionRoundsParams(
            firstBidder: exprRef(params.firstBidder, phaseId: phaseId, key: "firstBidder"),
            rounds: rounds,
            onCall: try EngineBuilder.mapEffects(params.onCallEffects),
            endWhen: exprRef(params.endWhen, phaseId: phaseId, key: "endWhen"),
            endWhenRuleId: nil,
            allPass: params.allPass.map {
                ExprRef(pointer: "/phases/\(phaseId)/allPass", source: $0.action.source)
            },
            allPassRuleId: params.allPass?.rule)
    }

    /// Call `sets` are `{set, to}` assignments; P1 supports plain
    /// scope-qualified paths (no index brackets).
    static func setAssignments(
        _ assigns: [SetAssign]?, phaseId: String
    ) throws -> [EngineEffect] {
        guard let assigns else { return [] }
        return try assigns.map { assign in
            let path = assign.set.source
            guard !path.contains("[") else {
                throw SimulationError.unsupported(
                    "indexed call set '\(path)' in '\(phaseId)'")
            }
            return .set(name: path, index: nil, value: assign.to.source)
        }
    }

    /// Suit codes for call params: the deck's suits in first-seen order.
    static func suitCandidates(_ deckFaces: [CardFace]?, phaseId: String) -> [String] {
        guard let deckFaces else { return [] }
        var seen: [String] = []
        for face in deckFaces {
            if let suit = face.suit?.code, !seen.contains(suit) {
                seen.append(suit)
            }
        }
        return seen
    }
}
