// NativeTests+Rummy.swift — rummy.melds fixed cases and faults (P2.4).

import RulesetKit
import Testing

extension NativeTests {
    // MARK: - rummy.melds: fixed cases

    /// The native returns card lists; sort ids alphabetically for
    /// readable expectations.
    func meldGroups(_ deck: [String], rules: Value) throws -> (melds: [[String]], deadwood: Int) {
        let result = try Self.call("rummy.melds", [Self.cards(deck), rules])
        let parts = Self.meldParts(result)
        return (parts.melds.map { $0.sorted() }, parts.deadwood)
    }

    @Test func meldsFixedCases() throws {
        // Three fives are a set; 6-7 unsuited stay dead (13 points).
        var result = try meldGroups(["5H", "5D", "5S", "6C", "7C"], rules: Self.rummyRules())
        #expect(result.melds == [["5D", "5H", "5S"]])
        #expect(result.deadwood == 13)

        // The six and seven of clubs complete a second meld.
        result = try meldGroups(["5H", "5D", "5S", "6C", "7C", "8C"], rules: Self.rummyRules())
        #expect(result.melds == [["5D", "5H", "5S"], ["6C", "7C", "8C"]])
        #expect(result.deadwood == 0)

        // A four-card run beats leaving one behind: 5H-8H all melded.
        result = try meldGroups(["5H", "6H", "7H", "8H"], rules: Self.rummyRules())
        #expect(result.melds == [["5H", "6H", "7H", "8H"]])
        #expect(result.deadwood == 0)

        // A wild completes a set: 5-5 + wild two → deadwood 0.
        result = try meldGroups(["2C", "5D", "5S"], rules: Self.rummyRules(wildRanks: ["2"]))
        #expect(result.melds == [["2C", "5D", "5S"]])
        #expect(result.deadwood == 0)

        // Without enough naturals, minSet 4 cannot be met with one wild.
        result = try meldGroups(["2C", "5D", "5S"], rules: Self.rummyRules(minSet: 4, wildRanks: ["2"]))
        #expect(result.melds == [])
        #expect(result.deadwood == 10)  // wilds are dead at face value 0

        // Dead wilds contribute nothing to deadwood.
        result = try meldGroups(["2H", "3D"], rules: Self.rummyRules(wildRanks: ["2"]))
        #expect(result.melds == [])
        #expect(result.deadwood == 3)

        // minRun 4 rejects a three-card run.
        result = try meldGroups(["5H", "6H", "7H"], rules: Self.rummyRules(minRun: 4))
        #expect(result.melds == [])
        #expect(result.deadwood == 18)

        // Wrap runs: Q-K-A melds only when wrap is on.
        result = try meldGroups(["QH", "KH", "AH"], rules: Self.rummyRules(wrap: true))
        #expect(result.melds == [["AH", "KH", "QH"]])
        #expect(result.deadwood == 0)
        result = try meldGroups(["QH", "KH", "AH"], rules: Self.rummyRules())
        #expect(result.melds == [])
        #expect(result.deadwood == 21)

        // Ace-high runs: Q-K-A of a suit melds only when the ace is high.
        result = try meldGroups(["QD", "KD", "AD"], rules: Self.rummyRules(aceHigh: true))
        #expect(result.melds == [["AD", "KD", "QD"]])
        #expect(result.deadwood == 0)
        result = try meldGroups(["QD", "KD", "AD"], rules: Self.rummyRules())
        #expect(result.melds == [])
        #expect(result.deadwood == 21)

        // A full board: heart run A-4, the four fives, club run 9-J; the
        // deuce of spades is dead. (A-5 run with three fives ties at the
        // same deadwood; the deterministic search reaches this one first.)
        result = try meldGroups(
            ["AH", "2H", "3H", "4H", "5H", "5S", "5D", "5C", "9C", "10C", "JC", "2S"],
            rules: Self.rummyRules()
        )
        #expect(
            result.melds == [
                ["2H", "3H", "4H", "AH"], ["5C", "5D", "5H", "5S"], ["10C", "9C", "JC"],
            ])
        #expect(result.deadwood == 2)
    }

    @Test func meldsFaults() throws {
        let hand = Self.cards(["5H", "5D", "5S"])
        // Rules must be a record with the right shape.
        #expect(Self.faultOf("rummy.melds", [hand, .int(3)]) != nil)
        #expect(Self.faultOf("rummy.melds", [hand, .record(name: "contract", fields: [:])]) != nil)
        // minSet/minRun below 3 or above 13.
        #expect(Self.faultOf("rummy.melds", [hand, Self.rummyRules(minSet: 2)]) != nil)
        #expect(Self.faultOf("rummy.melds", [hand, Self.rummyRules(minRun: 14)]) != nil)
        // Duplicate ids are ambiguous.
        #expect(Self.faultOf("rummy.melds", [Self.cards(["5H", "5H", "5D"]), Self.rummyRules()]) != nil)
        // Unorderable, non-wild rank.
        #expect(Self.faultOf("rummy.melds", [Self.cards(["5H", "XD", "5S"]), Self.rummyRules()]) != nil)
        // Too many cards for the meld search (cap is 17).
        let bigDeck = [
            "2C", "3C", "4C", "5C", "6C", "7C", "8C", "9C", "10C", "JC",
            "2D", "3D", "4D", "5D", "6D", "7D", "8D", "9D",
        ]
        #expect(bigDeck.count == 18)  // 18 distinct valid ids
        #expect(Self.faultOf("rummy.melds", [Self.cards(bigDeck), Self.rummyRules()]) != nil)
        // Wrong arg count.
        #expect(Self.faultOf("rummy.melds", [hand]) != nil)
    }

}
