// NativeTests+Cribbage.swift — cribbage natives: frozen vectors, famous anchors, and a 31-subset independent-scorer cross-check (P2.4).

import RulesetKit
import Testing

extension NativeTests {
    // MARK: - cribbage.handScore: frozen acceptance vectors

    @Test func handScoreFrozenVectors() throws {
        for (index, row) in CribbageTestData.cribRows.enumerated() {
            let score = try Self.call(
                "cribbage.handScore",
                [
                    Self.cards(row.hand), Self.card(row.starter), .bool(row.crib),
                ])
            guard case .int(let value) = score else {
                Issue.record("handScore returned \(score) for row \(index)")
                return
            }
            if Int(value) != row.score {
                Issue.record(
                    "row \(index) \(row.hand)+\(row.starter) crib=\(row.crib): got \(value), want \(row.score)")
                return
            }
        }
    }

    /// The famous hands, with the arithmetic worked out by hand.
    @Test func handScoreFamousAnchors() throws {
        // 29: three fives + nobs jack. Fifteens {5,J} ×3 = 6 pts? No — each
        // fifteen is 2 points: {5,J} three ways (3 hand fives) = 6, plus the
        // starter five gives a fourth five: {5,J} ×4 = 8 and {5,5,5} ×4 ways
        // = 8 → 16; pairs C(4,2) = 12; nobs (JH + starter 5H) = 1 → 29.
        var score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["5D", "5C", "5S", "JH"]), Self.card("5H"), .bool(false),
            ])
        #expect(score == .int(29))

        // 28: same shape, jack's suit ≠ starter suit → no nobs.
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["5D", "5C", "5S", "JD"]), Self.card("5H"), .bool(false),
            ])
        #expect(score == .int(28))

        // 24: 4-4-5-5 + 6. Fifteens {4,5,6} ×4 = 8; runs 4-5-6 with
        // multiplicities 2·2·1 → 4 runs of 3 = 12; pairs 2+2 = 4 → 24.
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["4D", "4C", "5D", "5C"]), Self.card("6H"), .bool(false),
            ])
        #expect(score == .int(24))

        // 24 again, fives and sixes doubled: fifteens 8, runs 4·3 = 12,
        // pairs 4 → 24.
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["5D", "5C", "6D", "6C"]), Self.card("4H"), .bool(false),
            ])
        #expect(score == .int(24))

        // 21: 4-4-5-6 + 4. Fifteens {4,5,6} ×3 = 6; runs 3·3 = 9 (three
        // fours); pairs C(3,2)·2 = 6 → 21.
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["4D", "4C", "5D", "6D"]), Self.card("4H"), .bool(false),
            ])
        #expect(score == .int(21))

        // 4: two pairs only (4-4-5-5 + 8: no fifteens, no run of three).
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["4D", "4C", "5D", "5C"]), Self.card("8H"), .bool(false),
            ])
        #expect(score == .int(4))

        // 0: A-2-6-10 + J. No fifteens (1+2+6+10=19; J pairs with nothing
        // to 15), no pairs, runs only of length two (A-2 and 10-J).
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["AC", "2C", "6C", "10D"]), Self.card("JC"), .bool(false),
            ])
        #expect(score == .int(0))

        // Flushes. Hand 2H 3H 4H 9H + 5S: fifteens 2+4+9 = 2; run
        // 2-3-4-5 = 4; four-card flush = 4 → 10 non-crib. As a crib the
        // four-card flush scores nothing → 2 + 4 = 6.
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["2H", "3H", "4H", "9H"]), Self.card("5S"), .bool(false),
            ])
        #expect(score == .int(10))

        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["2H", "3H", "4H", "9H"]), Self.card("5S"), .bool(true),
            ])
        #expect(score == .int(6))  // crib: four-card flush scores nothing

        // Five hearts as a crib (starter 6H): fifteens {6,9}, {2,4,9},
        // {2,3,4,6} = 6; run 2-3-4 = 3 (no five present); five-card
        // flush = 5 → 14.
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["2H", "3H", "4H", "9H"]), Self.card("6H"), .bool(true),
            ])
        #expect(score == .int(14))

        // Nobs: jack of clubs in hand, starter a club. One fifteen
        // (9+2+4) — the jack counts as ten, so 10+8+2+4 is not one —
        // gives 2 + 1 nobs = 3.
        score = try Self.call(
            "cribbage.handScore",
            [
                Self.cards(["JC", "9D", "8S", "2H"]), Self.card("4C"), .bool(false),
            ])
        #expect(score == .int(3))
    }

    @Test func handScoreFaults() throws {
        // Wrong arity.
        #expect(Self.faultOf("cribbage.handScore", [Self.cards(["5H", "5D", "5S", "JC"]), Self.card("5H")]) != nil)
        // Hand must be exactly four cards.
        #expect(
            Self.faultOf("cribbage.handScore", [Self.cards(["5H", "5D", "5S"]), Self.card("5H"), .bool(true)]) != nil)
        #expect(
            Self.faultOf(
                "cribbage.handScore",
                [
                    Self.cards(["5H", "5D", "5S", "JC", "2D"]), Self.card("5H"), .bool(true),
                ]) != nil)
        // Non-card list element.
        #expect(
            Self.faultOf(
                "cribbage.handScore", [.list([.int(1), .int(2), .int(3), .int(4)]), Self.card("5H"), .bool(true)])
                != nil)
        // Duplicate card ids are ambiguous.
        #expect(
            Self.faultOf("cribbage.handScore", [Self.cards(["5H", "5H", "5S", "JC"]), Self.card("5D"), .bool(true)])
                != nil)
        #expect(
            Self.faultOf(
                "cribbage.handScore",
                [
                    Self.cards(["5H", "5D", "5S", "JC"]), Self.card("5H"), .bool(true),
                ]) != nil)
        // Starter must be a card.
        #expect(
            Self.faultOf("cribbage.handScore", [Self.cards(["5H", "5D", "5S", "JC"]), .int(3), .bool(true)]) != nil)
    }

    // MARK: - cribbage.pegPoints: fixed cases

    @Test func pegPointsFixedCases() throws {
        // (cards, expected) — arithmetic worked out by hand.
        let cases: [(ids: [String], score: Int)] = [
            // Empty pile scores nothing.
            ([], 0),
            // A lone card can make a fifteen or pair with nothing.
            (["5H"], 0),
            // Pairs: 2, 6, 12 for two/three/four of a kind; the third five
            // also completes the fifteen 5+5+5, so 8 total.
            (["5H", "5D"], 2),
            (["5H", "5D", "5S"], 8),
            (["9H", "9D", "9S", "9C"], 12),
            // The jack makes the total 20 and creates nothing: the pair
            // was the second five's award.
            (["5H", "5D", "JH"], 0),
            // The jack makes 25 and creates nothing: the pairs were
            // earlier awards.
            (["5C", "5D", "5H", "JH"], 0),
            // Only the pair the last six forms: the {9,6} fifteen was
            // the first six's award.
            (["9H", "6S", "6D"], 2),
            // Fifteen (4+5+6) plus the three-card run; ace low.
            (["4S", "5H", "6D"], 5),
            (["AC", "2D", "3H"], 3),
            (["10H", "JH", "QH", "KH"], 4),
            // Doubled run 4-5-6 (two ways) = 6; the pair was the second
            // four's award and the total is 19.
            (["4S", "4D", "5H", "6C"], 6),
            // Q-K-A is not a run with the ace low.
            (["QC", "KD", "AH"], 0),
            // No fifteens (A+2+6+10=19, J pairs with nothing to 15), no
            // pairs, no run of three (A-2 and 10-J only).
            (["AC", "2C", "6C", "10D", "JC"], 0),
        ]
        for (index, testCase) in cases.enumerated() {
            let score = try Self.call("cribbage.pegPoints", [Self.cards(testCase.ids)])
            guard case .int(let value) = score else {
                Issue.record("pegPoints returned \(score) for case \(index)")
                return
            }
            #expect(Int(value) == testCase.score, "case \(index) \(testCase.ids)")
        }
    }

    @Test func pegPointsFaults() throws {
        #expect(Self.faultOf("cribbage.pegPoints", [.int(5)]) != nil)
        #expect(Self.faultOf("cribbage.pegPoints", [.list([.string("5H")])]) != nil)
        #expect(Self.faultOf("cribbage.pegPoints", []) != nil)
    }

    // MARK: - handScore: independent 31-subset cross-check (100k hands)

    /// Cribbage pip value: A=1, 2–10 face value, J/Q/K = 10.
    static func cribPip(_ id: String) -> Int {
        switch String(id.dropLast()) {
        case "A": return 1
        case "J", "Q", "K": return 10
        default: return Int(String(id.dropLast()))!
        }
    }

    /// Fifteens: 2 points for each subset of the five cards whose pips
    /// sum to 15.
    static func referenceFifteens(_ pips: [Int]) -> Int {
        var score = 0
        for mask in 1..<(1 << pips.count) {
            var sum = 0
            for (i, pip) in pips.enumerated() where mask & (1 << i) != 0 {
                sum += pip
            }
            if sum == 15 { score += 2 }
        }
        return score
    }

    /// Pairs: 2 points for each pair of cards of equal rank.
    static func referencePairs(_ cards: [String]) -> Int {
        var score = 0
        for i in 0..<cards.count {
            for j in i + 1..<cards.count
            where String(cards[i].dropLast()) == String(cards[j].dropLast()) {
                score += 2
            }
        }
        return score
    }

    /// Runs: over the multiset of ranks, every maximal consecutive span
    /// of length ≥ 3 scores length × Π(multiplicities).
    static func referenceRuns(_ cards: [String]) -> Int {
        var counts: [String: Int] = [:]
        for id in cards { counts[String(id.dropLast()), default: 0] += 1 }
        let aceLow = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
        var score = 0
        var runIndex = 0
        while runIndex < aceLow.count {
            if counts[aceLow[runIndex]] == nil {
                runIndex += 1
                continue
            }
            var end = runIndex
            while end + 1 < aceLow.count && counts[aceLow[end + 1]] != nil {
                end += 1
            }
            let length = end - runIndex + 1
            if length >= 3 {
                var multiplicity = 1
                for k in runIndex...end { multiplicity *= counts[aceLow[k]]! }
                score += length * multiplicity
            }
            runIndex = end + 1
        }
        return score
    }

    /// Flush: four hand cards of one suit; the starter's suit counts
    /// only outside the crib.
    static func referenceFlush(hand: [String], starter: String, isCrib: Bool) -> Int {
        let handSuits = Set(hand.map { $0.last! })
        guard handSuits.count == 1 else { return 0 }
        let matches = hand[0].last! == starter.last!
        if isCrib { return matches ? 5 : 0 }
        return matches ? 5 : 4
    }

    /// Nobs: a jack in the hand matching the starter's suit.
    static func referenceNobs(hand: [String], starter: String) -> Int {
        if hand.contains(where: { String($0.dropLast()) == "J" && $0.last! == starter.last! }) {
            return 1
        }
        return 0
    }

    /// Reference show scorer: fifteens by enumerating all 31 non-empty
    /// subsets; pairs, runs, flush and nobs by direct inspection. Written
    /// against the rules, not against the native's algorithm.
    static func referenceHandScore(
        _ hand: [String], starter: String, isCrib: Bool
    ) -> Int {
        let all = hand + [starter]
        let pips = all.map(cribPip)
        return referenceFifteens(pips)
            + referencePairs(all)
            + referenceRuns(all)
            + referenceFlush(hand: hand, starter: starter, isCrib: isCrib)
            + referenceNobs(hand: hand, starter: starter)
    }

    /// Deterministic LCG shuffle (same generator family as the vector
    /// tool), used to deal the cross-check hands.
    static func lcgDeal(seed: UInt64, deck: [String], take: Int) -> [String] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var pool = deck
        for i in stride(from: pool.count - 1, to: 0, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let j = Int((state >> 33) % UInt64(i + 1))
            pool.swapAt(i, j)
        }
        return Array(pool.prefix(take))
    }

    static let deck52: [String] = {
        let ranks = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"]
        let suits = ["C", "D", "H", "S"]
        return suits.flatMap { suit in ranks.map { $0 + suit } }
    }()

    @Test func handScoreMatchesIndependentScorer() throws {
        for seed in 1...100_000 {
            let dealt = Self.lcgDeal(seed: UInt64(seed), deck: Self.deck52, take: 5)
            let hand = Array(dealt.prefix(4))
            let starter = dealt[4]
            let isCrib = seed % 2 == 0
            let expected = Self.referenceHandScore(hand, starter: starter, isCrib: isCrib)
            let value = try Self.call(
                "cribbage.handScore",
                [
                    Self.cards(hand), Self.card(starter), .bool(isCrib),
                ])
            guard case .int(let actual) = value else {
                Issue.record("seed \(seed): handScore returned \(value)")
                return
            }
            if Int(actual) != expected {
                Issue.record("seed \(seed): hand \(hand)+\(starter) crib=\(isCrib): got \(actual), want \(expected)")
                return
            }
        }
    }

}
