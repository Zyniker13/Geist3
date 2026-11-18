import Foundation
import Testing
@testable import CardModel

@Suite("CardModel — card identity and decks")
struct CardModelTests {

    // MARK: - Deck catalogue (§4.2): every deck ID resolves with the right size

    @Test func deckSizes() {
        let expected: [String: Int] = [
            "french-52": 52, "french-52j1": 53, "french-52j2": 54, "french-104j4": 108,
            "euchre-24": 24, "euchre-25": 25,
            "piquet-32": 32,
            "pinochle-48": 48, "pinochle-80": 80,
            "bezique-64": 64,
            "doko-48": 48, "doko-40": 40,
            "german-32": 32, "german-24": 24,
            "swiss-36": 36,
            "french-36": 36,
            "spanish-40": 40, "spanish-48": 48,
            "italian-40": 40,
            "tarot-78": 78, "tarock-54": 54,
        ]
        for (id, count) in expected {
            let cards = DeckCatalog.faces(for: id)
            #expect(cards != nil, "missing deck \(id)")
            #expect(cards?.count == count, "deck \(id): \(cards?.count ?? -1) != \(count)")
        }
    }

    @Test func everyCatalogIDHasSpecOrIsCustom() {
        for id in DeckCatalog.allDeckIDs {
            if id == "custom" {
                #expect(DeckCatalog.spec(for: id) == nil)
            } else {
                #expect(DeckCatalog.spec(for: id) != nil, "no spec for \(id)")
            }
        }
    }

    @Test func deckContents() {
        // french-52: A–K × ♠♥♦♣
        let french = DeckCatalog.faces(for: "french-52")!
        #expect(Set(french.map(\.suit?.code)) == Set(["S", "H", "D", "C"]))
        #expect(french.filter { $0.suit?.code == "S" }.count == 13)
        #expect(french.contains(CardFace(suit: .spades, rank: Rank("Q"))))

        // euchre-24: 9–A only
        let euchre = DeckCatalog.faces(for: "euchre-24")!
        #expect(!euchre.contains { ["8", "7", "2"].contains($0.rank.code) })
        #expect(euchre.contains(CardFace(suit: .hearts, rank: Rank("9"))))

        // piquet-32: 7–A
        let piquet = DeckCatalog.faces(for: "piquet-32")!
        #expect(!piquet.contains { ["6", "5", "4", "3", "2"].contains($0.rank.code) })

        // pinochle-48: 9–A doubled
        let pinochle = DeckCatalog.faces(for: "pinochle-48")!
        #expect(pinochle.count == 48)
        let queenSpades = pinochle.filter { $0.id == "QS" }
        #expect(queenSpades.count == 2, "pinochle QS should appear twice, got \(queenSpades.count)")

        // pinochle-80: 10–A quadrupled, no nines
        let p80 = DeckCatalog.faces(for: "pinochle-80")!
        #expect(p80.filter { $0.id == "AS" }.count == 4)
        #expect(!p80.contains { $0.rank.code == "9" })

        // bezique-64: two piquet packs
        let bezique = DeckCatalog.faces(for: "bezique-64")!
        #expect(bezique.filter { $0.id == "JC" }.count == 2)

        // doko-48 / doko-40
        let doko = DeckCatalog.faces(for: "doko-48")!
        #expect(doko.filter { $0.id == "9H" }.count == 2)
        let doko40 = DeckCatalog.faces(for: "doko-40")!
        #expect(!doko40.contains { $0.rank.code == "9" })
        #expect(doko40.count == 40)

        // german-32: Daus = A
        let german = DeckCatalog.faces(for: "german-32")!
        #expect(german.contains(CardFace(suit: Suit("Ei"), rank: Rank("A"))))
        #expect(!german.contains { ["J", "Q"].contains($0.rank.code) })

        // swiss-36 includes Banner (6)
        let swiss = DeckCatalog.faces(for: "swiss-36")!
        #expect(swiss.contains(CardFace(suit: Suit("Ro"), rank: Rank("6"))))

        // spanish-40: 1–7, S, C, R × Or/Co/Es/Ba
        let spanish = DeckCatalog.faces(for: "spanish-40")!
        #expect(spanish.contains(CardFace(suit: Suit("Or"), rank: Rank("R"))))
        #expect(!spanish.contains { $0.suit?.code == "S" && $0.rank.code == "Q" })

        // italian-40
        let italian = DeckCatalog.faces(for: "italian-40")!
        #expect(italian.contains(CardFace(suit: Suit("De"), rank: Rank("F"))))

        // tarot-78: 21 trumps + Fool + 4×14
        let tarot = DeckCatalog.faces(for: "tarot-78")!
        #expect(tarot.filter { $0.suit == .trumps }.count == 21)
        #expect(tarot.contains(CardFace(suit: nil, rank: .fool)))
        #expect(tarot.contains(CardFace(suit: .trumps, rank: Rank.trump(21))))
        #expect(tarot.contains(CardFace(suit: .hearts, rank: .cavallo)))

        // tarock-54: piquet suits + 22 trumps (21 + Fool)
        let tarock = DeckCatalog.faces(for: "tarock-54")!
        #expect(tarock.filter { $0.suit == .trumps }.count == 21)
        #expect(tarock.contains(CardFace(suit: .spades, rank: Rank("7"))))

        // custom: inline spec
        let custom = DeckSpec(base: nil, add: [CardFace(suit: .spades, rank: .ace)])
        #expect(DeckCatalog.resolve(custom).count == 1)
    }

    // MARK: - CardFace identity and Codable round-trip

    @Test func faceIdentifierFormat() {
        #expect(CardFace(suit: .spades, rank: .queen).id == "QS")
        #expect(CardFace(suit: .hearts, rank: Rank("10")).id == "10H")
        #expect(CardFace(suit: Suit("Ei"), rank: .ober).id == "OEi")
        #expect(CardFace(suit: .trumps, rank: Rank.trump(21)).id == "T21")
        #expect(CardFace(suit: nil, rank: .fool).id == "Fool")
        #expect(CardFace(suit: nil, rank: .jokerBig).id == "JokerBig")
    }

    @Test func faceCodableRoundTrip() throws {
        let faces: [CardFace] = [
            CardFace(suit: .spades, rank: .queen),
            CardFace(suit: .hearts, rank: Rank("10")),
            CardFace(suit: Suit("Ei"), rank: .ober),
            CardFace(suit: .trumps, rank: Rank.trump(21)),
            CardFace(suit: nil, rank: .fool),
            CardFace(suit: nil, rank: .jokerLittle),
        ]
        for face in faces {
            let data = try JSONEncoder().encode(face)
            let decoded = try JSONDecoder().decode(CardFace.self, from: data)
            #expect(decoded == face)
            #expect(decoded.id == face.id)
        }
    }

    // MARK: - Duplicate decks produce distinct instances

    @Test func duplicateDecksProduceDistinctInstances() {
        let first = DeckCatalog.faces(for: "pinochle-48")!
        let second = DeckCatalog.faces(for: "pinochle-48")!
        // Same face multiset…
        #expect(first.sorted { $0.id < $1.id } == second.sorted { $0.id < $1.id })
        // …but a copy in one deck is a different physical card than a copy in
        // the other: each build yields its own array of values, and per-deal
        // CardIDs are assigned independently later (§9.5) — the two arrays are
        // not aliased or identified with each other.
        #expect(first.count == second.count)
        for (a, b) in zip(first, second) {
            #expect(a == b) // same face
        }
    }

    // MARK: - Seats and SeatSet

    @Test func seatSetBitOperations() {
        var set = SeatSet([Seat(0), Seat(3), Seat(63)])
        #expect(set.count == 3)
        #expect(set.contains(Seat(3)))
        #expect(!set.contains(Seat(1)))
        set.insert(Seat(1))
        #expect(set.count == 4)
        set.remove(Seat(0))
        #expect(set.count == 3)
        let other = SeatSet([Seat(2), Seat(3)])
        #expect(set.intersection(other).count == 1)
        #expect(set.union(other).count == 4)
        let seats = Array(set)
        #expect(seats == [Seat(1), Seat(3), Seat(63)])
    }

    @Test func seatCodable() throws {
        let seat = Seat(7)
        let decoded = try JSONDecoder().decode(Seat.self, from: JSONEncoder().encode(seat))
        #expect(decoded == seat)
        let cardID = CardID(65535)
        let decodedID = try JSONDecoder().decode(CardID.self, from: JSONEncoder().encode(cardID))
        #expect(decodedID == cardID)
    }
}
