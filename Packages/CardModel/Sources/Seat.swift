// Seats and teams (ARCHITECTURE §4.3). Seats are 0..<n clockwise.

public struct Seat: Hashable, Codable, Sendable, Comparable {
    public let raw: Int

    public init(_ raw: Int) { self.raw = raw }

    public static func < (lhs: Seat, rhs: Seat) -> Bool { lhs.raw < rhs.raw }
}

/// Team layouts a ruleset may declare (§4.3, ruleset `players.teams`).
public enum TeamLayout: String, Codable, Sendable {
    case none
    case partnershipOpposite
    case dynamic
}

/// Team indices are ruleset-defined; the engine only carries them.
public struct Team: Hashable, Codable, Sendable {
    public let raw: Int

    public init(_ raw: Int) { self.raw = raw }
}

/// A fixed-capacity bitset over seats (0..<64; table sizes never approach it).
/// Contract partner for `pendingSeats` (§5.6) and knowledge masks (§9.6).
public struct SeatSet: Hashable, Codable, Sendable, Sequence {
    public private(set) var bits: UInt64

    public struct SeatIterator: IteratorProtocol {
        var bits: UInt64
        mutating public func next() -> Seat? {
            guard bits != 0 else { return nil }
            let low = bits & (~bits &+ 1)  // isolate lowest set bit
            bits &= bits &- 1
            return Seat(low.trailingZeroBitCount)
        }
    }

    public func makeIterator() -> SeatIterator { SeatIterator(bits: bits) }

    public init() { bits = 0 }
    public init(bits: UInt64) { self.bits = bits }

    public init(_ seats: some Sequence<Seat>) {
        bits = 0
        for seat in seats { bits |= Self.bit(for: seat) }
    }

    public init(_ seat: Seat) { bits = Self.bit(for: seat) }

    public static func bit(for seat: Seat) -> UInt64 {
        precondition((0..<64).contains(seat.raw), "SeatSet supports seats 0..<64")
        return UInt64(1) << UInt64(seat.raw)
    }

    public static var empty: SeatSet { SeatSet() }

    public var isEmpty: Bool { bits == 0 }
    public var count: Int { bits.nonzeroBitCount }

    public func contains(_ seat: Seat) -> Bool { bits & Self.bit(for: seat) != 0 }

    public mutating func insert(_ seat: Seat) { bits |= Self.bit(for: seat) }
    public mutating func remove(_ seat: Seat) { bits &= ~Self.bit(for: seat) }

    public mutating func formUnion(_ other: SeatSet) { bits |= other.bits }
    public func union(_ other: SeatSet) -> SeatSet { SeatSet(bits: bits | other.bits) }
    public func intersection(_ other: SeatSet) -> SeatSet { SeatSet(bits: bits & other.bits) }
    public func subtracting(_ other: SeatSet) -> SeatSet { SeatSet(bits: bits & ~other.bits) }

    public static func union(_ first: SeatSet, _ second: SeatSet) -> SeatSet { first.union(second) }
}
