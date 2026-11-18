// Seeded deterministic RNG (ARCHITECTURE §10.1).
// xoshiro256** (Blackman and Vigna) seeded via SplitMix64; Lemire's
// nearly-divisionless bounded integers; Fisher–Yates shuffle from the top.
// The whole state is a Codable struct so games serialize and replay exactly.

/// SplitMix64 stream used only to expand a 64-bit seed into RNG state or
/// deal seeds (`dealSeed(i) = splitmix64(sessionSeed ^ UInt64(i))`).
public struct SplitMix64: Sendable {
    public var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Pure function form used for deal seeds.
    public static func derive(from seed: UInt64) -> UInt64 {
        var sm = SplitMix64(seed: seed)
        return sm.next()
    }
}

public struct SeededRNG: Codable, Hashable, Sendable {
    public var s0: UInt64
    public var s1: UInt64
    public var s2: UInt64
    public var s3: UInt64

    public init(s0: UInt64, s1: UInt64, s2: UInt64, s3: UInt64) {
        self.s0 = s0
        self.s1 = s1
        self.s2 = s2
        self.s3 = s3
        if self.s0 == 0 && self.s1 == 0 && self.s2 == 0 && self.s3 == 0 {
            self.s3 = 1 // xoshiro256** must not start all-zero
        }
    }

    /// SplitMix64 expansion of a 64-bit seed (§10.1). Never all-zero.
    public init(seed: UInt64) {
        var sm = SplitMix64(seed: seed)
        var s0 = sm.next(), s1 = sm.next(), s2 = sm.next(), s3 = sm.next()
        if s0 == 0 && s1 == 0 && s2 == 0 && s3 == 0 {
            s3 = 1 // xoshiro256** must not start all-zero
        }
        self.init(s0: s0, s1: s1, s2: s2, s3: s3)
    }

    /// `dealSeed(i) = splitmix64(sessionSeed ^ UInt64(i))` (§10.2).
    public static func dealSeed(sessionSeed: UInt64, index: UInt64) -> UInt64 {
        SplitMix64.derive(from: sessionSeed ^ index)
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 &- k))
    }

    /// One xoshiro256** step; returns the output word.
    public mutating func nextUInt64() -> UInt64 {
        let result = SeededRNG.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = SeededRNG.rotl(s3, 45)
        return result
    }

    /// Lemire's nearly-divisionless bounded integer in `0..<bound`.
    public mutating func below(_ bound: UInt64) -> UInt64 {
        precondition(bound > 0, "bound must be positive")
        var x = nextUInt64()
        var m = x.multipliedFullWidth(by: bound)
        if m.low < bound {
            let threshold = (0 &- bound) % bound // 2^64 mod bound
            while m.low < threshold {
                x = nextUInt64()
                m = x.multipliedFullWidth(by: bound)
            }
        }
        return m.high
    }

    public mutating func below(_ bound: Int) -> Int {
        Int(below(UInt64(bound)))
    }

    /// Uniform element of `0..<range.lowerBound ..< range.upperBound` style
    /// convenience for integer ranges starting at zero.
    public mutating func `in`(_ range: Range<Int>) -> Int {
        precondition(!range.isEmpty, "range must not be empty")
        return range.lowerBound + below(range.count)
    }

    /// Fisher–Yates shuffle, from the top (§10.1).
    public mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        var i = array.count - 1
        while i > 0 {
            let j = below(i + 1)
            array.swapAt(i, j)
            i -= 1
        }
    }

    public mutating func shuffled<T>(_ array: [T]) -> [T] {
        var copy = array
        shuffle(&copy)
        return copy
    }
}
