import CardExpr

/// The runtime value model (ARCHITECTURE.md §7.6): the evaluator is a
/// tree-walking interpreter over `Value`.
///
/// String-domain types (`suit`, `rank`, `seat`, `team`, phase names)
/// carry their spelling as a `.string` payload. Their static types are
/// checked at load time, which keeps a `suit` apart from a `rank`; at
/// runtime values compare by payload, so no dynamic dispatch is needed.
/// Equality is structural and total.
public enum Value: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    /// A card instance: deal-scoped `id`, face `suit`, face `rank`.
    case card(id: String, suit: String, rank: String)
    case list([Value])
    case record(name: String, fields: [String: Value])

    /// The id of a card value.
    public var cardID: String? {
        if case .card(let id, _, _) = self { return id }
        return nil
    }

    /// The suit spelling of a card value.
    public var cardSuit: String? {
        if case .card(_, let suit, _) = self { return suit }
        return nil
    }

    /// The rank spelling of a card value.
    public var cardRank: String? {
        if case .card(_, _, let rank) = self { return rank }
        return nil
    }
}
