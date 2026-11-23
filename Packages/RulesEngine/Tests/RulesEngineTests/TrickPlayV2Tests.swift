// Trick-play v2 extension tests (S6): trump winner selection, follow
// obligations with mixed hands, dummy play, and claims (§5.6). The
// euchre-shaped fixture is a 4-seat, 24-card game with unshuffled dealing
// so every hand is known before the deal. The dealer pops the stock tail,
// so each seat receives the six cards listed below in order: seat 0 leads
// with club honours, seat 1 holds five diamonds, seat 2 the remaining
// clubs plus hearts, and seat 3 the spades. Trump is diamonds throughout.

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

@Suite("RulesEngine — trick-play v2: trump, dummy, claims")
struct TrickPlayV2Tests {

    // MARK: - Trump beats the led suit

    /// Seat 1 is void in the led club suit and trumps with the king of
    /// diamonds; the trump must beat seat 0's ace lead and seat 2's club
    /// jack follow.
    @Test static func trumpBeatsHigherLedCard() throws {
        let engine = euchreEngine()
        var state = try engine.start(seed: 7).state
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "J"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "K"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "A"))
        let sub = try #require(trickSub(state))
        #expect(sub.trickIndex == 1, "trick 1 decided")
        #expect(sub.tricksWon[1] == 1, "trump player won the trick")
        #expect(sub.leader == Seat(1), "winner leads the next trick")
    }

    /// No trump hits the table: seat 1 discards a spade, so the highest
    /// card of the led suit wins (seat 2's club jack over seat 0's nine).
    @Test static func highestLedSuitWinsWhenNoTrumpPlayed() throws {
        let engine = euchreEngine()
        var state = try engine.start(seed: 7).state
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "s", rank: "9"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "K"))
        let sub = try #require(trickSub(state))
        #expect(sub.tricksWon[2] == 1, "highest card of the led suit wins")
        #expect(sub.leader == Seat(2))
    }

    // MARK: - Follow obligations with mixed hands

    /// Seat 2 holds clubs and hearts; with clubs led it must play a club —
    /// the legal list narrows to clubs, and a heart dump is rejected with
    /// the follow rule id. Seat 1 (void in clubs) discards first, so seat 2
    /// is genuinely to act when the narrowing is checked.
    @Test static func mustFollowEnforcedOnMixedHand() throws {
        let engine = euchreEngine()
        var state = try engine.start(seed: 7).state
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))

        let legal2 = engine.legalIntents(for: Seat(2), in: state)
        let legalCards = Set(
            legal2.map { intent -> UInt16 in
                if case .play(let id) = intent { return id.raw }
                return UInt16.max
            })
        let clubs = hand(state, Seat(2)).filter { $0.face.suit?.code == "c" }
        #expect(legalCards == Set(clubs.map { $0.id.raw }), "legal list narrowed to the led suit")

        do {
            try play(engine, &state, Seat(2), card(state, Seat(2), suit: "h", rank: "A"))
            Issue.record("heart dump was accepted while holding clubs")
        } catch {
            guard case RuleViolation.illegal(let ruleId, .mustFollow(let suit)) = error else {
                Issue.record("wrong violation: \(error)")
                return
            }
            #expect(ruleId == "euch.follow")
            #expect(suit == "c")
        }
    }

    // MARK: - Dummy play

    /// The dummy's hand is public from phase entry, the controller acts on
    /// the dummy's turn, and the dummy seat itself is never pending.
    @Test static func dummyRevealedAndControlled() throws {
        let engine = euchreEngine(
            dummy: TrickPlayParams.DummySpec(
                seat: .seat(Seat(3)), revealAfter: .immediately, controlledBy: .seat(Seat(1)),
                ruleId: "euch.dummy"))
        var state = try engine.start(seed: 7).state
        let dummyCards = hand(state, Seat(3))
        #expect(!dummyCards.isEmpty)
        #expect(dummyCards.allSatisfy { state.knowledge.isPublic($0.id) }, "dummy hand is public")

        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "K"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))

        // Seat 3 is to act fourth; its controller must see the dummy's cards.
        let controllerLegal = engine.legalIntents(for: Seat(1), in: state)
        let dummyLegal = engine.legalIntents(for: Seat(3), in: state)
        let dummyHandIDs = Set(dummyCards.map { $0.id.raw })
        let controllerPicks = Set(
            controllerLegal.compactMap { intent -> UInt16? in
                if case .play(let id) = intent { return id.raw }
                return nil
            })
        #expect(controllerPicks.isSubset(of: dummyHandIDs), "controller plays from the dummy's hand")
        #expect(dummyLegal.isEmpty, "the dummy seat itself is never asked to act")
        try play(engine, &state, Seat(1), card(state, Seat(3), suit: "s", rank: "10"))
        let sub = try #require(trickSub(state))
        #expect(sub.tricksWon[1] == 1, "trump still wins when played from the dummy's hand")
    }

    // MARK: - Claims

    /// The designated claimant may claim the remaining tricks; the listed
    /// seats accept and the phase completes with all remaining tricks
    /// awarded. A non-claimant's claim attempt is rejected as out of turn.
    @Test static func claimAcceptedAwardsRemainingTricks() throws {
        let engine = euchreEngine(
            claims: TrickPlayParams.ClaimsSpec(
                enabled: ExprRef(pointer: "/test/claims", source: "true"),
                by: .seat(Seat(0)),
                acceptedBy: ExprRef(pointer: "/test/claims/acceptedBy", source: "['S2', 'S3', 'S4']"),
                ruleId: "euch.claims"))
        var state = try engine.start(seed: 7).state

        // Seat 1 is not the claimant.
        do {
            _ = try engine.apply(
                Action(seat: Seat(1), intent: .claim(6), expectedVersion: state.version), to: state)
            Issue.record("a non-claimant claim was accepted")
        } catch {
            guard case RuleViolation.notYourTurn = error else {
                Issue.record("wrong violation for non-claimant: \(error)")
                return
            }
        }

        state = try engine.apply(
            Action(seat: Seat(0), intent: .claim(6), expectedVersion: state.version), to: state
        ).state
        // Voters accept in turn (seat spellings are 1-based: S2 = Seat(1)).
        let voters = try #require(trickSub(state)).claimVoters
        #expect(voters == [Seat(1), Seat(2), Seat(3)])
        var last: Transition?
        for voter in voters {
            let transition = try engine.apply(
                Action(seat: voter, intent: .acceptClaim(true), expectedVersion: state.version), to: state)
            state = transition.state
            last = transition
        }
        // The final accept resolves the claim: all remaining tricks are
        // awarded as a scored event, and the game reaches its terminal
        // phase (so the trick substate is gone by the time we assert).
        let final = try #require(last)
        #expect(
            final.events.contains { event in
                if case .scored(let seat, let points, let reason, _) = event {
                    return seat == Seat(0) && points == 6 && reason == "claim"
                }
                return false
            }, "all remaining tricks awarded to the claimant")
        #expect(state.phase.phaseID == "done", "the phase completes on an accepted claim")
    }

    /// A rejected claim clears the pending claim and play continues.
    @Test static func claimRejectedResumesPlay() throws {
        let engine = euchreEngine(
            claims: TrickPlayParams.ClaimsSpec(
                enabled: ExprRef(pointer: "/test/claims", source: "true"),
                by: .seat(Seat(0)),
                acceptedBy: ExprRef(pointer: "/test/claims/acceptedBy", source: "['S2']"),
                ruleId: "euch.claims"))
        var state = try engine.start(seed: 7).state
        state = try engine.apply(
            Action(seat: Seat(0), intent: .claim(6), expectedVersion: state.version), to: state
        ).state
        state = try engine.apply(
            Action(seat: Seat(1), intent: .acceptClaim(false), expectedVersion: state.version), to: state
        )
        .state
        let sub = try #require(trickSub(state))
        #expect(sub.pendingClaim == nil, "the rejected claim is cleared")
        #expect(sub.tricksWon.allSatisfy { $0 == 0 }, "no tricks awarded on rejection")
        // Play continues: seat 0 is still to lead.
        let legal0 = engine.legalIntents(for: Seat(0), in: state)
        #expect(!legal0.isEmpty, "play resumes after a rejected claim")
    }

    /// A voter that has already voted is no longer pending (regression: a
    /// multi-voter claim advertised every voter as pending, and a bot lane
    /// parked on a voted seat whose legalIntents are empty — the P3.7 UI
    /// hang). While a claim is pending, only un-voted voters appear.
    @Test static func pendingClaimWaitsOnlyOnUnvotedVoters() throws {
        let engine = euchreEngine(
            claims: TrickPlayParams.ClaimsSpec(
                enabled: ExprRef(pointer: "/test/claims", source: "true"),
                by: .seat(Seat(0)),
                acceptedBy: ExprRef(pointer: "/test/claims/acceptedBy", source: "['S2', 'S3']"),
                ruleId: "euch.claims"))
        var state = try engine.start(seed: 7).state
        state = try engine.apply(
            Action(seat: Seat(0), intent: .claim(6), expectedVersion: state.version), to: state
        ).state
        // Both voters are pending before any vote.
        var pending = engine.pendingSeats(in: state)
        #expect(pending.contains(Seat(1)) && pending.contains(Seat(2)))
        // Seat 1 votes accept; now only Seat 2 is pending.
        state = try engine.apply(
            Action(seat: Seat(1), intent: .acceptClaim(true), expectedVersion: state.version), to: state
        ).state
        pending = engine.pendingSeats(in: state)
        #expect(!pending.contains(Seat(1)), "a voted seat is no longer pending")
        #expect(pending.contains(Seat(2)), "the remaining voter is still pending")
    }

    // MARK: - untilHandsEmpty completion

    /// A two-hand game with `untilHandsEmpty` completes when both hands
    /// are empty and the engine advances past the trick phase (regression:
    /// the stall where pending seats persisted with empty hands).
    @Test static func untilHandsEmptyAdvancesPastTrickPhase() throws {
        let deal = AnyMechanic(
            DealMechanic.self,
            params: DealParams(
                source: "stock",
                packets: [DealPacket(to: Seat(0), each: 2), DealPacket(to: Seat(1), each: 2)],
                shuffleFirst: false,
                deckFaces: [
                    CardFace(suit: .spades, rank: Rank("A")),
                    CardFace(suit: .spades, rank: Rank("K")),
                    CardFace(suit: .hearts, rank: Rank("A")),
                    CardFace(suit: .hearts, rank: Rank("K")),
                ]))
        let trick = AnyMechanic(
            TrickPlayMechanic.self,
            params: TrickPlayParams(
                seatCount: 2,
                tricks: .untilHandsEmpty,
                follow: TrickPlayParams.Follow(mustFollow: true, ruleId: "mini.follow"),
                firstLeader: .seat(Seat(1)),
                winner: .highestOfLed))
        let engine = Engine(
            phases: [
                PhaseConfig(id: "deal", mechanic: deal),
                PhaseConfig(id: "tricks", mechanic: trick),
            ],
            seatCount: 2)
        var state = try engine.start(seed: 11).state
        for _ in 0..<4 {
            var acted = false
            for seatRaw in 0..<2 {
                let legal = engine.legalIntents(for: Seat(seatRaw), in: state)
                if let intent = legal.first {
                    state = try engine.apply(
                        Action(seat: Seat(seatRaw), intent: intent, expectedVersion: state.version), to: state
                    )
                    .state
                    acted = true
                    break
                }
            }
            if !acted, state.phase.phaseID != "done" {
                Issue.record("stalled in phase \(state.phase.phaseID)")
                return
            }
        }
        #expect(state.phase.phaseID == "done", "the engine advanced past trick play")
    }

}
