import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
@_spi(HostOnly) import ToyGame
import XCTest

final class PerfTests: XCTestCase {

    /// A mid-deal state to measure against: the deal plus one play.
    private func midDealState() throws -> (Engine, GameState, Seat) {
        let engine = ToyGame.engine()
        let start = try engine.start(seed: 2026)
        var state = start.state
        for seatRaw in 0..<ToyGame.seatCount {
            let seat = Seat(seatRaw)
            let legal = engine.legalIntents(for: seat, in: state)
            guard let first = legal.first else { continue }
            state = try engine.apply(
                Action(seat: seat, intent: first, expectedVersion: state.version),
                to: state
            ).state
            break
        }
        // The seat with a legal action now is the measured actor.
        for seatRaw in 0..<ToyGame.seatCount {
            let seat = Seat(seatRaw)
            if !engine.legalIntents(for: seat, in: state).isEmpty {
                return (engine, state, seat)
            }
        }
        throw XCTSkip("no legal action in mid-deal state")
    }

    func testMeasureApply() throws {
        let (engine, state, seat) = try midDealState()
        let legal = engine.legalIntents(for: seat, in: state)
        guard let first = legal.first else { throw XCTSkip("no legal action in mid-deal state") }
        measure {
            _ = try? engine.apply(
                Action(seat: seat, intent: first, expectedVersion: state.version),
                to: state
            )
        }
    }

    func testMeasureObservation() throws {
        let (engine, state, _) = try midDealState()
        measure {
            _ = engine.observation(of: state, for: .seat(Seat(0)))
        }
    }

    /// Samples one operation, returning its duration in nanoseconds.
    private func sampleNanos(_ body: () throws -> Void) rethrows -> Int {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        return Int(t1 - t0)
    }

    /// Integer p99: the sample at index `(count * 99) / 100` of the sorted
    /// nanosecond timings (no floating point anywhere, per CONVENTIONS §5).
    private func p99Nanos(_ samples: [Int]) -> Int {
        samples[(samples.count * 99) / 100]
    }

    /// p99 of `apply` must stay under 1 ms on this machine.
    func testApplyP99UnderOneMillisecond() throws {
        let (engine, state, seat) = try midDealState()
        let legal = engine.legalIntents(for: seat, in: state)
        guard let first = legal.first else { throw XCTSkip("no legal action in mid-deal state") }
        let action = Action(seat: seat, intent: first, expectedVersion: state.version)
        var samples: [Int] = []
        samples.reserveCapacity(2_000)
        // Warm-up.
        for _ in 0..<50 { _ = try engine.apply(action, to: state) }
        for _ in 0..<2_000 {
            samples.append(try sampleNanos { try engine.apply(action, to: state) })
        }
        samples.sort()
        let p99 = p99Nanos(samples)
        XCTAssertLessThan(p99, 1_000_000, "p99 apply = \(p99) ns (threshold 1_000_000 ns)")
        print("PERF: apply p99 = \(p99 / 1_000) µs (\(samples.count) samples)")
    }

    /// p99 of `observation` must stay under 0.5 ms on this machine.
    func testObservationP99UnderHalfMillisecond() throws {
        let (engine, state, _) = try midDealState()
        var samples: [Int] = []
        samples.reserveCapacity(2_000)
        for _ in 0..<50 { _ = engine.observation(of: state, for: .seat(Seat(0))) }
        for _ in 0..<2_000 {
            samples.append(sampleNanos { engine.observation(of: state, for: .seat(Seat(0))) })
        }
        samples.sort()
        let p99 = p99Nanos(samples)
        XCTAssertLessThan(p99, 500_000, "p99 observation = \(p99) ns (threshold 500_000 ns)")
        print("PERF: observation p99 = \(p99 / 1_000) µs (\(samples.count) samples)")
    }
}
