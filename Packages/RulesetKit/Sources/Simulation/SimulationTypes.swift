// P2.8 simulator support: deterministic deal simulation with invariants
// (ROADMAP §P2.8, CONVENTIONS §5). The simulator is host-side tooling: it
// consumes full intents and full state (it is compiled behind the same
// @_spi(HostOnly) boundary as the engine tests), so the §9 redaction
// boundary is not weakened for clients.

import CardModel
@_spi(HostOnly) import RulesEngine

/// Why a ruleset could not be turned into a runnable engine.
public enum SimulationError: Error, Sendable, CustomStringConvertible {
    /// A mechanic or parameter the P2.8 simulator does not model yet.
    case unsupported(String)
    /// The ruleset is internally inconsistent for simulation.
    case config(String)

    public var description: String {
        switch self {
        case .unsupported(let m): return "not simulated yet: \(m)"
        case .config(let m): return "simulation config error: \(m)"
        }
    }
}

/// A seat's policy for choosing among legal intents. Bots must be
/// deterministic given (seed, actionIndex): the simulator feeds each one a
/// seed stream derived from the run seed so runs replay exactly.
public protocol SimulatorBot: Sendable {
    /// Returns one of `legal` (or nil to pass, when legal).
    func choose(legal: [ActionIntent], seat: Seat, actionIndex: Int) -> ActionIntent?
}

/// Deterministic legal-random bot: uniform over the legal list using a
/// seed stream derived from (seed, seat, actionIndex). Pure architecture:
/// never logs, never consults a clock.
public struct RandomLegalBot: SimulatorBot {
    /// Uniform choice stream base; the simulator seeds it per run.
    public let seedBase: UInt64

    public init() { seedBase = 0 }

    public init(seed: UInt64) {
        seedBase = seed
    }

    public func choose(legal: [ActionIntent], seat: Seat, actionIndex: Int) -> ActionIntent? {
        guard !legal.isEmpty else { return nil }
        var rng = SeededRNG(seed: RandomLegalBot.mix(seed: seedBase, seat: seat.raw, counter: actionIndex))
        return legal[rng.below(legal.count)]
    }

    /// One-way mix for seed streams (CONVENTIONS §5: derived, not random).
    static func mix(seed: UInt64, seat: Int, counter: Int) -> UInt64 {
        var h = seed &* 0x9E37_79B9_7F4A_7C15
        h = h &+ (UInt64(bitPattern: Int64(seat)) &* 0xBF58_476D_1CE4_E5B9)
        h = h &+ (UInt64(bitPattern: Int64(counter)) &* 0x94D0_49BB_1331_11EB)
        h ^= h >> 33
        h = h &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        h = h &* 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return h
    }
}

/// The outcome of one simulated deal.
public struct SimulationRun: Sendable {
    /// The run seed (mixed into engine shuffles and bot streams).
    public let seed: UInt64
    /// Legal intents actually applied.
    public let actions: Int
    /// True when the engine reached its terminal phase ("done").
    public let done: Bool
    /// Deterministic digest of the terminal state (§10.4).
    public let finalHash: String
    /// Invariant violations found (must be empty for a clean run).
    public let faults: [String]
    /// Declared rule ids never exercised by this deal (informational).
    public let unexercisedRules: [String]
    /// One-line summary of the state at fault time (phase, deal index, match
    /// and deal variables); empty on a clean run. Host tooling only.
    public let faultContext: String
    /// The terminal state (host tooling only: full state, never serialized).
    /// SPI-marked because `GameState` itself crosses only the host-only SPI.
    @_spi(HostOnly) public let finalState: GameState
}
