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
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// Pure function form used for deal seeds.
    public static func derive(from seed: UInt64) -> UInt64 {
        var splitmix = SplitMix64(seed: seed)
        return splitmix.next()
    }
}

public struct SeededRNG: Codable, Hashable, Sendable {
    /// Encoded keys stay `s0`–`s3` so serialized RNG state (and therefore
    /// golden replay hashes) do not change with the Swift property names.
    private enum CodingKeys: String, CodingKey {
        case s0, s1, s2, s3
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lane0 = try container.decode(UInt64.self, forKey: .s0)
        lane1 = try container.decode(UInt64.self, forKey: .s1)
        lane2 = try container.decode(UInt64.self, forKey: .s2)
        lane3 = try container.decode(UInt64.self, forKey: .s3)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lane0, forKey: .s0)
        try container.encode(lane1, forKey: .s1)
        try container.encode(lane2, forKey: .s2)
        try container.encode(lane3, forKey: .s3)
    }

    public var lane0: UInt64
    public var lane1: UInt64
    public var lane2: UInt64
    public var lane3: UInt64

    public init(lane0: UInt64, lane1: UInt64, lane2: UInt64, lane3: UInt64) {
        self.lane0 = lane0
        self.lane1 = lane1
        self.lane2 = lane2
        self.lane3 = lane3
        if lane0 == 0 && lane1 == 0 && lane2 == 0 && lane3 == 0 {
            self.lane3 = 1  // xoshiro256** must not start all-zero
        }
    }

    /// SplitMix64 expansion of a 64-bit seed (§10.1). Never all-zero.
    public init(seed: UInt64) {
        var splitmix = SplitMix64(seed: seed)
        var state0 = splitmix.next()
        var state1 = splitmix.next()
        var state2 = splitmix.next()
        var state3 = splitmix.next()
        if state0 == 0 && state1 == 0 && state2 == 0 && state3 == 0 {
            state3 = 1  // xoshiro256** must not start all-zero
        }
        self.init(lane0: state0, lane1: state1, lane2: state2, lane3: state3)
    }

    /// `dealSeed(i) = splitmix64(sessionSeed ^ UInt64(i))` (§10.2).
    public static func dealSeed(sessionSeed: UInt64, index: UInt64) -> UInt64 {
        SplitMix64.derive(from: sessionSeed ^ index)
    }

    @inline(__always)
    private static func rotl(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        (value << amount) | (value >> (64 &- amount))
    }

    /// One xoshiro256** step; returns the output word.
    public mutating func nextUInt64() -> UInt64 {
        let result = SeededRNG.rotl(lane1 &* 5, 7) &* 9
        let scratch = lane1 << 17
        lane2 ^= lane0
        lane3 ^= lane1
        lane1 ^= lane2
        lane0 ^= lane3
        lane2 ^= scratch
        lane3 = SeededRNG.rotl(lane3, 45)
        return result
    }

    /// Lemire's nearly-divisionless bounded integer in `0..<bound`.
    public mutating func below(_ bound: UInt64) -> UInt64 {
        precondition(bound > 0, "bound must be positive")
        var draw = nextUInt64()
        var product = draw.multipliedFullWidth(by: bound)
        if product.low < bound {
            let threshold = (0 &- bound) % bound  // 2^64 mod bound
            while product.low < threshold {
                draw = nextUInt64()
                product = draw.multipliedFullWidth(by: bound)
            }
        }
        return product.high
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
        var cursor = array.count - 1
        while cursor > 0 {
            let pick = below(cursor + 1)
            array.swapAt(cursor, pick)
            cursor -= 1
        }
    }

    public mutating func shuffled<T>(_ array: [T]) -> [T] {
        var copy = array
        shuffle(&copy)
        return copy
    }
}
