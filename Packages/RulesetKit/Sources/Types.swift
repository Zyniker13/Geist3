/// The static types of CardExpr expressions (ARCHITECTURE.md §7.2).
///
/// Unification is deliberately simple: the DSL has no generic variables of
/// its own, so inference variables arise only from empty list literals.
/// String literals carry `literalString`, which unifies with every
/// string-domained type (`string`, `suit`, `rank`, `phase`, `seat`, `team`),
/// and `null` unifies with any type (§7.4 optional semantics).
public indirect enum ExprType: Sendable, Hashable, CustomStringConvertible {
    case int
    case bool
    case string
    case suit
    case rank
    case card
    case seat
    case team
    case phase
    /// Accepts anything; the `param` contextual binding (§7.3).
    case any
    /// One of several types (builtin signatures only, e.g. §7.3
    /// `tricksWon(team | seat)`); never appears in rule text. A string
    /// literal does not unify with a union: with several string-domained
    /// members the meaning would be ambiguous.
    case union([ExprType])
    case list(ExprType)
    case optional(ExprType)
    case record(RecordType)
    /// A string literal, which also unifies with the enum types whose
    /// values are written as string literals.
    case literalString
    /// The `null` literal, which unifies with any type.
    case literalNull
    /// Internal inference variable (empty list elements); resolved before
    /// a checked expression is exposed.
    case varType(Int)

    /// The type without its optional wrapper, if any (§7.4: `T?` flows
    /// where `T` is expected and `T` flows where `T?` is declared).
    public var unwrapped: ExprType {
        if case .optional(let inner) = self { return inner }
        return self
    }

    /// True when the type is optional.
    public var isOptional: Bool {
        if case .optional = self { return true }
        return false
    }

    /// Whether a string literal can be written as a value of this type
    /// (§7.2: the DSL has no suit/rank/phase literals, only strings).
    public var isStringDomain: Bool {
        switch self {
        case .string, .suit, .rank, .phase, .seat, .team: return true
        default: return false
        }
    }

    public var description: String { typeName(self) }
}

/// A named or anonymous record type (§7.2). Two record types unify when
/// their names are equal and their fields match pairwise.
public struct RecordType: Sendable, Hashable, CustomStringConvertible {
    public var name: String?
    public var fields: [String: ExprType]

    public init(name: String? = nil, fields: [String: ExprType]) {
        self.name = name
        self.fields = fields
    }

    /// Human-readable shape, e.g. `{below: int, above: int}`.
    public var description: String {
        let parts = fields.sorted { $0.key < $1.key }.map { "\($0.key): \(typeName($0.value))" }
        return "{\(parts.joined(separator: ", "))}"
    }
}

/// The DSL spelling of a type (error messages, tests).
///
/// Scalar names live in a table; the switch below handles only the
/// structured cases. No case may fall through to `String(describing:)`,
/// whose `description` implementation calls `typeName` again and would
/// recurse forever on a missed case — an unhandled case fails loudly.
public func typeName(_ type: ExprType) -> String {
    let scalarNames: [ExprType: String] = [
        .int: "int", .bool: "bool", .string: "string", .suit: "suit",
        .rank: "rank", .card: "card", .seat: "seat", .team: "team",
        .phase: "phase", .any: "any", .literalString: "string", .literalNull: "null",
    ]
    switch type {
    case .optional(let inner):
        return typeName(inner) + "?"
    case .list(let element):
        return "list<\(typeName(element))>"
    case .record(let record):
        return record.name ?? record.description
    case .varType(let id):
        return "?T\(id)"
    case .union(let members):
        return members.map(typeName).joined(separator: " | ")
    default:
        if let name = scalarNames[type] { return name }
        fatalError("typeName: unhandled ExprType case \(type)")
    }
}
