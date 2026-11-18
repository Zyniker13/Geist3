import Foundation
import XCTest
import CardModel
@_spi(HostOnly) import ToyGame
@testable import RulesEngine
@_spi(HostOnly) import RulesEngine

/// P1.8: Performance harness (ROADMAP §P1.8). XCTest `measure` for
/// `apply` and `observation`, plus explicit p99 sampling against the
/// acceptance thresholds: p99 apply < 1 ms, p99 observation < 0.5 ms on
/// the CI Mac (device numbers are recorded again in P4).
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

    /// p99 of `apply` must stay under 1 ms on this machine.
    func testApplyP99UnderOneMillisecond() throws {
        let (engine, state, seat) = try midDealState()
        let legal = engine.legalIntents(for: seat, in: state)
        guard let first = legal.first else { throw XCTSkip("no legal action in mid-deal state") }
        let action = Action(seat: seat, intent: first, expectedVersion: state.version)
        var samples: [Double] = []
        samples.reserveCapacity(2_000)
        // Warm-up.
        for _ in 0..<50 { _ = try engine.apply(action, to: state) }
        for _ in 0..<2_000 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try engine.apply(action, to: state)
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1 - t0) / 1_000.0) // microseconds
        }
        samples.sort()
        let p99 = samples[Int(Double(samples.count - 1) * 0.99)]
        XCTAssertLessThan(p99, 1_000.0, "p99 apply = \(p99) µs (threshold 1000 µs)")
        print("PERF: apply p99 = \(p99) µs (\(samples.count) samples)")
    }

    /// p99 of `observation` must stay under 0.5 ms on this machine.
    func testObservationP99UnderHalfMillisecond() throws {
        let (engine, state, _) = try midDealState()
        var samples: [Double] = []
        samples.reserveCapacity(2_000)
        for _ in 0..<50 { _ = engine.observation(of: state, for: .seat(Seat(0))) }
        for _ in 0..<2_000 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = engine.observation(of: state, for: .seat(Seat(0)))
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1 - t0) / 1_000.0)
        }
        samples.sort()
        let p99 = samples[Int(Double(samples.count - 1) * 0.99)]
        XCTAssertLessThan(p99, 500.0, "p99 observation = \(p99) µs (threshold 500 µs)")
        print("PERF: apply/observation p99 = \(samples[Int(Double(samples.count - 1) * 0.99)]) µs (observation, \(samples.count) samples)")
    }
}
