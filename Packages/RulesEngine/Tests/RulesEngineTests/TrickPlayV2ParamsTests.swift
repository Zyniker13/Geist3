import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

// Trick-play v2 parameter/extension tests (S6), split from
// TrickPlayV2Tests.swift to keep each type body under the lint limit.
// The helpers live on the same type, in TrickPlayV2Tests.swift.
extension TrickPlayV2Tests {
    /// `activeSeats` limits who participates: skipped seats are never
    /// pending, their legality is empty, and a two-seat deal still counts
    /// every played trick.
    @Test static func activeSeatsExcludeSeatsFromTricks() throws {
        let engine = euchreEngine(
            trickCount: 2, activeSeats: .seats([Seat(0), Seat(2), Seat(3)]))
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))

        #expect(try engine.legalIntents(for: Seat(1), in: state).isEmpty, "S1 is not active")
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "A"))
        #expect(try engine.legalIntents(for: Seat(1), in: state).isEmpty)
        let afterOne = try #require(trickSub(state))
        #expect(afterOne.tricksWon[2] == 1, "the club ace wins the all-club trick")
        #expect(afterOne.trickIndex == 1)
        #expect(afterOne.leader == Seat(2), "the winner leads trick 2")

        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "K"))
        #expect(try engine.legalIntents(for: Seat(1), in: state).isEmpty)
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "K"))
        let events = try playEvents(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "10"))
        #expect(
            events.contains {
                if case .trickWon(let seat, _) = $0 { return seat == Seat(2) }
                return false
            },
            "the king of clubs wins the second trick")
        #expect(state.phase.phaseID == "done", "two tricks completed the phase")
    }

    /// `firstLeader` may name a seat by expression.
    @Test static func firstLeaderFromExpression() throws {
        let engine = euchreEngine(
            firstLeader: .expr(ExprRef(pointer: "/t/fl", source: "fixedS4")))
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        #expect(sub.leader == Seat(3), "the expression picked seat 4")
        #expect(!engine.legalIntents(for: Seat(3), in: state).isEmpty)
    }

    /// `nextLeader` may override the seat that follows the trick winner.
    @Test static func nextLeaderFromExpression() throws {
        let engine = euchreEngine(nextLeader: ExprRef(pointer: "/t/nl", source: "fixedS4"))
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "A"))
        let after = try #require(trickSub(state))
        #expect(after.tricksWon[1] == 1, "the trump ace wins the trick")
        #expect(after.leader == Seat(3), "the nextLeader expression overrides the winner")
    }

    /// `winner: .custom` resolves the trick from the plays list.
    @Test static func winnerFromCustomExpression() throws {
        let engine = euchreEngine(
            winner: .custom(ExprRef(pointer: "/t/w", source: "secondPlayer")))
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "J"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "s", rank: "9"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "10"))
        let after = try #require(trickSub(state))
        #expect(after.tricksWon[1] == 1, "the second player always wins")
        #expect(after.leader == Seat(1))
    }

    /// `trump` may come from an expression evaluated at phase entry.
    @Test static func trumpSuitFromExpression() throws {
        let engine = euchreEngine(trump: .expr(ExprRef(pointer: "/t/trump", source: "dealTrump")))
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        #expect(sub.trumpSuit == "s", "the deal expression fixed spades as trump")
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "A"))
        let after = try #require(trickSub(state))
        #expect(after.tricksWon[3] == 1, "the spade ace outranks everything non-trump")
    }

    /// A trump expression the runtime cannot answer fails at phase entry
    /// with an engine fault that points at the parameter.
    @Test static func trumpExpressionFaultPointsAtParameter() throws {
        let engine = euchreEngine(trump: .expr(ExprRef(pointer: "/t/trump", source: "junk")))
        let v = violation { _ = try engine.start(seed: 7) }
        #expect(v?.hasPrefix("engineFault") == true, "expected an engine fault, got: \(v ?? "none")")
        #expect(v?.contains("/phases/trick-play/trump") == true, "the fault points at the trump parameter: \(v ?? "")")
    }

    /// `suitOf` reclassifies cards for follow and winner logic together —
    /// the euchre left bower plays as trump even when it is the jack of a
    /// different colour's suit.
    @Test static func suitOfReclassifiesLeftBower() throws {
        let params = TrickPlayParams(
            seatCount: 4,
            tricks: .count(2),
            orderRanks: ["9", "10", "J", "Q", "K", "A"],
            follow: TrickPlayParams.Follow(mustFollow: true, ruleId: "t.follow"),
            suitOf: ExprRef(pointer: "/t/suitOf", source: "leftBower"),
            trump: .suit("d"),
            winner: .highestTrumpElseLed)
        let engine = miniEngine(
            pops: [
                [("c", "9"), ("c", "J"), ("h", "J"), ("h", "10")],
                [("d", "9"), ("d", "10"), ("s", "9"), ("s", "10")],
                [("c", "A"), ("c", "Q"), ("h", "Q"), ("h", "9")],
                [("s", "A"), ("s", "Q"), ("s", "J"), ("s", "10")],
            ], params: params)
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "9"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "A"))
        let afterOne = try #require(trickSub(state))
        #expect(afterOne.tricksWon[1] == 1, "the d9 is the highest trump")
        #expect(afterOne.leader == Seat(1))

        // Leading trump drags the hJ (the left bower) out of S0, and only
        // the hJ satisfies the follow rule: it reclassifies as a diamond.
        // S1 won trick 1, so trick 2 runs S1 → S2 → S3 → S0.
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "10"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "h", rank: "Q"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "Q"))
        let hJ = card(state, Seat(0), suit: "h", rank: "J")
        let legalCards = engine.legalIntents(for: Seat(0), in: state).map { intent -> UInt16 in
            if case .play(let id) = intent { return id.raw }
            return UInt16.max
        }
        #expect(legalCards == [hJ.raw], "only the reclassified hJ follows the trump lead")
        let events = try playEvents(engine, &state, Seat(0), hJ)
        #expect(
            events.contains {
                if case .trickWon(let seat, _) = $0 { return seat == Seat(0) }
                return false
            },
            "the left bower outranks the real trump")
        #expect(state.phase.phaseID == "done", "two tricks completed the phase")
    }

    /// `strength` replaces the rank order for every comparison, so a
    /// "pet card" expression can beat even the highest trump.
    @Test static func strengthExpressionReordersTrick() throws {
        let params = TrickPlayParams(
            seatCount: 4,
            tricks: .count(1),
            orderRanks: ["9", "10", "J", "Q", "K", "A"],
            follow: TrickPlayParams.Follow(mustFollow: true, ruleId: "t.follow"),
            strength: ExprRef(pointer: "/t/strength", source: "spadeAceBeatsAll"),
            trump: .suit("d"),
            winner: .highestTrumpElseLed)
        let engine = miniEngine(
            pops: [
                [("c", "9"), ("c", "J"), ("h", "A"), ("h", "10")],
                [("d", "A"), ("d", "9"), ("s", "9"), ("s", "10")],
                [("c", "A"), ("c", "Q"), ("h", "Q"), ("h", "9")],
                [("s", "A"), ("s", "Q"), ("s", "J"), ("s", "10")],
            ], params: params)
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        let events = try playEvents(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "A"))
        #expect(
            events.contains {
                if case .trickWon(let seat, _) = $0 { return seat == Seat(3) }
                return false
            },
            "the expression made the spade ace worth 100")
        #expect(state.phase.phaseID == "done")
    }

    /// `mustOvertrump` forces a player who ruffs to beat the best trump so
    /// far, even from a void suit.
    @Test static func mustOvertrumpForcesHigherTrump() throws {
        let params = TrickPlayParams(
            seatCount: 3,
            tricks: .count(1),
            orderRanks: ["9", "10", "J", "Q", "K", "A"],
            follow: TrickPlayParams.Follow(mustFollow: true, mustOvertrump: true, ruleId: "t.over"),
            trump: .suit("d"),
            winner: .highestTrumpElseLed)
        let engine = miniEngine(
            pops: [[("h", "A"), ("s", "9")], [("d", "10"), ("c", "9")], [("d", "9"), ("d", "A")]],
            params: params)
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "h", rank: "A"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "10"))
        let legal = engine.legalIntents(for: Seat(2), in: state).map { intent -> UInt16 in
            if case .play(let id) = intent { return id.raw }
            return UInt16.max
        }
        #expect(legal == [card(state, Seat(2), suit: "d", rank: "A").raw], "only the higher trump is legal")
        let v = violation {
            try play(engine, &state, Seat(2), card(state, Seat(2), suit: "d", rank: "9"))
        }
        #expect(v?.contains("t.over") == true, "the lower trump was rejected: \(v ?? "none")")
        let events = try playEvents(engine, &state, Seat(2), card(state, Seat(2), suit: "d", rank: "A"))
        #expect(
            events.contains {
                if case .trickWon(let seat, _) = $0 { return seat == Seat(2) }
                return false
            },
            "the higher trump won")
        #expect(state.phase.phaseID == "done")
    }

    /// `mustHeadTrick` forces a player who still holds the led suit to
    /// either follow or beat the current best card of that suit.
    @Test static func mustHeadTrickForcesBeatingLedSuit() throws {
        let params = TrickPlayParams(
            seatCount: 4,
            tricks: .count(1),
            orderRanks: ["9", "10", "J", "Q", "K", "A"],
            follow: TrickPlayParams.Follow(mustFollow: true, mustHeadTrick: true, ruleId: "t.head"),
            winner: .highestOfLed)
        let engine = miniEngine(
            pops: [
                [("c", "10"), ("c", "9"), ("h", "A"), ("h", "K")],
                [("d", "A"), ("d", "K"), ("d", "9"), ("s", "9")],
                [("c", "A"), ("c", "9"), ("h", "Q"), ("h", "J")],
                [("s", "A"), ("s", "K"), ("s", "10"), ("h", "9")],
            ], params: params)
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "10"))
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))
        let legal = engine.legalIntents(for: Seat(2), in: state).map { intent -> UInt16 in
            if case .play(let id) = intent { return id.raw }
            return UInt16.max
        }
        #expect(legal == [card(state, Seat(2), suit: "c", rank: "A").raw], "only the club ace beats the led c10")
        let v = violation {
            try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "9"))
        }
        #expect(v?.contains("t.head") == true, "the small club was rejected: \(v ?? "none")")
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        let events = try playEvents(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "A"))
        #expect(
            events.contains {
                if case .trickWon(let seat, _) = $0 { return seat == Seat(2) }
                return false
            },
            "the club ace heads the trick")
        #expect(state.phase.phaseID == "done")
    }

    /// `mustTrumpIfVoid` forces void players to ruff instead of discarding.
    @Test static func mustTrumpIfVoidForcesRuff() throws {
        let engine = euchreEngine(
            follow: TrickPlayParams.Follow(mustFollow: true, mustTrumpIfVoid: true, ruleId: "euch.follow"))
        var state = try engine.start(seed: 7).state
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        let legal = engine.legalIntents(for: Seat(1), in: state).map { intent -> UInt16 in
            if case .play(let id) = intent { return id.raw }
            return UInt16.max
        }
        #expect(legal.count == 5, "void in clubs, so every diamond ruff is legal")
        let v = violation {
            try play(engine, &state, Seat(1), card(state, Seat(1), suit: "s", rank: "9"))
        }
        #expect(v?.contains("euch.follow") == true, "the spade discard was rejected: \(v ?? "none")")
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))
    }

    /// `leadAllowed` guards the opening lead of a trick.
    @Test static func leadAllowedGuardRestrictsOpeningLead() throws {
        let engine = euchreEngine(
            firstLeader: .seat(Seat(1)),
            leadAllowed: TrickPlayParams.PlayGuard(
                expr: ExprRef(pointer: "/t/lead", source: "noTrumpLead"),
                otherwise: "no leading trump",
                ruleId: "t.lead"))
        var state = try engine.start(seed: 7).state
        let legal = engine.legalIntents(for: Seat(1), in: state).map { intent -> UInt16 in
            if case .play(let id) = intent { return id.raw }
            return UInt16.max
        }
        #expect(legal == [card(state, Seat(1), suit: "s", rank: "9").raw], "the lone non-trump card is the only lead")
        let v = violation {
            try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))
        }
        #expect(
            v?.contains("t.lead") == true && v?.contains("no leading trump") == true,
            "the guard rejected a diamond lead: \(v ?? "none")")
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "s", rank: "9"))
    }

    /// `playAllowed` guards every follow, and is checked even when the
    /// follow rule would have allowed a discard.
    @Test static func playAllowedGuardRestrictsFollows() throws {
        let engine = euchreEngine(
            playAllowed: TrickPlayParams.PlayGuard(
                expr: ExprRef(pointer: "/t/play", source: "noTrumpFollow"),
                otherwise: "no trump on follow",
                ruleId: "t.play"))
        var state = try engine.start(seed: 7).state
        let sub = try #require(trickSub(state))
        try play(engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        let legal = engine.legalIntents(for: Seat(1), in: state).map { intent -> UInt16 in
            if case .play(let id) = intent { return id.raw }
            return UInt16.max
        }
        #expect(legal == [card(state, Seat(1), suit: "s", rank: "9").raw], "the void seat must discard non-trumps")
        let v = violation {
            try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))
        }
        #expect(
            v?.contains("t.play") == true && v?.contains("no trump on follow") == true,
            "the guard rejected the ruff: \(v ?? "none")")
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "s", rank: "9"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        try play(engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "K"))
        let after = try #require(trickSub(state))
        #expect(after.tricksWon[2] == 1, "the club ace still wins without trump in play")
    }

    /// `onCardPlayed` and `onTrickEnd` effects fire with their bindings.
    @Test static func effectsFirePerCardAndPerTrick() throws {
        let engine = euchreEngine(
            onCardPlayed: [EngineEffect.emit(name: "cardPlayed")],
            onTrickEnd: [EngineEffect.emit(name: "trickEnd")])
        var state = try engine.start(seed: 7).state
        let firstEvents = try playEvents(
            engine, &state, Seat(0), card(state, Seat(0), suit: "c", rank: "9"))
        #expect(
            firstEvents.contains {
                if case .emitted("cardPlayed") = $0 { return true }
                return false
            },
            "the card effect fired on the first play")
        try play(engine, &state, Seat(1), card(state, Seat(1), suit: "d", rank: "A"))
        try play(engine, &state, Seat(2), card(state, Seat(2), suit: "c", rank: "A"))
        let endEvents = try playEvents(
            engine, &state, Seat(3), card(state, Seat(3), suit: "s", rank: "A"))
        #expect(
            endEvents.contains {
                if case .emitted("trickEnd") = $0 { return true }
                return false
            },
            "the trick effect fired when the trick completed")
    }

    /// A dummy controlled by its own seat is a configuration fault.
    @Test static func dummySelfControlIsRejected() throws {
        let engine = euchreEngine(
            dummy: TrickPlayParams.DummySpec(
                seat: .seat(Seat(3)),
                revealAfter: .immediately,
                controlledBy: .seat(Seat(3))))
        let v = violation { _ = try engine.start(seed: 7) }
        #expect(v?.hasPrefix("engineFault") == true, "expected an engine fault, got: \(v ?? "none")")
        #expect(v?.contains("controlledBy") == true, "the fault points at the controller: \(v ?? "")")
    }

    /// A dummy outside the active seat list is a configuration fault.
    @Test static func dummyOutsideActiveSeatsIsRejected() throws {
        let engine = euchreEngine(
            dummy: TrickPlayParams.DummySpec(
                seat: .seat(Seat(0)),
                revealAfter: .immediately,
                controlledBy: .seat(Seat(2))),
            activeSeats: .seats([Seat(2), Seat(3)]))
        let v = violation { _ = try engine.start(seed: 7) }
        #expect(v?.contains("dummy/seat") == true, "the fault points at the dummy seat: \(v ?? "none")")
    }

    /// Repeated seats in `activeSeats` are rejected.
    @Test static func duplicateActiveSeatsAreRejected() throws {
        let engine = euchreEngine(activeSeats: .seats([Seat(0), Seat(0)]))
        let v = violation { _ = try engine.start(seed: 7) }
        #expect(v?.contains("activeSeats") == true, "the fault points at the seat list: \(v ?? "none")")
    }

    /// A first leader outside the active seat list is rejected.
    @Test static func firstLeaderOutsideActiveSeatsIsRejected() throws {
        let engine = euchreEngine(
            activeSeats: .seats([Seat(2), Seat(3)]),
            firstLeader: .seat(Seat(0)))
        let v = violation { _ = try engine.start(seed: 7) }
        #expect(v?.contains("firstLeader") == true, "the fault points at the leader: \(v ?? "none")")
    }
}
