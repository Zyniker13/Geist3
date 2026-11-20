// Value conversions for the expression runtime (ARCHITECTURE §7.5):
// between the engine's variable and card representations, the JSON option
// values, the `Value` the CardExpr evaluator produces, and the `EvalValue`
// the engine's `EvalContext.eval` returns. All static and pure (§5).

import CardModel
@_spi(HostOnly) import RulesEngine

extension ExpressionRuntime {

    /// A card value for a face (identity-free reads).
    static func cardFaceValue(_ face: CardFace) -> Value {
        .card(
            id: face.id,
            suit: face.suit?.code ?? "",
            rank: face.rank.code)
    }

    /// A card value for an instance id: the face comes from the zone
    /// store's instances; unknown ids read face-down (empty suit and rank).
    static func cardInstanceValue(_ id: CardID, state: GameState) -> Value {
        for instance in state.zones.allInstances where instance.id == id {
            return cardFaceValue(instance.face)
        }
        return .card(id: "", suit: "", rank: "")
    }

    /// A card value for a whole instance.
    static func cardValue(_ instance: CardInstance) -> Value {
        cardFaceValue(instance.face)
    }

    /// An engine variable value as an expression value.
    static func value(from varValue: RulesEngine.VarValue) -> Value {
        switch varValue {
        case .int(let n): return .int(Int64(n))
        case .bool(let b): return .bool(b)
        case .string(let s): return .string(s)
        case .seat(let seat): return .string("S\(seat.raw + 1)")
        case .null: return .null
        }
    }

    static func value(from json: JSON) -> Value {
        switch json {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let n): return .int(Int64(n))
        case .decimal(let text):
            return Int64(text).map { .int($0) } ?? .null
        case .string(let s): return .string(s)
        case .array(let items): return .list(items.map(value(from:)))
        case .object: return .null
        }
    }

    static func value(from eval: EvalValue) -> Value {
        switch eval {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let n): return .int(n)
        case .string(let s): return .string(s)
        case .card(let id, let suit, let rank): return .card(id: id, suit: suit, rank: rank)
        case .list(let items): return .list(items.map(value(from:)))
        case .record(let name, let fields):
            return .record(
                name: name,
                fields: fields.mapValues(value(from:)))
        }
    }

    static func evalValue(from value: Value) -> EvalValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let n): return .int(n)
        case .string(let s): return .string(s)
        case .card(let id, let suit, let rank): return .card(id: id, suit: suit, rank: rank)
        case .list(let items): return .list(items.map(evalValue(from:)))
        case .record(let name, let fields):
            return .record(
                name: name,
                fields: fields.mapValues(evalValue(from:)))
        }
    }

    static func failure(
        from fault: EvaluationFault, pointer: String
    ) -> EvalFailure {
        if fault.kind == .fuelExhausted {
            return .budget(pointer: pointer)
        }
        return .fault(pointer: pointer, detail: "\(fault.kind): \(fault.message)")
    }
}

// (no local Value extensions: `Value.cardID`/`Value.cardSuit` already
// exist as optional accessors in Value.swift)
