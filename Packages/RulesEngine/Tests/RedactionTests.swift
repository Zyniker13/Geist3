import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing
@_spi(HostOnly) import ToyGame

@Suite("RulesEngine — Observation and Redactor (§9.6)")
struct RedactionTests {

    private static func encodedScannable(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    /// All face IDs a viewer must NOT see in this state.
    private static func forbiddenFaces(state: GameState, viewer: Viewer) -> Set<String> {
        var forbidden = Set<String>()
        let seat: Seat?
        switch viewer {
        case .seat(let s), .coachOf(let s):
            seat = s
        case .table, .spectator, .replayAll:
            return forbidden  // table/spectator/replay see public cards only
        }
        for (key, cards) in state.zones.zones {
            for card in cards {
                let visible = ObservedZone.redactCards([card], key: key, viewer: viewer, knowledge: state.knowledge)
                switch visible {
                case .visible:
                    break
                case .hidden(_, let known):
                    let knownIDs = Set(known.map { $0.id })
                    if !knownIDs.contains(card.id) {
                        forbidden.insert(card.face.id)
                    }
                }
            }
        }
        _ = seat
        return forbidden
    }

    @Test func observationByteScanNoHiddenFaces() throws {
        let engine = ToyGame.engine()
        let games = 2_000
        var checks = 0
        for seed in 0..<games {
            let start = try engine.start(seed: UInt64(seed))
            var state = start.state
            var rng = SeededRNG(seed: UInt64(seed) ^ 0xface_face_face_face)
            // Scan the initial observation too.
            for viewer in [Viewer.seat(Seat(0)), .seat(Seat(1)), .table, .spectator] {
                let forbidden = RedactionTests.forbiddenFaces(state: state, viewer: viewer)
                let observation = engine.observation(of: state, for: viewer)
                let json = RedactionTests.encodedScannable(try JSONEncoder().encode(observation))
                for face in forbidden {
                    #expect(!json.contains(face), "seed \(seed): \(viewer) sees hidden face \(face)")
                    checks += 1
                }
            }
            // Play the deal, scanning after every step.
            while state.phase.phaseID != "done" {
                var acted = false
                for seatRaw in 0..<2 {
                    let seat = Seat(seatRaw)
                    let legal = engine.legalIntents(for: seat, in: state)
                    guard !legal.isEmpty else { continue }
                    let pick = rng.below(legal.count)
                    state = try engine.apply(
                        Action(seat: seat, intent: legal[pick], expectedVersion: state.version), to: state
                    ).state
                    acted = true
                    break
                }
                if !acted { break }
                for viewer in [Viewer.seat(Seat(0)), .seat(Seat(1)), .table, .spectator] {
                    let forbidden = RedactionTests.forbiddenFaces(state: state, viewer: viewer)
                    let observation = engine.observation(of: state, for: viewer)
                    let json = RedactionTests.encodedScannable(try JSONEncoder().encode(observation))
                    for face in forbidden {
                        #expect(!json.contains(face), "seed \(seed): \(viewer) sees hidden face \(face)")
                        checks += 1
                    }
                }
            }
        }
        #expect(checks > 10_000, "byte scan ran \(checks) checks; expected a large sample")
    }

    /// Hidden zones expose counts only: no card IDs, no faces.
    @Test func hiddenZonesExposeCountsOnly() throws {
        let engine = ToyGame.engine()
        let start = try engine.start(seed: 0)
        let state = start.state
        for viewer in [Viewer.seat(Seat(0)), .seat(Seat(1))] {
            let observation = engine.observation(of: state, for: viewer)
            for (key, zone) in observation.zones where key.contains(":0:hand") || key.contains(":1:hand") {
                let owner = Int(key.split(separator: ":")[1]) ?? -1
                let viewerSeat: Int? = {
                    if case .seat(let s) = viewer { return s.raw }
                    return nil
                }()
                if owner != viewerSeat, case .hidden(let count, let known) = zone {
                    #expect(known.isEmpty, "hidden zone \(key) disclosed \(known.count) known cards to a non-owner")
                    #expect(count == 5, "hidden zone \(key) count \(count) != 5")
                }
            }
        }
    }

    /// Events are redacted per viewer: a non-owner sees no faces in .dealt.
    @Test func dealtEventsRedactedPerViewer() throws {
        let engine = ToyGame.engine()
        let start = try engine.start(seed: 3)
        let seat0 = engine.observation(of: start.state, for: .seat(Seat(0)))
        let json = RedactionTests.encodedScannable(try JSONEncoder().encode(seat0))
        // Seat 1's dealt cards must not appear anywhere in seat 0's events.
        let seat1Hand = start.state.zones.cards(in: ZoneKey(scope: .seat, owner: 1, id: "hand"))
        for card in seat1Hand {
            #expect(!json.contains(card.face.id), "seat 0's observation leaks seat 1's \(card.face.id)")
        }
        // But seat 0's own hand faces must be present (positive control).
        let seat0Hand = start.state.zones.cards(in: ZoneKey(scope: .seat, owner: 0, id: "hand"))
        var ownFaces = 0
        for card in seat0Hand where json.contains(card.face.id) { ownFaces += 1 }
        #expect(ownFaces == 5, "seat 0 should see all 5 of its own dealt faces, saw \(ownFaces)")
    }

    /// Redaction consistency across many seeds: the opponent hand never
    /// leaks through the observation's legal-intent list either.
    @Test func legalIntentsCarryNoForeignFaces() throws {
        let engine = ToyGame.engine()
        for seed in 0..<200 {
            let start = try engine.start(seed: UInt64(seed))
            let state = start.state
            let seat0 = engine.observation(of: state, for: .seat(Seat(0)))
            let seat1Hand = Set(state.zones.cards(in: ZoneKey(scope: .seat, owner: 1, id: "hand")).map { $0.id })
            // Legal intents reference seat 0's own cards only.
            for intent in seat0.legal {
                if case .play(let id) = intent {
                    #expect(!seat1Hand.contains(id), "seed \(seed): seat 0's legal list names seat 1's card \(id.raw)")
                }
            }
        }
    }
}
