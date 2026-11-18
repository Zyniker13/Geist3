import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

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
        // Expected per cell: shuffles / deckSize = 1000 (exact integer).
        let expected = shuffles / deckSize
        // chi-square = sum((O - E)^2) / E. With E = 1000 the comparison is
        // exact in integers: chi-square < 124.116 (df = 81, p = 0.001) is
        // equivalent to sum((O - E)^2) < 124_116.
        var squaredDeviationSum = 0
        for cell in counts {
            let delta = cell - expected
            squaredDeviationSum += delta * delta
        }
        #expect(
            squaredDeviationSum < 124_116,
            "chi-square \(squaredDeviationSum / expected) exceeds the p=0.001 critical value for df=81")
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
        var deckA = Array(0..<52)
        var deckB = Array(0..<52)
        rng.shuffle(&deckA)
        restored.shuffle(&deckB)
        #expect(deckA == deckB)
    }

    // MARK: - Bounded integers stay in range and are unbiased enough

    @Test func boundedIntegers() {
        var rng = SeededRNG(seed: 7)
        for bound in [1, 2, 3, 7, 52, 108, 1_000] {
            for _ in 0..<1_000 {
                let value = rng.below(UInt64(bound))
                #expect(value >= 0 && value < UInt64(bound))
            }
        }
        // Proper chi-square over 10 buckets, df = 9; p = 0.001 critical value
        // is 27.877 (Pearson). Tolerances must come from statistics, not
        // arbitrary windows. E = 3000, so χ² < 27.877 ⟺ Σ(O−E)² < 83631.
        var rng2 = SeededRNG(seed: 42)
        var buckets = Array(repeating: 0, count: 10)
        for _ in 0..<30_000 { buckets[rng2.below(10)] += 1 }
        var chiSqNum: Int64 = 0  // Σ(Oᵢ − E)² × 1000 (scaled by 1000 to avoid float)
        for bucket in buckets {
            let diff = Int64(bucket) - 3000
            chiSqNum += diff * diff * 1000
        }
        #expect(chiSqNum < 27_877_000, "chi-square exceeds the p=0.001 critical value for df=9")
    }

    /// Seed-expansion contract: the all-zero xoshiro state is a fixed point;
    /// the initializer must never produce it.
    @Test func seedExpansionNeverAllZero() {
        let rng = SeededRNG(lane0: 0, lane1: 0, lane2: 0, lane3: 0)
        #expect(rng.lane0 != 0 || rng.lane1 != 0 || rng.lane2 != 0 || rng.lane3 != 0)
        var probe = rng
        _ = probe.nextUInt64()
        // For a large sample of seeds, no state is all-zero and the first
        // output is not identically zero.
        for seed in [UInt64(0), 1, 42, UInt64.max, 0xDEAD_BEEF] {
            var generator = SeededRNG(seed: seed)
            #expect(generator.nextUInt64() != 0 || generator.nextUInt64() != 0)
        }
    }
}
