// Card identity types (ARCHITECTURE §4.1).
// A CardFace is what a card *is*; a CardID is which physical copy it is in
// this deal. Face IDs follow §4.1: "QS", "10H", "OEi", "T21", "Fool", "JokerBig".

public enum SuitSystem: String, Codable, Sendable, CaseIterable {
    case french
    case german
    case swiss
    case latinSpanish
    case latinItalian
    case tarot
}

public struct Suit: Hashable, Codable, Sendable {
    public let code: String

    public init(_ code: String) { self.code = code }

    public static let spades = Suit("S")
    public static let hearts = Suit("H")
    public static let diamonds = Suit("D")
    public static let clubs = Suit("C")
    public static let trumps = Suit("T")
}

public struct Rank: Hashable, Codable, Sendable {
    public let code: String

    public init(_ code: String) { self.code = code }

    public static let ace = Rank("A")
    public static let king = Rank("K")
    public static let queen = Rank("Q")
    public static let jack = Rank("J")
    public static let ten = Rank("10")
    public static let nine = Rank("9")
    public static let eight = Rank("8")
    public static let seven = Rank("7")
    public static let six = Rank("6")
    public static let five = Rank("5")
    public static let four = Rank("4")
    public static let three = Rank("3")
    public static let two = Rank("2")
    public static let unter = Rank("U")
    public static let ober = Rank("O")
    public static let sota = Rank("S")
    public static let caballo = Rank("C")
    public static let rey = Rank("R")
    public static let fante = Rank("F")
    public static let cavallo = Rank("Kn")
    public static let fool = Rank("Fool")
    public static let jokerBig = Rank("JokerBig")
    public static let jokerLittle = Rank("JokerLittle")

    /// Numeric trumps "1"…"21" for tarot-family decks.
    public static func trump(_ n: Int) -> Rank { Rank(String(n)) }
}

public struct CardFace: Hashable, Codable, Sendable {
    public let suit: Suit?
    public let rank: Rank
    public var id: String

    public init(suit: Suit?, rank: Rank) {
        self.suit = suit
        self.rank = rank
        self.id = CardFace.identifier(suit: suit, rank: rank)
    }

    /// "QS", "10H", "OEi", "T21", "Fool", "JokerBig".
    /// Trumps encode suit-first ("T21"); suitless faces encode rank only.
    public static func identifier(suit: Suit?, rank: Rank) -> String {
        guard let suit else { return rank.code }
        if suit.code == "T" { return "T" + rank.code }
        return rank.code + suit.code
    }
}

/// Opaque per-deal instance ID (ARCHITECTURE §9.5): assigned after the
/// shuffle, in dealing order, fresh each deal, so it never correlates with a
/// face across deals or with the pre-shuffle order.
public struct CardID: Hashable, Codable, Sendable {
    public let raw: UInt16

    public init(_ raw: UInt16) { self.raw = raw }
}
