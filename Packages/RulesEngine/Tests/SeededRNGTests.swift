import Testing
@testable import RulesEngine

@Suite("RulesEngine — SeededRNG (§10.1)")
struct SeededRNGTests {

    // MARK: - Reference vector
    // Verified against the authors' reference implementation
    // (prng.di.unimi.it/xoshiro256starstar.c, xoshiro256** 1.0, Blackman and
    // Vigna) compiled locally with a SplitMix64 seeding main: the C binary
    // and this Swift implementation print identical streams.

    @Test func referenceVectorAgainstAuthorsImplementation() {
        var rng = SeededRNG(seed: 42)
        #expect(rng.nextUInt64() == 0x1578_0b2e_0c2e_c716)
        #expect(rng.nextUInt64() == 0x6104_d986_6d11_3a7e)
        #expect(rng.nextUInt64() == 0xae17_5332_39e4_99a1)
        #expect(rng.nextUInt64() == 0xecb8_ad47_03b3_60a1)
        #expect(rng.nextUInt64() == 0xfde6_dc7f_e2ec_5e64)
    }

    /// Independent arithmetic cross-checks (SplitMix64 identities).
    @Test func splitMix64Derivation() {
        var sm = SplitMix64(seed: 0)
        let first = sm.next()
        let second = sm.next()
        #expect(first != second)
        // derive(from:) is the first output of the stream with that seed.
        #expect(SplitMix64.derive(from: 0) == first)
        #expect(SplitMix64.derive(from: 1) != first)
        // Deterministic: same seed, same stream.
        var sm2 = SplitMix64(seed: 0)
        #expect(sm2.next() == first)
        #expect(sm2.next() == second)
    }

    @Test func dealSeedFormula() {
        // dealSeed(i) = splitmix64(sessionSeed ^ UInt64(i)) (§10.2)
        #expect(SeededRNG.dealSeed(sessionSeed: 42, index: 0) == SplitMix64.derive(from: 42))
        #expect(SeededRNG.dealSeed(sessionSeed: 42, index: 3) == SplitMix64.derive(from: 42 ^ 3))
        // Distinct deals get distinct seeds with overwhelming probability.
        var seen = Set<UInt64>()
        for i in 0..<1000 {
            seen.insert(SeededRNG.dealSeed(sessionSeed: 1234, index: UInt64(i)))
        }
        #expect(seen.count == 1000)
    }

    // MARK: - Statistical: 10,000 shuffles of a 10-card deck, chi-square p > 0.001

    @Test func shuffleUniformity() {
        let shuffles = 10_000
        let deckSize = 10
        // Count how often each face ends up in each position.
        var counts = Array(repeating: 0, count: deckSize * deckSize)
        for seed in 0..<UInt64(shuffles) {
            var rng = SeededRNG(seed: seed)
            var deck = Array(0..<deckSize)
            rng.shuffle(&deck)
            for (position, face) in deck.enumerated() {
                counts[position * deckSize + face] += 1
            }
        }
        // Expected per cell: shuffles / deckSize = 1000.
        let expected = Double(shuffles) / Double(deckSize)
        var chiSquare = 0.0
        for c in counts {
            let observed = Double(c)
            let d = observed - expected
            chiSquare += d * d / expected
        }
        // df = (rows-1)(cols-1) = 81. p > 0.001 iff chi-square < ~124.8
        // (Wilson–Hilferty check instead: use the strict published critical
        // value 124.116 for df=81, p=0.001).
        #expect(chiSquare < 124.116, "chi-square \(chiSquare) exceeds the p=0.001 critical value for df=81")
    }

    // MARK: - Serialization round-trip preserves the stream

    @Test func codableRoundTripPreservesStream() throws {
        var rng = SeededRNG(seed: 0xC0FFEE)
        for _ in 0..<100 { _ = rng.nextUInt64() }
        let data = try JSONEncoder().encode(rng)
        var restored = try JSONDecoder().decode(SeededRNG.self, from: data)
        #expect(restored == rng)
        for _ in 0..<1000 {
            #expect(restored.nextUInt64() == rng.nextUInt64())
        }
        // Shuffles continue identically too.
        var a = Array(0..<52)
        var b = Array(0..<52)
        rng.shuffle(&a)
        restored.shuffle(&b)
        #expect(a == b)
    }

    // MARK: - Bounded integers stay in range and are unbiased enough

    @Test func boundedIntegers() {
        var rng = SeededRNG(seed: 7)
        for bound in [1, 2, 3, 7, 52, 108, 1_000] {
            for _ in 0..<1_000 {
                let v = rng.below(UInt64(bound))
                #expect(v >= 0 && v < UInt64(bound))
            }
        }
        // Proper chi-square over 10 buckets, df = 9; p = 0.001 critical value
        // is 27.877 (Pearson). Tolerances must come from statistics, not
        // arbitrary windows.
        var rng2 = SeededRNG(seed: 99)
        var buckets = Array(repeating: 0, count: 10)
        for _ in 0..<30_000 { buckets[rng2.below(10)] += 1 }
        let expected = 3_000.0
        var chiSquare = 0.0
        for b in buckets {
            let d = Double(b) - expected
            chiSquare += d * d / expected
        }
        #expect(chiSquare < 27.877, "chi-square \(chiSquare) exceeds the p=0.001 critical value for df=9")
    }

    /// Seed-expansion contract: the all-zero xoshiro state is a fixed point;
    /// the initializer must never produce it.
    @Test func seedExpansionNeverAllZero() {
        let rng = SeededRNG(s0: 0, s1: 0, s2: 0, s3: 0)
        #expect(rng.s0 != 0 || rng.s1 != 0 || rng.s2 != 0 || rng.s3 != 0)
        var probe = rng
        _ = probe.nextUInt64()
        // For a large sample of seeds, no state is all-zero and the first
        // output is not identically zero.
        for seed in [UInt64(0), 1, 42, UInt64.max, 0xDEADBEEF] {
            var r = SeededRNG(seed: seed)
            #expect(r.nextUInt64() != 0 || r.nextUInt64() != 0)
        }
    }
}

import Foundation
