// Effect vocabulary (§5.4). Decoding is keyed by which vocabulary word the
// effect object contains; an object containing more than one vocabulary word
// is ambiguous and rejected, as is any unknown key — the vocabulary is closed
// so authoring errors surface immediately instead of vanishing on re-encode.
// Every case carries the optional `rule` provenance tag the spec allows.

import Foundation

/// How many cards a `move` effect transfers. Absent means "all cards the
/// source selection holds"; an integer means "top N"; anything else is an
/// expression evaluated per move.
public enum CardCount: Equatable, Sendable, JSONCodable {
    case all
    case top(Int)
    case expr(Expr)

    public init(json: JSON, path: String) throws(SchemaError) {
        if json.isNull {
            self = .all
        } else if let i = json.intValue {
            self = .top(i)
        } else if let s = json.stringValue {
            self = .expr(Expr(source: s))
        } else {
            throw SchemaError.wrongType(expected: "int or expression string", path: path)
        }
    }

    public var json: JSON {
        switch self {
        case .all: return .null
        case .top(let n): return .int(n)
        case .expr(let e): return e.json
        }
    }
}

/// One data movement: source selection, destination, and card count. Source
/// and destination keep their raw shapes (zone name, `{zone, seat?, index?}`,
/// or an array) because the spec allows several forms; validation (P2.7)
/// checks those shapes.
public struct MoveSpec: Equatable, Sendable {
    public var from: JSON
    public var to: JSON
    public var toSeat: Expr?
    public var toTeam: Expr?
    public var cards: CardCount

    public init(from: JSON, to: JSON, toSeat: Expr? = nil, toTeam: Expr? = nil, cards: CardCount = .all) {
        self.from = from
        self.to = to
        self.toSeat = toSeat
        self.toTeam = toTeam
        self.cards = cards
    }
}

/// The Effects vocabulary (§5.4). Case names mirror the JSON keys.
public enum Effect: Equatable, Sendable, JSONCodable {
    case set(path: String, to: Expr, rule: String?)
    case add(path: String, value: Expr, event: String?, rule: String?)
    case letBinding(name: String, be: Expr, rule: String?)
    case ifElse(condition: Expr, then: [Effect], elseBranch: [Effect]?, rule: String?)
    case forEach(kind: String, body: [Effect], rule: String?)
    case move(MoveSpec, rule: String?)
    case reveal(zone: String, seat: Expr?, to: JSON?, rule: String?)
    case emit(name: String, data: [JSONField]?, rule: String?)

    /// Vocabulary words that select the case.
    static let vocabulary: [String] = [
        "set", "add", "let", "if", "forEach", "move", "reveal", "emit",
    ]

    public init(json: JSON, path: String) throws(SchemaError) {
        let present = Effect.vocabulary.filter { json[$0] != nil }
        switch present.count {
        case 0:
            throw SchemaError.wrongType(expected: "an effect object", path: path)
        case 1:
            break
        default:
            throw SchemaError.wrongType(
                expected: "exactly one effect key (found \(present.joined(separator: ", ")))",
                path: path)
        }

        var reader = try FieldReader(json, path: path)

        func decodeEffectArray(_ key: String) throws(SchemaError) -> [Effect] {
            let raw = try reader.value(key)
            let arrayPath = reader.childPath(key)
            guard let items = raw.arrayValue else {
                throw SchemaError.wrongType(expected: "array of effects", path: arrayPath)
            }
            return try items.enumerated().map { (index: Int, item: JSON) throws(SchemaError) in
                try Effect(json: item, path: "\(arrayPath)[\(index)]")
            }
        }

        func decodeMove() throws(SchemaError) -> MoveSpec {
            let raw = try reader.value("move")
            var moveReader = try FieldReader(raw, path: reader.childPath("move"))
            let spec = MoveSpec(
                from: try moveReader.value("from"),
                to: try moveReader.value("to"),
                toSeat: try moveReader.optionalDecoded("toSeat") as Expr?,
                toTeam: try moveReader.optionalDecoded("toTeam") as Expr?,
                cards: try moveReader.optionalDecoded("cards") as CardCount? ?? .all)
            try moveReader.rejectLeftovers()
            return spec
        }

        switch present[0] {
        case "set":
            self = .set(
                path: try reader.string("set"),
                to: try reader.decoded("to") as Expr,
                rule: try reader.optionalString("rule"))
        case "add":
            self = .add(
                path: try reader.string("add"),
                value: try reader.decoded("value") as Expr,
                event: try reader.optionalString("event"),
                rule: try reader.optionalString("rule"))
        case "let":
            self = .letBinding(
                name: try reader.string("let"),
                be: try reader.decoded("be") as Expr,
                rule: try reader.optionalString("rule"))
        case "if":
            self = .ifElse(
                condition: try reader.decoded("if") as Expr,
                then: try decodeEffectArray("then"),
                elseBranch: try reader.optionalArray("else") as [Effect]?,
                rule: try reader.optionalString("rule"))
        case "forEach":
            self = .forEach(
                kind: try reader.string("forEach"),
                body: try decodeEffectArray("do"),
                rule: try reader.optionalString("rule"))
        case "move":
            self = .move(try decodeMove(), rule: try reader.optionalString("rule"))
        case "reveal":
            let raw = try reader.value("reveal")
            var revealReader = try FieldReader(raw, path: reader.childPath("reveal"))
            let zone = try revealReader.string("zone")
            let seat = try revealReader.optionalDecoded("seat") as Expr?
            let to = revealReader.optionalValue("to")
            try revealReader.rejectLeftovers()
            self = .reveal(zone: zone, seat: seat, to: to, rule: try reader.optionalString("rule"))
        case "emit":
            let raw = try reader.value("emit")
            guard let name = raw.stringValue else {
                throw SchemaError.wrongType(expected: "event name string", path: reader.childPath("emit"))
            }
            var data: [JSONField]?
            if let dataJSON = json["data"] {
                guard let dataObject = dataJSON.fields else {
                    throw SchemaError.wrongType(expected: "object of event data", path: reader.childPath("data"))
                }
                data = try dataObject.map { (field: JSONField) throws(SchemaError) in
                    guard let s = field.value.stringValue else {
                        throw SchemaError.wrongType(
                            expected: "expression string",
                            path: "\(reader.childPath("data")).\(field.key)")
                    }
                    return JSONField(key: field.key, value: .string(s))
                }
            }
            self = .emit(name: name, data: data, rule: try reader.optionalString("rule"))
        default:
            throw SchemaError.wrongType(expected: "an effect object", path: path)
        }

        try reader.rejectLeftovers()
    }

    public var json: JSON {
        switch self {
        case .set(let path, let to, let rule):
            var pairs: [JSONField] = [
                JSONField(key: "set", value: .string(path)),
                JSONField(key: "to", value: to.json),
            ]
            if let rule { pairs.append(JSONField(key: "rule", value: .string(rule))) }
            return .object(pairs)
        case .add(let path, let value, let event, let rule):
            var pairs: [JSONField] = [
                JSONField(key: "add", value: .string(path)),
                JSONField(key: "value", value: value.json),
            ]
            if let event { pairs.append(JSONField(key: "event", value: .string(event))) }
            if let rule { pairs.append(JSONField(key: "rule", value: .string(rule))) }
            return .object(pairs)
        case .letBinding(let name, let be, let rule):
            var pairs: [JSONField] = [
                JSONField(key: "let", value: .string(name)),
                JSONField(key: "be", value: be.json),
            ]
            if let rule { pairs.append(JSONField(key: "rule", value: .string(rule))) }
            return .object(pairs)
        case .ifElse(let condition, let then, let elseBranch, let rule):
            var pairs: [JSONField] = [
                JSONField(key: "if", value: condition.json),
                JSONField(key: "then", value: .array(then.map { $0.json })),
            ]
            if let elseBranch {
                pairs.append(JSONField(key: "else", value: .array(elseBranch.map { $0.json })))
            }
            if let rule { pairs.append(JSONField(key: "rule", value: .string(rule))) }
            return .object(pairs)
        case .forEach(let kind, let body, let rule):
            var pairs: [JSONField] = [
                JSONField(key: "forEach", value: .string(kind)),
                JSONField(key: "do", value: .array(body.map { $0.json })),
            ]
            if let rule { pairs.append(JSONField(key: "rule", value: .string(rule))) }
            return .object(pairs)
        case .move(let spec, let rule):
            var movePairs: [JSONField] = [
                JSONField(key: "from", value: spec.from),
                JSONField(key: "to", value: spec.to),
            ]
            if let toSeat = spec.toSeat { movePairs.append(JSONField(key: "toSeat", value: toSeat.json)) }
            if let toTeam = spec.toTeam { movePairs.append(JSONField(key: "toTeam", value: toTeam.json)) }
            if spec.cards != .all { movePairs.append(JSONField(key: "cards", value: spec.cards.json)) }
            var pairs: [JSONField] = [JSONField(key: "move", value: .object(movePairs))]
            if let rule { pairs.append(JSONField(key: "rule", value: .string(rule))) }
            return .object(pairs)
        case .reveal(let zone, let seat, let to, let rule):
            var revealPairs: [JSONField] = [JSONField(key: "zone", value: .string(zone))]
            if let seat { revealPairs.append(JSONField(key: "seat", value: seat.json)) }
            if let to { revealPairs.append(JSONField(key: "to", value: to)) }
            var pairs: [JSONField] = [JSONField(key: "reveal", value: .object(revealPairs))]
            if let rule { pairs.append(JSONField(key: "rule", value: .string(rule))) }
            return .object(pairs)
        case .emit(let name, let data, let rule):
            var pairs: [JSONField] = [JSONField(key: "emit", value: .string(name))]
            if let data { pairs.append(JSONField(key: "data", value: .object(data))) }
            if let rule { pairs.append(JSONField(key: "rule", value: .string(rule))) }
            return .object(pairs)
        }
    }
}
