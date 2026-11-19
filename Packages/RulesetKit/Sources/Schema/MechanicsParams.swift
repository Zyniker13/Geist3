// Mechanic parameter structs (§5.6/§5.7) and the PhaseParams dispatch.
// Field sets mirror the reference rulesets exactly; every struct keeps
// with `SchemaError.wrongType` so unknown keys never survive decode, and the
// validator (P2.7) can warn on them.

import Foundation

/// A numeric setting the rulesets write either as a literal (`6`) or as an
/// expression string (`"3"`). Preserved verbatim either way.
public enum NumOrExpr: Equatable, Sendable, JSONCodable {
    case int(Int)
    case expr(Expr)

    public init(json: JSON, path: String) throws(SchemaError) {
        if let i = json.intValue {
            self = .int(i)
        } else if let s = json.stringValue {
            self = .expr(Expr(source: s))
        } else {
            throw SchemaError.wrongType(expected: "int or expression string", path: path)
        }
    }

    public var json: JSON {
        switch self {
        case .int(let i): return .int(i)
        case .expr(let e): return e.json
        }
    }
}

/// How many tricks a trick-play phase plays: a count (bridge: 13), the
/// keyword `untilHandsEmpty`, or an expression.
public enum TricksSpec: Equatable, Sendable, JSONCodable {
    case count(Int)
    case text(String)

    public init(json: JSON, path: String) throws(SchemaError) {
        if let i = json.intValue {
            self = .count(i)
        } else if let s = json.stringValue {
            self = .text(s)
        } else {
            throw SchemaError.wrongType(expected: "int or string", path: path)
        }
    }

    public var json: JSON {
        switch self {
        case .count(let i): return .int(i)
        case .text(let s): return .string(s)
        }
    }
}

// MARK: - deal

public struct DealPacket: Equatable, Sendable, JSONCodable {
    public var to: String
    public var each: NumOrExpr?
    public var count: NumOrExpr?
    public var faceUp: Bool?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        to = try reader.string("to")
        each = try reader.optionalDecoded("each") as NumOrExpr?
        count = try reader.optionalDecoded("count") as NumOrExpr?
        faceUp = try reader.optionalBool("faceUp")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("to", .string(to))]
        if let each { pairs.append(("each", each.json)) }
        if let count { pairs.append(("count", count.json)) }
        if let faceUp { pairs.append(("faceUp", .bool(faceUp))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct DealParams: Equatable, Sendable, JSONCodable {
    public var source: String?
    public var packets: [DealPacket]
    public var thenEffects: [Effect]?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        source = try reader.optionalString("source")
        packets = try reader.array("packets")
        thenEffects = try reader.optionalArray("then") as [Effect]?
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let source { pairs.append(("source", .string(source))) }
        pairs.append(("packets", .array(packets.map { $0.json })))
        if let thenEffects { pairs.append(("then", .array(thenEffects.map { $0.json }))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - exchange.*

public struct ExchangePassParams: Equatable, Sendable, JSONCodable {
    public var from: Expr?
    public var via: Expr?
    public var to: Expr?
    public var count: NumOrExpr?
    public var target: Expr?
    public var simultaneous: Bool?
    public var revealTo: JSON?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        from = try reader.optionalDecoded("from") as Expr?
        via = try reader.optionalDecoded("via") as Expr?
        to = try reader.optionalDecoded("to") as Expr?
        count = try reader.optionalDecoded("count") as NumOrExpr?
        target = try reader.optionalDecoded("target") as Expr?
        simultaneous = try reader.optionalBool("simultaneous")
        revealTo = reader.optionalValue("revealTo")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let from { pairs.append(("from", from.json)) }
        if let via { pairs.append(("via", via.json)) }
        if let to { pairs.append(("to", to.json)) }
        if let count { pairs.append(("count", count.json)) }
        if let target { pairs.append(("target", target.json)) }
        if let simultaneous { pairs.append(("simultaneous", .bool(simultaneous))) }
        if let revealTo { pairs.append(("revealTo", revealTo)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct ExchangeKittyParams: Equatable, Sendable, JSONCodable {
    public var seat: Expr?
    public var take: NumOrExpr?
    public var discard: NumOrExpr?
    public var discardTo: Expr?
    public var skipIf: Expr?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        seat = try reader.optionalDecoded("seat") as Expr?
        take = try reader.optionalDecoded("take") as NumOrExpr?
        discard = try reader.optionalDecoded("discard") as NumOrExpr?
        discardTo = try reader.optionalDecoded("discardTo") as Expr?
        skipIf = try reader.optionalDecoded("skipIf") as Expr?
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let seat { pairs.append(("seat", seat.json)) }
        if let take { pairs.append(("take", take.json)) }
        if let discard { pairs.append(("discard", discard.json)) }
        if let discardTo { pairs.append(("discardTo", discardTo.json)) }
        if let skipIf { pairs.append(("skipIf", skipIf.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct ExchangeDiscardToParams: Equatable, Sendable, JSONCodable {
    public var count: NumOrExpr?
    public var from: Expr?
    public var to: Expr?
    public var simultaneous: Bool?
    public var revealTo: JSON?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        count = try reader.optionalDecoded("count") as NumOrExpr?
        from = try reader.optionalDecoded("from") as Expr?
        to = try reader.optionalDecoded("to") as Expr?
        simultaneous = try reader.optionalBool("simultaneous")
        revealTo = reader.optionalValue("revealTo")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let count { pairs.append(("count", count.json)) }
        if let from { pairs.append(("from", from.json)) }
        if let to { pairs.append(("to", to.json)) }
        if let simultaneous { pairs.append(("simultaneous", .bool(simultaneous))) }
        if let revealTo { pairs.append(("revealTo", revealTo)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - reveal.starter

public struct RevealStarterParams: Equatable, Sendable, JSONCodable {
    public var cutBy: Expr?
    public var from: Expr?
    public var to: Expr?
    public var minCutDepth: Int?
    public var afterEffects: [Effect]?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        cutBy = try reader.optionalDecoded("cutBy") as Expr?
        from = try reader.optionalDecoded("from") as Expr?
        to = try reader.optionalDecoded("to") as Expr?
        minCutDepth = try reader.optionalInt("minCutDepth")
        afterEffects = try reader.optionalArray("after") as [Effect]?
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let cutBy { pairs.append(("cutBy", cutBy.json)) }
        if let from { pairs.append(("from", from.json)) }
        if let to { pairs.append(("to", to.json)) }
        if let minCutDepth { pairs.append(("minCutDepth", .int(minCutDepth))) }
        if let afterEffects { pairs.append(("after", .array(afterEffects.map { $0.json }))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - auction.ladder

public struct LadderSpec: Equatable, Sendable, JSONCodable {
    public var levels: [Int]
    public var strains: String?
    public var rule: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        levels = try reader.array("levels")
        strains = try reader.optionalString("strains")
        rule = try reader.optionalString("rule")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("levels", .array(levels.map { .int($0) }))]
        if let strains { pairs.append(("strains", .string(strains))) }
        if let rule { pairs.append(("rule", .string(rule))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct LadderEnd: Equatable, Sendable, JSONCodable {
    public var consecutivePassesAfterBid: Int?
    public var rule: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        consecutivePassesAfterBid = try reader.optionalInt("consecutivePassesAfterBid")
        rule = try reader.optionalString("rule")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let consecutivePassesAfterBid {
            pairs.append(("consecutivePassesAfterBid", .int(consecutivePassesAfterBid)))
        }
        if let rule { pairs.append(("rule", .string(rule))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct AllPassSpec: Equatable, Sendable, JSONCodable {
    public var action: Expr
    public var rule: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        action = try reader.decoded("action")
        rule = try reader.optionalString("rule")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("action", action.json)]
        if let rule { pairs.append(("rule", .string(rule))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct ResultDeclarer: Equatable, Sendable, JSONCodable {
    public var set: Expr
    public var rule: String
    public var ruleId: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        set = try reader.decoded("set")
        rule = try reader.string("rule")
        ruleId = try reader.optionalString("ruleId")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("set", set.json),
            ("rule", .string(rule)),
        ]
        if let ruleId { pairs.append(("ruleId", .string(ruleId))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct AuctionResult: Equatable, Sendable, JSONCodable {
    public var contract: Expr
    public var declarer: ResultDeclarer?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        contract = try reader.decoded("contract")
        declarer = try reader.optionalDecoded("declarer")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("contract", contract.json)]
        if let declarer { pairs.append(("declarer", declarer.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct AuctionLadderParams: Equatable, Sendable, JSONCodable {
    public var firstBidder: Expr?
    public var ladder: LadderSpec?
    public var calls: [String]?
    public var doubleRule: String?
    public var end: LadderEnd?
    public var allPass: AllPassSpec?
    public var result: AuctionResult?
    public var alerts: Expr?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        firstBidder = try reader.optionalDecoded("firstBidder") as Expr?
        ladder = try reader.optionalDecoded("ladder")
        calls = try reader.optionalArray("calls")
        doubleRule = try reader.optionalString("doubleRule")
        end = try reader.optionalDecoded("end")
        allPass = try reader.optionalDecoded("allPass")
        result = try reader.optionalDecoded("result")
        alerts = try reader.optionalDecoded("alerts") as Expr?
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let firstBidder { pairs.append(("firstBidder", firstBidder.json)) }
        if let ladder { pairs.append(("ladder", ladder.json)) }
        if let calls { pairs.append(("calls", .array(calls.map { .string($0) }))) }
        if let doubleRule { pairs.append(("doubleRule", .string(doubleRule))) }
        if let end { pairs.append(("end", end.json)) }
        if let allPass { pairs.append(("allPass", allPass.json)) }
        if let result { pairs.append(("result", result.json)) }
        if let alerts { pairs.append(("alerts", alerts.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - auction.rounds

public struct SetAssign: Equatable, Sendable, JSONCodable {
    public var set: Expr
    public var to: Expr

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        set = try reader.decoded("set")
        to = try reader.decoded("to")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        let pairs: [(String, JSON)] = [("set", set.json), ("to", to.json)]
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct AuctionRoundCall: Equatable, Sendable, JSONCodable {
    public var id: String
    public var allowed: Expr?
    public var param: String?
    public var sets: [SetAssign]?
    public var alone: Expr?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        id = try reader.string("id")
        allowed = try reader.optionalDecoded("allowed") as Expr?
        param = try reader.optionalString("param")
        sets = try reader.optionalArray("sets")
        alone = try reader.optionalDecoded("alone") as Expr?
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("id", .string(id))]
        if let allowed { pairs.append(("allowed", allowed.json)) }
        if let param { pairs.append(("param", .string(param))) }
        if let sets { pairs.append(("sets", .array(sets.map { $0.json }))) }
        if let alone { pairs.append(("alone", alone.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct AuctionRound: Equatable, Sendable, JSONCodable {
    public var id: String
    public var rule: String?
    public var beforeEffects: [Effect]?
    public var calls: [AuctionRoundCall]

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        id = try reader.string("id")
        rule = try reader.optionalString("rule")
        beforeEffects = try reader.optionalArray("before") as [Effect]?
        calls = try reader.array("calls")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("id", .string(id))]
        if let rule { pairs.append(("rule", .string(rule))) }
        if let beforeEffects { pairs.append(("before", .array(beforeEffects.map { $0.json }))) }
        pairs.append(("calls", .array(calls.map { $0.json })))
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct AuctionRoundsParams: Equatable, Sendable, JSONCodable {
    public var firstBidder: Expr?
    public var rounds: [AuctionRound]
    public var onCallEffects: [Effect]?
    public var endWhen: Expr?
    public var allPass: AllPassSpec?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        firstBidder = try reader.optionalDecoded("firstBidder") as Expr?
        rounds = try reader.array("rounds")
        onCallEffects = try reader.optionalArray("onCall") as [Effect]?
        endWhen = try reader.optionalDecoded("endWhen") as Expr?
        allPass = try reader.optionalDecoded("allPass")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let firstBidder { pairs.append(("firstBidder", firstBidder.json)) }
        pairs.append(("rounds", .array(rounds.map { $0.json })))
        if let onCallEffects { pairs.append(("onCall", .array(onCallEffects.map { $0.json }))) }
        if let endWhen { pairs.append(("endWhen", endWhen.json)) }
        if let allPass { pairs.append(("allPass", allPass.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - trick-play

public struct FollowRules: Equatable, Sendable, JSONCodable {
    public var mustFollow: Bool?
    public var mustTrumpIfVoid: Bool?
    public var mustOvertrump: Bool?
    public var mustHeadTrick: Bool?
    public var rule: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        mustFollow = try reader.optionalBool("mustFollow")
        mustTrumpIfVoid = try reader.optionalBool("mustTrumpIfVoid")
        mustOvertrump = try reader.optionalBool("mustOvertrump")
        mustHeadTrick = try reader.optionalBool("mustHeadTrick")
        rule = try reader.optionalString("rule")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let mustFollow { pairs.append(("mustFollow", .bool(mustFollow))) }
        if let mustTrumpIfVoid { pairs.append(("mustTrumpIfVoid", .bool(mustTrumpIfVoid))) }
        if let mustOvertrump { pairs.append(("mustOvertrump", .bool(mustOvertrump))) }
        if let mustHeadTrick { pairs.append(("mustHeadTrick", .bool(mustHeadTrick))) }
        if let rule { pairs.append(("rule", .string(rule))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct PlayGuard: Equatable, Sendable, JSONCodable {
    public var expr: Expr
    public var otherwise: String
    public var rule: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        expr = try reader.decoded("expr")
        otherwise = try reader.string("otherwise")
        rule = try reader.optionalString("rule")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("expr", expr.json),
            ("otherwise", .string(otherwise)),
        ]
        if let rule { pairs.append(("rule", .string(rule))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct DummySpec: Equatable, Sendable, JSONCodable {
    public var seat: Expr
    public var revealAfter: String
    public var controlledBy: Expr
    public var rule: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        seat = try reader.decoded("seat")
        revealAfter = try reader.string("revealAfter")
        controlledBy = try reader.decoded("controlledBy")
        rule = try reader.optionalString("rule")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("seat", seat.json),
            ("revealAfter", .string(revealAfter)),
            ("controlledBy", controlledBy.json),
        ]
        if let rule { pairs.append(("rule", .string(rule))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct ClaimsSpec: Equatable, Sendable, JSONCodable {
    public var enabled: Expr?
    public var by: Expr?
    public var acceptedBy: Expr?
    public var rule: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        enabled = try reader.optionalDecoded("enabled") as Expr?
        by = try reader.optionalDecoded("by") as Expr?
        acceptedBy = try reader.optionalDecoded("acceptedBy") as Expr?
        rule = try reader.optionalString("rule")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let enabled { pairs.append(("enabled", enabled.json)) }
        if let by { pairs.append(("by", by.json)) }
        if let acceptedBy { pairs.append(("acceptedBy", acceptedBy.json)) }
        if let rule { pairs.append(("rule", .string(rule))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct TrickPlayParams: Equatable, Sendable, JSONCodable {
    public var tricks: TricksSpec?
    public var activeSeats: Expr?
    public var trump: Expr?
    public var order: String?
    public var suitOf: Expr?
    public var strength: Expr?
    public var follow: FollowRules?
    public var firstLeader: Expr?
    public var firstLeaderRule: String?
    public var leadAllowed: PlayGuard?
    public var playAllowed: PlayGuard?
    public var dummy: DummySpec?
    public var winner: Expr?
    public var winnerRule: String?
    public var nextLeader: Expr?
    public var claims: ClaimsSpec?
    public var onCardPlayedEffects: [Effect]?
    public var onTrickEndEffects: [Effect]?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        tricks = try reader.optionalDecoded("tricks") as TricksSpec?
        activeSeats = try reader.optionalDecoded("activeSeats") as Expr?
        trump = try reader.optionalDecoded("trump") as Expr?
        order = try reader.optionalString("order")
        suitOf = try reader.optionalDecoded("suitOf") as Expr?
        strength = try reader.optionalDecoded("strength") as Expr?
        follow = try reader.optionalDecoded("follow")
        firstLeader = try reader.optionalDecoded("firstLeader") as Expr?
        firstLeaderRule = try reader.optionalString("firstLeaderRule")
        leadAllowed = try reader.optionalDecoded("leadAllowed")
        playAllowed = try reader.optionalDecoded("playAllowed")
        dummy = try reader.optionalDecoded("dummy")
        winner = try reader.optionalDecoded("winner") as Expr?
        winnerRule = try reader.optionalString("winnerRule")
        nextLeader = try reader.optionalDecoded("nextLeader") as Expr?
        claims = try reader.optionalDecoded("claims")
        onCardPlayedEffects = try reader.optionalArray("onCardPlayed") as [Effect]?
        onTrickEndEffects = try reader.optionalArray("onTrickEnd") as [Effect]?
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let tricks { pairs.append(("tricks", tricks.json)) }
        if let activeSeats { pairs.append(("activeSeats", activeSeats.json)) }
        if let trump { pairs.append(("trump", trump.json)) }
        if let order { pairs.append(("order", .string(order))) }
        if let suitOf { pairs.append(("suitOf", suitOf.json)) }
        if let strength { pairs.append(("strength", strength.json)) }
        if let follow { pairs.append(("follow", follow.json)) }
        if let firstLeader { pairs.append(("firstLeader", firstLeader.json)) }
        if let firstLeaderRule { pairs.append(("firstLeaderRule", .string(firstLeaderRule))) }
        if let leadAllowed { pairs.append(("leadAllowed", leadAllowed.json)) }
        if let playAllowed { pairs.append(("playAllowed", playAllowed.json)) }
        if let dummy { pairs.append(("dummy", dummy.json)) }
        if let winner { pairs.append(("winner", winner.json)) }
        if let winnerRule { pairs.append(("winnerRule", .string(winnerRule))) }
        if let nextLeader { pairs.append(("nextLeader", nextLeader.json)) }
        if let claims { pairs.append(("claims", claims.json)) }
        if let onCardPlayedEffects {
            pairs.append(("onCardPlayed", .array(onCardPlayedEffects.map { $0.json })))
        }
        if let onTrickEndEffects {
            pairs.append(("onTrickEnd", .array(onTrickEndEffects.map { $0.json })))
        }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - count-play

public struct GoSpec: Equatable, Sendable, JSONCodable {
    public var rule: String?
    public var lastCardPoints: NumOrExpr?
    public var exactLimitPoints: NumOrExpr?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        rule = try reader.optionalString("rule")
        lastCardPoints = try reader.optionalDecoded("lastCardPoints") as NumOrExpr?
        exactLimitPoints = try reader.optionalDecoded("exactLimitPoints") as NumOrExpr?
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let rule { pairs.append(("rule", .string(rule))) }
        if let lastCardPoints { pairs.append(("lastCardPoints", lastCardPoints.json)) }
        if let exactLimitPoints { pairs.append(("exactLimitPoints", exactLimitPoints.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct CountPlayParams: Equatable, Sendable, JSONCodable {
    public var from: Expr?
    public var to: Expr?
    public var sequence: String?
    public var firstPlayer: Expr?
    public var valueOf: Expr?
    public var limit: NumOrExpr?
    public var rule: String?
    public var go: GoSpec?
    public var pointsOnPlay: Expr?
    public var pointsRule: String?
    public var award: String?
    public var returnCards: Bool?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        from = try reader.optionalDecoded("from") as Expr?
        to = try reader.optionalDecoded("to") as Expr?
        sequence = try reader.optionalString("sequence")
        firstPlayer = try reader.optionalDecoded("firstPlayer") as Expr?
        valueOf = try reader.optionalDecoded("valueOf") as Expr?
        limit = try reader.optionalDecoded("limit") as NumOrExpr?
        rule = try reader.optionalString("rule")
        go = try reader.optionalDecoded("go")
        pointsOnPlay = try reader.optionalDecoded("pointsOnPlay") as Expr?
        pointsRule = try reader.optionalString("pointsRule")
        award = try reader.optionalString("award")
        returnCards = try reader.optionalBool("returnCards")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let from { pairs.append(("from", from.json)) }
        if let to { pairs.append(("to", to.json)) }
        if let sequence { pairs.append(("sequence", .string(sequence))) }
        if let firstPlayer { pairs.append(("firstPlayer", firstPlayer.json)) }
        if let valueOf { pairs.append(("valueOf", valueOf.json)) }
        if let limit { pairs.append(("limit", limit.json)) }
        if let rule { pairs.append(("rule", .string(rule))) }
        if let go { pairs.append(("go", go.json)) }
        if let pointsOnPlay { pairs.append(("pointsOnPlay", pointsOnPlay.json)) }
        if let pointsRule { pairs.append(("pointsRule", .string(pointsRule))) }
        if let award { pairs.append(("award", .string(award))) }
        if let returnCards { pairs.append(("returnCards", .bool(returnCards))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}
