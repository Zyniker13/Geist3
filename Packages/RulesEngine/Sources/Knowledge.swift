// Knowledge, variables, and phase cursor (ARCHITECTURE §9.1, §9.6).
// KnowledgeStore: who knows each card's face. Knowledge is never removed
// during a deal (§9.6 rule 3).
// Internal dictionaries use scalar keys (UInt64 / String) so that canonical
// JSON encoding with `.sortedKeys` is deterministic across platforms
// (required by replay hashing, §10.4).

import CardModel

public struct KnowledgeStore: Codable, Hashable, Sendable {
    /// CardID.raw → the raw SeatSet bits of seats that know its face.
    /// Absent = unknown to everyone.
    private var known: [UInt64: UInt64] = [:]

    public init() {}

    public func knows(_ id: CardID, _ seat: Seat) -> Bool {
        (known[UInt64(id.raw)] ?? 0) & SeatSet.bit(for: seat) != 0
    }

    public func viewers(of id: CardID) -> SeatSet { SeatSet(bits: known[UInt64(id.raw)] ?? 0) }

    /// Public knowledge: every seat (and table/spectator) knows the face.
    public func isPublic(_ id: CardID) -> Bool {
        known[UInt64(id.raw)] == UInt64.max
    }

    /// Grant knowledge: the seat(s) now know this card's face.
    public mutating func reveal(_ id: CardID, to seats: SeatSet) {
        known[UInt64(id.raw), default: 0] |= seats.bits
    }

    /// Make a card public knowledge (all seats, table, spectators).
    public mutating func makePublic(_ id: CardID) {
        known[UInt64(id.raw)] = .max
    }

    // Canonical Codable: a sorted [id, mask] array, so JSON encoding is
    // deterministic across platforms (replay hashing, §10.4).

    private enum CodingKeys: String, CodingKey { case known }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pairs = try container.decode([[UInt64]].self, forKey: .known)
        for pair in pairs where pair.count == 2 {
            known[pair[0]] = pair[1]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sorted = known.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        try container.encode(sorted, forKey: .known)
    }
}

/// Variables by scope (§5.2 `vars`). Values are JSON-ish for the expression
/// engine; CardExpr lands in P2, so P1 stores Swift-native values.
public enum VarValue: Codable, Hashable, Sendable {
    case int(Int)
    case bool(Bool)
    case string(String)
    case seat(Seat)
}

public enum VarScope: String, Codable, Sendable {
    case match
    case deal
    case seatMatch
    case seatDeal
    case teamMatch
    case teamDeal
}

/// A variable's declared identity: scope, type shape, and whether it is
/// hidden information (redacted like a card, §9.6 rule 5).
public struct VarDecl: Codable, Hashable, Sendable {
    public let scope: VarScope
    public let isHidden: Bool
    public let initial: VarValue

    public init(scope: VarScope, isHidden: Bool = false, initial: VarValue) {
        self.scope = scope
        self.isHidden = isHidden
        self.initial = initial
    }
}

/// Typed variable addresses.
public struct VarPath: Hashable, Codable, Sendable {
    public let name: String
    /// Seat/team subscript; nil for match/deal-scoped vars.
    public let index: Int?

    public init(_ name: String, _ index: Int? = nil) {
        self.name = name
        self.index = index
    }

    /// Canonical storage key: "name" or "name@index".
    var storageKey: String {
        index.map { "\(name)@\($0)" } ?? name
    }

}

public struct VarStore: Codable, Hashable, Sendable {
    private var values: [String: VarValue] = [:]
    /// Canonical storage: sorted array (Set<String> encodes unsorted).
    private var hidden: [String] = []
    private var declarations: [String: VarDecl] = [:]

    public init() {}

    public mutating func declare(_ name: String, _ decl: VarDecl) {
        declarations[name] = decl
        if decl.isHidden, !hidden.contains(name) {
            hidden.append(name)
            hidden.sort()
        }
    }

    public func isHidden(_ name: String) -> Bool { hidden.contains(name) }

    public func get(_ path: VarPath) -> VarValue? { values[path.storageKey] }

    public mutating func set(_ path: VarPath, _ value: VarValue) {
        values[path.storageKey] = value
    }

    public mutating func add(_ path: VarPath, _ delta: Int) {
        switch values[path.storageKey] {
        case .int(let current): values[path.storageKey] = .int(current + delta)
        case nil: values[path.storageKey] = .int(delta)
        default: break  // type mismatch: silently ignored in P1; P2 validator owns this
        }
    }
}

/// The current phase and its mechanic sub-state (§9.1 `phase`).
public struct PhaseCursor: Codable, Hashable, Sendable {
    public let phaseID: String
    /// Mechanic-local sub-state (Codable). Mechanics that need none use nil.
    public let substate: MechanicSubstate?

    public init(phaseID: String, substate: MechanicSubstate? = nil) {
        self.phaseID = phaseID
        self.substate = substate
    }
}

/// Typed sub-states for the built-in mechanics; each mechanic owns its case.
public enum MechanicSubstate: Codable, Hashable, Sendable {
    case trick(TrickSubstate)
}
