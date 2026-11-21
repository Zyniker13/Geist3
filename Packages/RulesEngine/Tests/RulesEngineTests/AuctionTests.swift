import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

// Auction mechanic suites (P3.1): `auction.rounds` (euchre-shaped) and
// `auction.ladder` (bridge-shaped) — every parameter exercised, plus
// invalid-call rejections. The builder-side parameter validation lives in
// the RulesetKit suite.
@Suite("Auction mechanics — rounds and ladder (P3.1)")
struct AuctionTests {
    // MARK: - auction.rounds

    @Test func orderUpSetsTrumpMakerAndCompletes() throws {
        let engine = Self.roundsEngine()
        let started = try engine.start(seed: 7)
        // Deal completes automatically; the auction begins left of dealer 0.
        #expect(started.state.phase.phaseID == "bid")
        #expect(Self.substate(started.state).turn == Seat(1))
        // S2 orders up: trump comes from the upcard (queen of clubs).
        let applied = try engine.apply(
            Action(seat: Seat(1), intent: .call("orderUp"), expectedVersion: started.state.version),
            to: started.state)
        #expect(Self.dealVarOf(applied.state, "trump") == .string("C"))
        #expect(Self.dealVarOf(applied.state, "maker") == .seat(Seat(1)))
        #expect(applied.events.contains(.called(seat: Seat(1), call: "orderUp")))
        #expect(applied.state.phase.phaseID != "bid")
    }

    @Test func passTurnsMoveAroundTheRound() throws {
        let engine = Self.roundsEngine()
        let started = try engine.start(seed: 7)
        var state = started.state
        for raw in 1...3 {
            let applied = try engine.apply(
                Action(seat: Seat(raw), intent: .call("pass"), expectedVersion: state.version),
                to: state)
            state = applied.state
        }
        // Three passes leave the auction with the dealer still to call.
        #expect(state.phase.phaseID == "bid")
        #expect(Self.substate(state).turn == Seat(0))
        // The fourth pass exhausts round 1: the upcard turns down and round
        // 2 re-enters at the first bidder.
        let last = try engine.apply(
            Action(seat: Seat(0), intent: .call("pass"), expectedVersion: state.version),
            to: state)
        let sub = Self.substate(last.state)
        #expect(sub.round == 1)
        #expect(sub.turn == Seat(1))
        #expect(last.state.zones.cards(in: ZoneKey(scope: .shared, id: "upcard")).isEmpty)
        #expect(last.state.zones.cards(in: ZoneKey(scope: .shared, id: "discard")).count == 1)
    }

    @Test func allPassTwiceRedealsWithRotatedDealer() throws {
        let engine = Self.roundsEngine()
        var state = try engine.start(seed: 11).state
        // Pass all the way through both rounds.
        for _ in 0..<8 {
            let turn = Self.substate(state).turn!
            let applied = try engine.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state.version),
                to: state)
            state = applied.state
        }
        // The auction passed out: the deal re-entered with the dealer moved.
        // The idle deal phase completes instantly, so the engine rests back
        // in the auction with a fresh substate and the next dealer.
        #expect(state.phase.phaseID == "bid")
        #expect(state.dealer == Seat(1))
        #expect(state.dealIndex == 1)
        #expect(Self.dealVarOf(state, "trump") == .null)
        let fresh = Self.substate(state)
        #expect(fresh.round == 0)
        #expect(!fresh.passedOut)
        #expect(fresh.turn == Seat(2))
    }

    @Test func allPassSameDealerLeavesDealerAlone() throws {
        let engine = Self.roundsEngine(allPass: "redealSame")
        var state = try engine.start(seed: 11).state
        for _ in 0..<8 {
            let turn = Self.substate(state).turn!
            let applied = try engine.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state.version),
                to: state)
            state = applied.state
        }
        #expect(state.phase.phaseID == "bid")
        #expect(state.dealer == Seat(0))
        #expect(Self.substate(state).round == 0)
    }

    @Test func nameCarriesTheParamIntoTrump() throws {
        let engine = Self.roundsEngine()
        var state = try engine.start(seed: 3).state
        for _ in 0..<4 {
            let turn = Self.substate(state).turn!
            state = try engine.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        // Round 2: S2 names diamonds (not the discarded club).
        let intents = engine.legalIntents(for: Seat(1), in: state)
        #expect(intents.contains(.call("name:D")))
        #expect(!intents.contains(.call("name:C")))
        #expect(!intents.contains(.call("name")))
        let applied = try engine.apply(
            Action(seat: Seat(1), intent: .call("name:D"), expectedVersion: state.version),
            to: state)
        #expect(Self.dealVarOf(applied.state, "trump") == .string("D"))
        #expect(applied.state.phase.phaseID != "bid")
    }

    @Test func stickTheDealerHidesPassInRoundTwo() throws {
        let engine = Self.roundsEngine(stickPass: true)
        var state = try engine.start(seed: 3).state
        for _ in 0..<4 {
            let turn = Self.substate(state).turn!
            state = try engine.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        // Everyone else may pass; the dealer may not (EUC-2.4).
        for seat in [Seat(1), Seat(2), Seat(3)] {
            #expect(engine.legalIntents(for: seat, in: state).contains(.call("pass")))
            state = try engine.apply(
                Action(seat: seat, intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        // The dealer is on turn with no pass offered — spades and hearts are
        // still nameable, the discarded club is not.
        let dealerIntents = engine.legalIntents(for: Seat(0), in: state)
        #expect(dealerIntents.contains(.call("name:S")))
        #expect(dealerIntents.contains(.call("name:H")))
        #expect(!dealerIntents.contains(.call("name:C")))
        #expect(!dealerIntents.contains(.call("pass")))
        do {
            _ = try engine.apply(
                Action(seat: Seat(0), intent: .call("pass"), expectedVersion: state.version),
                to: state)
            Issue.record("stick the dealer: the dealer must not pass")
        } catch {}
        // Forced to make trump, the dealer names spades and the auction ends.
        let applied = try engine.apply(
            Action(seat: Seat(0), intent: .call("name:S"), expectedVersion: state.version),
            to: state)
        #expect(Self.dealVarOf(applied.state, "trump") == .string("S"))
        #expect(applied.state.phase.phaseID != "bid")
    }

    @Test func goAloneFlowsIntoOnCall() throws {
        let on = Self.roundsEngine(alone: "true")
        var state = try on.start(seed: 3).state
        for _ in 0..<4 {
            let turn = Self.substate(state).turn!
            state = try on.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        let applied = try on.apply(
            Action(seat: Seat(1), intent: .call("name:H"), expectedVersion: state.version),
            to: state)
        #expect(Self.dealVarOf(applied.state, "alone") == .bool(true))

        let off = Self.roundsEngine(alone: "false")
        var state2 = try off.start(seed: 3).state
        for _ in 0..<4 {
            let turn = Self.substate(state2).turn!
            state2 = try off.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state2.version),
                to: state2
            ).state
        }
        let applied2 = try off.apply(
            Action(seat: Seat(1), intent: .call("name:H"), expectedVersion: state2.version),
            to: state2)
        #expect(Self.dealVarOf(applied2.state, "alone") == .bool(false))
    }

    @Test func illegalIntentsAreRejected() throws {
        let engine = Self.roundsEngine()
        let started = try engine.start(seed: 5)
        // Wrong seat: nothing is legal and the reducer refuses the action.
        #expect(engine.legalIntents(for: Seat(2), in: started.state).isEmpty)
        do {
            _ = try engine.apply(
                Action(seat: Seat(2), intent: .call("orderUp"), expectedVersion: started.state.version),
                to: started.state)
            Issue.record("out-of-turn call must be rejected")
        } catch {}
        // A call the round does not offer.
        do {
            _ = try engine.apply(
                Action(seat: Seat(1), intent: .call("bid"), expectedVersion: started.state.version),
                to: started.state)
            Issue.record("unknown call must be rejected")
        } catch {}
        // A param call without its parameter.
        var state = started.state
        for _ in 0..<4 {
            let turn = Self.substate(state).turn!
            state = try engine.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        do {
            _ = try engine.apply(
                Action(seat: Seat(1), intent: .call("name"), expectedVersion: state.version),
                to: state)
            Issue.record("param call without a param must be rejected")
        } catch {}
    }

    // MARK: - auction.ladder

    @Test func openingMenuOffersEveryBidAndPassOnly() throws {
        let engine = Self.ladderEngine()
        let started = try engine.start(seed: 1)
        // Dealer (S1) calls first (BRG-2.1).
        #expect(Self.substate(started.state).turn == Seat(0))
        let intents = engine.legalIntents(for: Seat(0), in: started.state)
        let tags = intents.compactMap { intent -> String? in
            if case .call(let tag) = intent { return tag }
            return nil
        }
        let bids = tags.filter { !["pass", "double", "redouble"].contains($0) }
        #expect(bids.count == 35)  // 7 levels × 5 strains
        #expect(bids.contains("1C") && bids.contains("7NT"))
        #expect(tags.contains("pass"))
        #expect(!tags.contains("double"))
        #expect(!tags.contains("redouble"))
    }

    @Test func bidMustRankAboveTheLast() throws {
        let engine = Self.ladderEngine()
        var state = try engine.start(seed: 1).state
        state = try engine.apply(
            Action(seat: Seat(0), intent: .call("1C"), expectedVersion: state.version),
            to: state
        ).state
        let intents = engine.legalIntents(for: Seat(1), in: state)
        let tags = intents.compactMap { if case .call(let t) = $0 { return t } else { return nil } }
        #expect(!tags.contains("1C"))
        #expect(tags.contains("1D") && tags.contains("7NT"))
        // An equal-or-lower bid is illegal.
        do {
            _ = try engine.apply(
                Action(seat: Seat(1), intent: .call("1C"), expectedVersion: state.version),
                to: state)
            Issue.record("a non-outranking bid must be rejected")
        } catch {}
        // Out of range bids are illegal too.
        do {
            _ = try engine.apply(
                Action(seat: Seat(1), intent: .call("8H"), expectedVersion: state.version),
                to: state)
            Issue.record("level 8 must be rejected")
        } catch {}
    }

    @Test func doubleAndRedoubleLegality() throws {
        let engine = Self.ladderEngine()
        var state = try engine.start(seed: 1).state
        // N bids 1C; E (opponent) may double, S (partner) may not.
        state = try engine.apply(
            Action(seat: Seat(0), intent: .call("1C"), expectedVersion: state.version),
            to: state
        ).state
        let eastIntents = engine.legalIntents(for: Seat(1), in: state)
        #expect(eastIntents.contains(.call("double")))
        #expect(!eastIntents.contains(.call("redouble")))
        #expect(!engine.legalIntents(for: Seat(2), in: state).contains(.call("double")))
        // E doubles; now S (owning side) may redouble, E may not.
        state = try engine.apply(
            Action(seat: Seat(1), intent: .call("double"), expectedVersion: state.version),
            to: state
        ).state
        #expect(engine.legalIntents(for: Seat(2), in: state).contains(.call("redouble")))
        #expect(!engine.legalIntents(for: Seat(1), in: state).contains(.call("redouble")))
        state = try engine.apply(
            Action(seat: Seat(2), intent: .call("redouble"), expectedVersion: state.version),
            to: state
        ).state
        // A second redouble is not offered to anyone.
        #expect(!engine.legalIntents(for: Seat(3), in: state).contains(.call("redouble")))
        #expect(Self.dealVarOf(state, "contract") == .null)
    }

    @Test func threePassesEndTheAuctionAndWriteTheResult() throws {
        let engine = Self.ladderEngine()
        var state = try engine.start(seed: 2).state
        state = try engine.apply(
            Action(seat: Seat(0), intent: .call("1NT"), expectedVersion: state.version),
            to: state
        ).state
        for raw in 1...3 {
            state = try engine.apply(
                Action(seat: Seat(raw), intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        #expect(state.phase.phaseID != "bid")
        let contract = Self.dealVarOf(state, "contract")
        guard case .record("contract", let fields)? = contract else {
            Issue.record("contract record missing: \(String(describing: contract))")
            return
        }
        #expect(fields["level"] == .int(1))
        #expect(fields["strain"] == .string("NT"))
        #expect(fields["doubled"] == .bool(false))
        #expect(fields["redoubled"] == .bool(false))
        #expect(Self.dealVarOf(state, "declarer") == .seat(Seat(0)))
    }

    @Test func declarerIsFirstOfTheWinningSideToNameTheStrain() throws {
        let engine = Self.ladderEngine()
        var state = try engine.start(seed: 2).state
        // N 1H, E pass, S 2H, W pass, N pass, E pass → N's side wins 2H;
        // N named hearts first, so N declares (BRG-2.5).
        state = try engine.apply(
            Action(seat: Seat(0), intent: .call("1H"), expectedVersion: state.version),
            to: state
        ).state
        state = try engine.apply(
            Action(seat: Seat(1), intent: .call("pass"), expectedVersion: state.version),
            to: state
        ).state
        state = try engine.apply(
            Action(seat: Seat(2), intent: .call("2H"), expectedVersion: state.version),
            to: state
        ).state
        for seat in [Seat(3), Seat(0), Seat(1)] {
            state = try engine.apply(
                Action(seat: seat, intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        #expect(state.phase.phaseID != "bid")
        #expect(Self.dealVarOf(state, "declarer") == .seat(Seat(0)))
        guard case .record("contract", let fields)? = Self.dealVarOf(state, "contract") else {
            Issue.record("contract record missing")
            return
        }
        #expect(fields["level"] == .int(2))
        #expect(fields["strain"] == .string("H"))
    }

    @Test func passedOutRedealsPerTheOption() throws {
        let next = Self.ladderEngine(allPass: "redealNext")
        var state = try next.start(seed: 4).state
        for _ in 0..<4 {
            let turn = Self.substate(state).turn!
            state = try next.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        #expect(state.phase.phaseID == "bid")
        #expect(state.dealer == Seat(1))

        let same = Self.ladderEngine(allPass: "redealSame")
        var state2 = try same.start(seed: 4).state
        for _ in 0..<4 {
            let turn = Self.substate(state2).turn!
            state2 = try same.apply(
                Action(seat: turn, intent: .call("pass"), expectedVersion: state2.version),
                to: state2
            ).state
        }
        #expect(state2.phase.phaseID == "bid")
        #expect(state2.dealer == Seat(0))
    }

    @Test func defaultPassesNeededIsEveryOtherSeat() throws {
        // No `end` block: the auction ends when every other seat passes.
        let engine = Self.ladderEngine(passes: nil)
        var state = try engine.start(seed: 6).state
        state = try engine.apply(
            Action(seat: Seat(0), intent: .call("2S"), expectedVersion: state.version),
            to: state
        ).state
        for raw in 1...2 {
            state = try engine.apply(
                Action(seat: Seat(raw), intent: .call("pass"), expectedVersion: state.version),
                to: state
            ).state
        }
        #expect(state.phase.phaseID == "bid")
        state = try engine.apply(
            Action(seat: Seat(3), intent: .call("pass"), expectedVersion: state.version),
            to: state
        ).state
        #expect(state.phase.phaseID != "bid")
        #expect(Self.dealVarOf(state, "declarer") == .seat(Seat(0)))
    }
}
