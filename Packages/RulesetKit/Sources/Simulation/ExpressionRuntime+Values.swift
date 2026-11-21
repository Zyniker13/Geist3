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

    /// An engine variable value as an expression value. Seat-typed
    /// values spell with the declared seat names (§7.3) so seat builtin
    /// calls like `left(deal.declarer, 1)` resolve against `seats()`;
    /// unnamed layouts keep the positional `S<n>` spellings.
    func value(from varValue: RulesEngine.VarValue) -> Value {
        switch varValue {
        case .int(let n): return .int(Int64(n))
        case .bool(let b): return .bool(b)
        case .string(let s): return .string(s)
        case .seat(let seat):
            let spelling = seatSpellings.indices.contains(seat.raw)
                ? seatSpellings[seat.raw] : "S\(seat.raw + 1)"
            return .string(spelling)
        case .record(let name, let fields):
            return .record(
                name: name,
                fields: fields.mapValues(value(from:)))
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

    /// The static type a runtime binding presents to the checker (§7.5).
    /// Strings erase to `any`: seat, team and suit spellings are plain
    /// strings at run time, so the permissive erasure matches what the
    /// evaluator resolves. Ints, bools, cards and records keep their kind
    /// (records so member access checks), and a let-bound name thereby
    /// shadows its canonical spelling with its real shape.
    static func bindingType(_ value: EvalValue) -> ExprType {
        switch value {
        case .null, .string: return .any
        case .bool: return .bool
        case .int: return .int
        case .card: return .card
        case .list(let items):
            var element: ExprType?
            var mixed = false
            for item in items {
                let kind = bindingType(item)
                if let known = element {
                    if known != kind { mixed = true; break }
                } else {
                    element = kind
                }
            }
            return mixed ? .list(.any) : .list(element ?? .any)
        case .record(_, let fields):
            return .record(RecordType(fields: fields.mapValues(bindingType)))
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
