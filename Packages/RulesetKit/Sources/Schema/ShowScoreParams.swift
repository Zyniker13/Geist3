// Show and score phase parameter structs (§5.6/§5.7).

import Foundation

// MARK: - show

public struct ShowEntry: Equatable, Sendable, JSONCodable {
    public var zone: String
    public var seat: Expr?
    public var award: Expr?
    public var isCrib: Bool?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        zone = try reader.string("zone")
        seat = try reader.optionalDecoded("seat") as Expr?
        award = try reader.optionalDecoded("award") as Expr?
        isCrib = try reader.optionalBool("isCrib")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("zone", .string(zone))]
        if let seat { pairs.append(("seat", seat.json)) }
        if let award { pairs.append(("award", award.json)) }
        if let isCrib { pairs.append(("isCrib", .bool(isCrib))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct ShowParams: Equatable, Sendable, JSONCodable {
    public var order: [ShowEntry]
    /// A shared zone counted with every pile (§5.6), e.g. the cribbage
    /// starter. Validators check the id against the declared zones.
    public var with: String?
    public var points: Expr?
    public var pointsRule: String?
    public var manual: Expr?
    public var muggins: Expr?
    public var award: Expr?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        order = try reader.array("order")
        with = try reader.optionalString("with")
        points = try reader.optionalDecoded("points") as Expr?
        pointsRule = try reader.optionalString("pointsRule")
        manual = try reader.optionalDecoded("manual") as Expr?
        muggins = try reader.optionalDecoded("muggins") as Expr?
        award = try reader.optionalDecoded("award") as Expr?
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("order", .array(order.map { $0.json }))]
        if let with { pairs.append(("with", .string(with))) }
        if let points { pairs.append(("points", points.json)) }
        if let pointsRule { pairs.append(("pointsRule", .string(pointsRule))) }
        if let manual { pairs.append(("manual", manual.json)) }
        if let muggins { pairs.append(("muggins", muggins.json)) }
        if let award { pairs.append(("award", award.json)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

// MARK: - score

public struct ScoreChoice: Equatable, Sendable, JSONCodable {
    public var id: String
    public var seat: Expr
    public var when: Expr
    public var values: [String]

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        id = try reader.string("id")
        seat = try reader.decoded("seat")
        when = try reader.decoded("when")
        values = try reader.array("values")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        let pairs: [(String, JSON)] = [
            ("id", .string(id)),
            ("seat", seat.json),
            ("when", when.json),
            ("values", .array(values.map { .string($0) })),
        ]
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

public struct ScoreParams: Equatable, Sendable, JSONCodable {
    public var effects: [Effect]
    public var choices: [ScoreChoice]?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        effects = try reader.array("effects")
        choices = try reader.optionalArray("choices")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [("effects", .array(effects.map { $0.json }))]
        if let choices { pairs.append(("choices", .array(choices.map { $0.json }))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}
