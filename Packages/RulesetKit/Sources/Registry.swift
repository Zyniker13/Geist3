import CardExpr
import Foundation

// MARK: - Variables and zones

/// Scoped-variable stores (§7.3): match-scoped variables persist across
/// deals; deal-scoped variables reset at the start of each deal.
public enum VarStore: String, Sendable {
    case match
    case deal
}

/// Variable scoping: match- or deal-scoped alone, or per-seat/per-team.
public enum VarScope: String, Sendable {
    case match
    case seatMatch = "seat-match"
    case teamMatch = "team-match"
    case deal
    case seatDeal = "seat-deal"
    case teamDeal = "team-deal"

    /// The store this scope's variables live in.
    public var store: VarStore {
        switch self {
        case .match, .seatMatch, .teamMatch: return .match
        case .deal, .seatDeal, .teamDeal: return .deal
        }
    }

    /// Whether references carry an index (a seat for seat scopes, a team
    /// for team scopes).
    public var isIndexed: Bool {
        switch self {
        case .match, .deal: return false
        case .seatMatch, .teamMatch, .seatDeal, .teamDeal: return true
        }
    }

    /// The type of the index expression for indexed scopes.
    public var keyType: ExprType {
        switch self {
        case .seatMatch, .seatDeal: return .seat
        case .teamMatch, .teamDeal: return .team
        case .match, .deal: return .int
        }
    }
}

/// A resolved reference to a scoped variable.
public struct VarRef: Sendable, Hashable {
    public let store: VarStore
    public let scope: VarScope
    public let name: String

    public init(store: VarStore, scope: VarScope, name: String) {
        self.store = store
        self.scope = scope
        self.name = name
    }
}

/// A declared scoped variable from the ruleset's `vars` section.
public struct VarDecl: Sendable {
    public let scope: VarScope
    public let type: ExprType
    /// Initializer expression text; the loader type-checks it separately.
    public let initial: String

    public init(scope: VarScope, type: ExprType, initial: String) {
        self.scope = scope
        self.type = type
        self.initial = initial
    }
}

/// How visible a zone's contents are to the ruleset.
public enum ZoneVisibility: String, Sendable {
    case publicZone = "public"
    case owner
    case none
}

/// A zone declaration's information relevant to type checking.
public struct ZoneInfo: Sendable {
    public let id: String
    public let visibility: ZoneVisibility

    public init(id: String, visibility: ZoneVisibility) {
        self.id = id
        self.visibility = visibility
    }
}

// MARK: - Context roots

/// Fields available on the `players` context root (§7.3).
public enum PlayersField: String, Sendable {
    case count
    case active

    /// The field's expression type.
    public var type: ExprType {
        switch self {
        case .count: return .int
        case .active: return .int
        }
    }
}

/// Fields available on the `trick` context root (§7.3).
public enum TrickField: String, Sendable {
    case number
    case leader
    case cards
    case ledSuit
    case winner

    /// The field's expression type.
    public var type: ExprType {
        switch self {
        case .number: return .int
        case .leader: return .seat
        case .cards: return .list(.card)
        case .ledSuit: return .optional(.suit)
        case .winner: return .optional(.seat)
        }
    }
}

// MARK: - Builtins, macros, natives

/// The built-in functions of the expression language (§7.3).
public enum BuiltinID: String, Sendable, CaseIterable {
    case seats, teams, left, right, partner, team, opponents, nextActive
    case zone, holderOf, tricksWon, playedBy, rankIndex, colorOf, rankCode
    case top, choice, dealtHands
}

/// The collection macros of the expression language (§7.1). `lambda` is
/// true for the macros that bind a variable and evaluate an expression
/// with it in scope.
public enum MacroID: String, Sendable, CaseIterable {
    case map, filter, exists, all, count, sum, min, max, size
    case sortBy
    case first, contains

    /// Whether the macro binds a lambda variable.
    public var lambda: Bool {
        switch self {
        case .map, .filter, .exists, .all, .count, .sortBy: return true
        case .sum, .min, .max, .size, .first, .contains: return false
        }
    }
}

/// One overload of a builtin or native function.
public struct ExprSignature: Sendable {
    public let params: [ExprType]
    public let result: ExprType
    /// Host-only functions (§7.5) are listed only in the host context.
    public let hostOnly: Bool

    public init(_ params: [ExprType], result: ExprType, hostOnly: Bool = false) {
        self.params = params
        self.result = result
        self.hostOnly = hostOnly
    }
}

/// A registered native function (§5.8), keyed by its dotted name.
public typealias NativeSignature = ExprSignature

/// The parsed parts of a def signature, without its body.
public struct DefHeader: Sendable {
    public let name: String
    public let params: [String]
    public let types: [ExprType]
    public let result: ExprType

    public init(name: String, params: [String], types: [ExprType], result: ExprType) {
        self.name = name
        self.params = params
        self.types = types
        self.result = result
    }
}

/// A ruleset def: its parsed signature and its parsed body.
public struct DefSignature: Sendable {
    public let name: String
    public let params: [String]
    public let types: [ExprType]
    public let result: ExprType
    public let body: AST

    public init(name: String, params: [String], types: [ExprType], result: ExprType, body: AST) {
        self.name = name
        self.params = params
        self.types = types
        self.result = result
        self.body = body
    }
}

// MARK: - Canonical record types

/// The card record (`c.suit`, `c.rank`, `c.id`).
public let cardRecord = RecordType(
    name: "card",
    fields: ["id": .string, "suit": .suit, "rank": .rank]
)

/// The contract record (`contract.level`, `contract.strain`,
/// `contract.doubled`).
public let contractRecord = RecordType(
    name: "contract",
    fields: ["strain": .suit, "level": .int, "doubled": .bool]
)

/// The call record (`call.bid`, `call.strain`, `call.doubled`).
public let callRecord = RecordType(
    name: "call",
    fields: ["bid": .int, "strain": .suit, "doubled": .bool]
)

/// The result record of the `bridge.score` native (§5.8).
public let bridgeScoreRecord = RecordType(
    name: "bridge.scoreResult",
    fields: ["below": .int, "above": .int, "defenders": .int, "total": .int]
)

/// Record types every ruleset can name in def signatures and var types.
public let canonicalRecords: [String: RecordType] = [
    "card": cardRecord,
    "contract": contractRecord,
    "call": callRecord,
    "bridge.scoreResult": bridgeScoreRecord,
]

/// Contextual bindings every expression can rely on (§7.3), regardless of
/// where in a rule the expression runs. Mechanics and effects bind more
/// (lambda variables, def parameters) while checking their bodies.
public let canonicalContextual: [String: ExprType] = [
    "dealer": .seat,
    "seat": .seat,
    "c": .card,
    "s": .seat,
    "t": .team,
    "call": .record(callRecord),
    "param": .any,
    "cards": .list(.card),
    "isCrib": .bool,
    "awardee": .seat,
]

/// Signatures of the built-in functions (§7.3), keyed by builtin.
public let builtinRegistry: [BuiltinID: [ExprSignature]] = {
    var table: [BuiltinID: [ExprSignature]] = [:]
    func add(_ id: BuiltinID, _ signature: ExprSignature) {
        table[id, default: []].append(signature)
    }
    add(.seats, ExprSignature([], result: .list(.seat)))
    add(.teams, ExprSignature([], result: .list(.team)))
    add(.left, ExprSignature([.seat, .int], result: .seat))
    add(.right, ExprSignature([.seat, .int], result: .seat))
    add(.partner, ExprSignature([.seat], result: .seat))
    add(.team, ExprSignature([.seat], result: .team))
    add(.opponents, ExprSignature([.team], result: .team))
    add(.nextActive, ExprSignature([.seat], result: .seat))
    add(.zone, ExprSignature([.string], result: .list(.card)))
    add(.zone, ExprSignature([.string, .seat], result: .list(.card)))
    add(.zone, ExprSignature([.string, .team], result: .list(.card)))
    add(.holderOf, ExprSignature([.string], result: .seat, hostOnly: true))
    add(.tricksWon, ExprSignature([.union([.team, .seat])], result: .int))
    add(.playedBy, ExprSignature([.seat], result: .list(.card)))
    add(.rankIndex, ExprSignature([.string, .rank], result: .int))
    add(.colorOf, ExprSignature([.suit], result: .string))
    add(.rankCode, ExprSignature([.rank], result: .int))
    add(.top, ExprSignature([.int], result: .list(.card)))
    add(.choice, ExprSignature([.string, .seat], result: .string))
    add(.dealtHands, ExprSignature([], result: .list(.list(.card))))
    return table
}()

/// The natives the reference rulesets call (§5.8). The remaining §5.8
/// natives join this table when their games are implemented; references
/// to unregistered names are validation errors.
public let nativeRegistry: [String: NativeSignature] = [
    "cribbage.handScore": NativeSignature(
        [.list(.card), .card, .bool],
        result: .int
    ),
    "cribbage.pegPoints": NativeSignature([.list(.card)], result: .int),
    "bridge.score": NativeSignature(
        [.record(contractRecord), .int, .bool, .string],
        result: .record(bridgeScoreRecord)
    ),
    "bridge.honors": NativeSignature(
        [.list(.list(.card)), .optional(.suit), .team],
        result: .int
    ),
]

extension TypeContext {
    /// The signature of a native by dotted name, preferring ruleset-specific
    /// registrations over the shared registry (§5.8).
    public func native(named name: String) -> NativeSignature? {
        natives[name] ?? nativeRegistry[name]
    }
}
