// NativeTests+Bridge.swift — bridge natives: frozen score table, hand-checked contracts, honors (P2.4).

import RulesetKit
import Testing

extension NativeTests {
    // MARK: - bridge.score: frozen table + fixed contracts

    @Test func bridgeScoreFrozenTable() throws {
        for (index, row) in BridgeTestData.bridgeRows.enumerated() {
            let result = try Self.call(
                "bridge.score",
                [
                    Self.contractValue(level: row.level, strain: row.strain, dbl: row.dbl),
                    .int(Int64(row.tricks)),
                    .bool(row.vul),
                    .string(row.mode),
                ])
            let parts = Self.bridgeParts(result)
            if parts.below != row.below || parts.above != row.above
                || parts.defenders != row.defenders || parts.total != row.below + row.above
            {
                // Single interpolated literal: Issue.record takes Comment?,
                // which string literals convert to but String values do not.
                let label = "\(row.mode) \(row.level)\(row.strain) d=\(row.dbl) v=\(row.vul) t=\(row.tricks)"
                let got = "(\(parts.below), \(parts.above), \(parts.defenders), \(parts.total))"
                let want = "(\(row.below), \(row.above), \(row.defenders), \(row.below + row.above))"
                Issue.record("row \(index) \(label): got \(got), want \(want)")
                return
            }
        }
    }

    /// Hand-checked contracts covering each line of the table.
    @Test func bridgeScoreKeyContracts() throws {
        /// Contract under test; the expected outcome is a (below, above,
        /// defenders, total) tuple checked line by line against the table.
        struct Contract {
            let level: Int
            let strain: String
            let dbl: Int
            let vul: Bool
        }
        func score(_ contract: Contract, _ tricks: Int, _ mode: String) throws -> (Int, Int, Int, Int) {
            do {
                let parts = Self.bridgeParts(
                    try Self.call(
                        "bridge.score",
                        [
                            Self.contractValue(level: contract.level, strain: contract.strain, dbl: contract.dbl),
                            .int(Int64(tricks)), .bool(contract.vul), .string(mode),
                        ]))
                return (parts.below, parts.above, parts.defenders, parts.total)
            } catch let fault as EvaluationFault {
                Issue.record("score fault: kind=\(fault.kind) pointer=\(fault.pointer) msg=\(fault.message)")
                return (-1, -1, -1, -1)
            }
        }

        // 4S making exactly, not vul: trick score 120 all below.
        #expect(try score(Contract(level: 4, strain: "S", dbl: 0, vul: false), 10, "rubber") == (120, 0, 0, 120))
        // 2H doubled making: below 120 = 60 trick score doubled; insult 50
        // above. Rubber has no per-deal game bonus: BRG-5.1 makes a game a
        // below-line accumulation in the match store.
        #expect(try score(Contract(level: 2, strain: "H", dbl: 1, vul: false), 8, "rubber") == (120, 50, 0, 170))
        // Same contract not doubled: 60 below, no bonus.
        #expect(try score(Contract(level: 2, strain: "H", dbl: 0, vul: false), 8, "rubber") == (60, 0, 0, 60))
        // 3NT making: 100 below; no per-deal game bonus in rubber.
        #expect(try score(Contract(level: 3, strain: "NT", dbl: 0, vul: false), 9, "rubber") == (100, 0, 0, 100))
        // 3NT chicago non-vul: partscore would be 50 but 100 ≥ 100 → 300.
        #expect(try score(Contract(level: 3, strain: "NT", dbl: 0, vul: false), 9, "chicago") == (100, 300, 0, 400))
        // Small slam: level 6 bonus 500 non-vul.
        #expect(try score(Contract(level: 6, strain: "S", dbl: 0, vul: false), 12, "rubber") == (180, 500, 0, 680))
        // Grand slam vulnerable: 1500 bonus.
        #expect(try score(Contract(level: 7, strain: "NT", dbl: 0, vul: true), 13, "rubber") == (220, 1500, 0, 1720))
        // Overtricks are strain-specific: NT overtricks 30 each.
        #expect(try score(Contract(level: 1, strain: "NT", dbl: 0, vul: false), 8, "rubber") == (40, 30, 0, 70))
        // Doubled undertricks: 5C down 6 non-vul = 100+200+200+300+300+300.
        #expect(try score(Contract(level: 5, strain: "C", dbl: 1, vul: false), 5, "rubber") == (0, 0, 1400, 0))
        // Redoubled doubles it.
        #expect(try score(Contract(level: 5, strain: "C", dbl: 2, vul: false), 5, "rubber") == (0, 0, 2800, 0))
        // Vulnerable doubled: 200 + 300×5.
        #expect(try score(Contract(level: 5, strain: "C", dbl: 1, vul: true), 5, "rubber") == (0, 0, 1700, 0))
        // Undoubled undertricks: 50 each non-vul, 100 vul. Down 3 = 11
        // needed, 8 made.
        #expect(try score(Contract(level: 5, strain: "C", dbl: 0, vul: false), 8, "rubber") == (0, 0, 150, 0))
        #expect(try score(Contract(level: 5, strain: "C", dbl: 0, vul: true), 8, "rubber") == (0, 0, 300, 0))
    }

    @Test func bridgeScoreFaults() throws {
        let contract = Self.contractValue(level: 4, strain: "S", dbl: 0)
        // Wrong arg counts and types.
        #expect(Self.faultOf("bridge.score", [contract, .int(10), .bool(false)]) != nil)
        #expect(Self.faultOf("bridge.score", [contract, .string("10"), .bool(false), .string("rubber")]) != nil)
        #expect(Self.faultOf("bridge.score", [contract, .int(10), .bool(false), .int(7)]) != nil)
        // Not a contract record.
        #expect(Self.faultOf("bridge.score", [Self.rummyRules(), .int(10), .bool(false), .string("rubber")]) != nil)
        // Level outside 1...7, tricks outside 0...13, unknown mode.
        func bad(_ contract: Value, _ tricks: Int64) -> Bool {
            Self.faultOf("bridge.score", [contract, .int(tricks), .bool(false), .string("rubber")]) != nil
        }
        #expect(bad(Self.contractValue(level: 0, strain: "S", dbl: 0), 10))
        #expect(bad(Self.contractValue(level: 8, strain: "S", dbl: 0), 10))
        #expect(bad(contract, 14))
        #expect(bad(contract, -1))
        #expect(Self.faultOf("bridge.score", [contract, .int(10), .bool(false), .string("chicagoan")]) != nil)
    }

    // MARK: - bridge.honors

    func honors(
        _ hands: [[String]], _ trump: String?, _ team: String,
        teams: [Value] = [.string("NS"), .string("EW")]
    ) throws -> Int {
        let result = try Self.call(
            "bridge.honors",
            [
                .list(hands.map(Self.cards)), trump.map { .string($0) } ?? .null,
                .string(team),
            ], teams: teams)
        guard case .int(let value) = result else {
            fatalError("honors returned \(result)")
        }
        return Int(value)
    }

    @Test func honorsFixedCases() throws {
        // Four trump honors for NS: split 2-2 across N and S.
        var value = try honors(
            [["KS", "QS"], ["2H", "3H"], ["JS", "10S"], ["2D", "3D"]],
            "S", "NS"
        )
        #expect(value == 100)

        // Five honors → 150.
        value = try honors(
            [["KS", "QS", "AS"], ["2H", "3H"], ["JS", "10S"], ["2D", "3D"]],
            "S", "NS"
        )
        #expect(value == 150)

        // Two honors → nothing.
        value = try honors(
            [["KS", "QS"], ["2H", "3H"], ["4D", "5D"], ["2D", "3D"]],
            "S", "NS"
        )
        #expect(value == 0)

        // Five trump honors total: NS holds one, EW four.
        let split = [["QS"], ["JS", "10S", "AS"], ["2H", "3H"], ["KS"]]
        #expect(try honors(split, "S", "NS") == 0)
        #expect(try honors(split, "S", "EW") == 100)

        // Notrump: aces only; all four → 150.
        #expect(
            try honors(
                [["AC", "AD"], ["2H", "3H"], ["AH", "AS"], ["2D", "3D"]],
                nil, "NS"
            ) == 150)
        #expect(
            try honors(
                [["AC", "AD"], ["2H", "3H"], ["AH", "4H"], ["2D", "3D"]],
                nil, "NS"
            ) == 0)

        // Team membership is by seat parity: honors in E and W count for EW.
        #expect(
            try honors(
                [["2H", "3H"], ["KS", "QS", "JS", "10S"], ["2D", "3D"], ["4H", "5H"]],
                "S", "EW"
            ) == 100)

        // Empty hands score nothing.
        #expect(try honors([[], [], [], []], "S", "NS") == 0)
    }
    @Test func honorsFaults() throws {
        let hands: Value = .list([
            Self.cards(["KS", "QS"]), Self.cards(["2H", "3H"]),
            Self.cards(["JS", "10S"]), Self.cards(["2D", "3D"]),
        ])
        let teams: [Value] = [.string("NS"), .string("EW")]
        func honorsBad(_ args: [Value]) -> Bool {
            Self.faultOf("bridge.honors", args, teams: teams) != nil
        }
        // Team not installed in the host table.
        #expect(Self.faultOf("bridge.honors", [hands, .string("S"), .string("E")], teams: teams) != nil)
        #expect(Self.faultOf("bridge.honors", [hands, .string("S"), .string("NS")], teams: teams) == nil)
        // Not four hands.
        #expect(
            honorsBad([
                .list([Self.cards(["KS"]), Self.cards(["QS"]), Self.cards(["JS"])]), .string("S"), .string("NS"),
            ]))
        // Four elements but a flat card list, not a list of hands.
        #expect(honorsBad([Self.cards(["KS", "QS", "JS", "10S"]), .string("S"), .string("NS")]))
        // Trump must be a suit string.
        #expect(honorsBad([hands, .string("X"), .string("NS")]))
        #expect(honorsBad([hands, .int(4), .string("NS")]))
        // Hands must contain cards.
        #expect(
            honorsBad([
                .list([.list([.int(1)]), Self.cards(["H2"]), Self.cards(["H3"]), Self.cards(["H4"])]),
                .string("S"), .string("NS"),
            ]))
    }

}
