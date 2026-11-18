// The built-in deck catalogue (ARCHITECTURE §4.2). Every deck ID the plan
// lists is a static spec; contents are derived, so sizes are testable.

/// A face pack is a *display* choice only (§4.2): art never affects deck
/// structure or rules.
public enum FacePack: String, Codable, Sendable, CaseIterable {
    case standard
    case fourColor
    case jumbo
    case highContrast
    case latinSpanishPattern
    case latinItalianPattern
    case germanPattern
}

public struct DeckSpec: Hashable, Codable, Sendable {
    /// DeckCatalog ID of the base deck, or nil for a fully custom deck.
    public let base: String?
    public let copies: Int
    /// Face IDs removed from the base deck.
    public let remove: [String]
    /// Faces added (after removals).
    public let add: [CardFace]
    public let faces: FacePack

    public init(base: String?, copies: Int = 1, remove: [String] = [], add: [CardFace] = [], faces: FacePack = .standard) {
        self.base = base
        self.copies = copies
        self.remove = remove
        self.add = add
        self.faces = faces
    }
}

public enum DeckCatalog {
    public static let allDeckIDs: [String] = [
        "french-52", "french-52j1", "french-52j2", "french-104j4",
        "euchre-24", "euchre-25",
        "piquet-32",
        "pinochle-48", "pinochle-80",
        "bezique-64",
        "doko-48", "doko-40",
        "german-32", "german-24",
        "swiss-36",
        "french-36",
        "spanish-40", "spanish-48",
        "italian-40",
        "tarot-78", "tarock-54",
        "custom",
    ]

    /// The spec for a built-in deck ID. `custom` has no fixed spec; callers
    /// build one inline (base: nil).
    public static func spec(for id: String) -> DeckSpec? {
        switch id {
        case "french-52":
            return DeckSpec(base: id, copies: 1)
        case "french-52j1":
            return DeckSpec(base: "french-52", add: [joker(big: true)])
        case "french-52j2":
            return DeckSpec(base: "french-52", add: [joker(big: true), joker(big: false)])
        case "french-104j4":
            return DeckSpec(base: "french-52", copies: 2,
                            add: [joker(big: true), joker(big: true), joker(big: false), joker(big: false)])
        case "euchre-24":
            return DeckSpec(base: "french-52", remove: CardModel.ranks(["2", "3", "4", "5", "6", "7", "8"]))
        case "euchre-25":
            return DeckSpec(base: "euchre-24", add: [joker(big: true)])
        case "piquet-32":
            return DeckSpec(base: "french-52", remove: CardModel.ranks(["2", "3", "4", "5", "6"]))
        case "pinochle-48":
            return DeckSpec(base: "euchre-24", copies: 2)
        case "pinochle-80":
            return DeckSpec(base: "euchre-24", copies: 4, remove: CardModel.ranks(["9"]))
        case "bezique-64":
            return DeckSpec(base: "piquet-32", copies: 2)
        case "doko-48":
            return DeckSpec(base: "euchre-24", copies: 2)
        case "doko-40":
            return DeckSpec(base: "euchre-24", copies: 2, remove: CardModel.ranks(["9"]))
        case "german-32":
            return germanDeck(ranks: ["7", "8", "9", "10", "U", "O", "K", "A"])
        case "german-24":
            return germanDeck(ranks: ["9", "10", "U", "O", "K", "A"])
        case "swiss-36":
            return swissDeck(ranks: ["6", "7", "8", "9", "10", "U", "O", "K", "A"])
        case "french-36":
            return DeckSpec(base: "french-52", remove: CardModel.ranks(["2", "3", "4", "5"]))
        case "spanish-40":
            return DeckSpec(base: "french-52", remove: spanishReplacements(stripped: false))
        case "spanish-48":
            return DeckSpec(base: "french-52", remove: spanishReplacements(stripped: true))
        case "italian-40":
            return DeckSpec(base: "french-52", remove: italianReplacements())
        case "tarot-78":
            return tarotDeck(suitRanks: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Kn", "Q", "K"],
                             trumpCount: 21)
        case "tarock-54":
            return tarotDeck(suitRanks: ["7", "8", "9", "10", "J", "Q", "K", "A"], trumpCount: 21)
        case "custom":
            return nil
        default:
            return nil
        }
    }

    /// Resolve a spec to its face list (one entry per physical card).
    public static func resolve(_ spec: DeckSpec) -> [CardFace] {
        let base: [CardFace]
        switch spec.base {
        case nil:
            base = []
        case "french-52":
            base = french(suits: [.spades, .hearts, .diamonds, .clubs],
                          ranks: ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"])
        case "piquet-32":
            base = french(suits: [.spades, .hearts, .diamonds, .clubs],
                          ranks: ["A", "K", "Q", "J", "10", "9", "8", "7"])
        case "euchre-24":
            base = french(suits: [.spades, .hearts, .diamonds, .clubs],
                          ranks: ["A", "K", "Q", "J", "10", "9"])
        default:
            // Bases referencing other deck IDs are not allowed (specs are flat).
            base = []
        }
        var cards = Array(repeating: base, count: max(1, spec.copies)).flatMap { $0 }
        if !spec.remove.isEmpty { cards.removeAll { spec.remove.contains($0.id) } }
        cards.append(contentsOf: spec.add)
        return cards
    }

    // MARK: - Builders

    static func joker(big: Bool) -> CardFace {
        CardFace(suit: nil, rank: big ? .jokerBig : .jokerLittle)
    }

    static func french(suits: [Suit], ranks: [String]) -> [CardFace] {
        suits.flatMap { suit in ranks.map { CardFace(suit: suit, rank: Rank($0)) } }
    }

    static func facesOf(system: SuitSystem, ranks: [String]) -> [String] {
        let suits: [String]
        switch system {
        case .french: suits = ["S", "H", "D", "C"]
        case .german: suits = ["Ei", "Gr", "Hz", "Sc"]
        case .swiss: suits = ["Sc", "Ro", "Sh", "Ei"]
        case .latinSpanish: suits = ["Or", "Co", "Es", "Ba"]
        case .latinItalian: suits = ["Co", "De", "Sp", "Ba"]
        case .tarot: suits = ["T"]
        }
        return suits.flatMap { s in ranks.map { r in CardFace.identifier(suit: Suit(s), rank: Rank(r)) } }
    }

    static func germanDeck(ranks: [String]) -> DeckSpec {
        let faces = ["Ei", "Gr", "Hz", "Sc"].flatMap { s in ranks.map { r in CardFace(suit: Suit(s), rank: Rank(r)) } }
        return DeckSpec(base: nil, add: faces)
    }

    static func swissDeck(ranks: [String]) -> DeckSpec {
        let faces = ["Sc", "Ro", "Sh", "Ei"].flatMap { s in ranks.map { r in CardFace(suit: Suit(s), rank: Rank(r)) } }
        return DeckSpec(base: nil, add: faces)
    }

    static func spanishReplacements(stripped: Bool) -> [String] {
        // Remove all French faces; replacements are added by `faces(for:)`.
        return facesOf(system: .french, ranks: ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"])
    }

    static func spanishFaces(stripped: Bool) -> [CardFace] {
        let ranks = stripped ? ["1", "2", "3", "4", "5", "6", "7", "8", "9", "S", "C", "R"]
                             : ["1", "2", "3", "4", "5", "6", "7", "S", "C", "R"]
        return ["Or", "Co", "Es", "Ba"].flatMap { s in ranks.map { r in CardFace(suit: Suit(s), rank: Rank(r)) } }
    }

    static func italianReplacements() -> [String] {
        facesOf(system: .french, ranks: ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"])
    }

    static func italianFaces() -> [CardFace] {
        ["1", "2", "3", "4", "5", "6", "7", "F", "C", "R"].flatMap { r in
            ["Co", "De", "Sp", "Ba"].map { s in CardFace(suit: Suit(s), rank: Rank(r)) }
        }
    }

    static func tarotDeck(suitRanks: [String], trumpCount: Int) -> DeckSpec {
        var faces = ["S", "H", "D", "C"].flatMap { s in suitRanks.map { r in CardFace(suit: Suit(s), rank: Rank(r)) } }
        faces += (1...trumpCount).map { CardFace(suit: .trumps, rank: Rank.trump($0)) }
        faces.append(CardFace(suit: nil, rank: .fool))
        return DeckSpec(base: nil, add: faces)
    }

    /// Public one-shot builders used by the Spanish and Italian specs above.
    public static func faces(for id: String) -> [CardFace]? {
        guard let spec = spec(for: id) else { return nil }
        var cards = resolve(spec)
        switch id {
        case "spanish-40", "spanish-48":
            cards = spanishFaces(stripped: id == "spanish-48")
        case "italian-40":
            cards = italianFaces()
        default:
            break
        }
        return cards
    }
}

/// Rank helpers used by the catalogue specs.
enum CardModel {
    static func ranks(_ codes: [String]) -> [String] {
        let suits = ["S", "H", "D", "C"]
        return suits.flatMap { s in codes.map { r in CardFace.identifier(suit: Suit(s), rank: Rank(r)) } }
    }
}
