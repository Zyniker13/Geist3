# G3 Review — Claude (engine and DSL architecture)

**Verdict: REVIEW: CLAUDE — PASS, with one required fix (R1) that must land before P4 starts.**

Reviewed at `4245dfe` on `phase/P3-first-four-games` (the engine, rulesets and app are unchanged through `7994ece`/`69188fc` per G3-REQUEST). Scope per `docs/reviews/G3-REQUEST.md`: mechanic generality for Waves 2–3, expression readability, redaction soundness, and the listed rough edges. I read the reducer (`Engine.swift`), the `Mechanic` protocol, `Knowledge`/`Observation`/`Redactor`, `DealMechanic`, `ExchangePassMechanic`, and the Hearts and Bridge rulesets. I did not run `make gate`; CI evidence is taken from STATUS.

## Required

**R1. Card IDs leak the original holder of passed and discarded cards.** §9.5 assigns `CardID`s after the shuffle *in dealing order* (`DealMechanic.enter`, `nextID` counting up per packet). Packets go to seats in a fixed order, so an ID maps deterministically to the seat it was dealt to. When a card later becomes public (played to a trick, or shown in the crib), every viewer can read its ID and work out who was originally dealt it. In Hearts that tells the third and fourth players exactly which cards were passed between the other two, which they must not know; in Cribbage it tells everyone who discarded each crib card. `Redactor` and the byte-scan tests check faces, not ID-to-seat inference, so nothing catches it today.
Fix: assign IDs from a per-deal random permutation of `0..<deckSize` drawn from the state RNG (deterministic, so replays still match), and update §9.5 to say IDs are uncorrelated with deal order as well as face. Add a property test: over N seeded Hearts deals, the ID of each passed card is uniformly distributed relative to the passer.

## Recommended (not blocking)

1. **Single-source legality.** `Engine.applyUnchecked` checks `pendingSeats` but trusts each mechanic's `apply` to reject anything outside `legalIntents`. That mirroring is the invariant the P3.7 hang broke. Either check `legalIntents(for:in:).contains(intent)` in the engine before `act` (cheap at card-game sizes; open-ended intents like `count(points:)` can be matched by kind), or add a generic property test run over every ruleset in the sim: every legal intent applies without `illegal`, and a sampled non-legal intent is rejected, and `pendingSeats` is non-empty iff some seat has a legal intent.
2. **Bound the auto-step loop.** `advanceIfAutomaticInner` loops on `.autoStep` with no step cap, unlike the phase-gate loop just below it. A mechanic whose `step` never changes its completion outcome hangs the host. Add a step budget (for example `deckSize × phases.count`) that throws `engineFault`.
3. **Native scoring functions.** Bridge (`bridge.score`, `bridge.honors`) and Cribbage (`cribbage.handScore`, `cribbage.pegPoints`) put their scoring in Swift natives. That's a reasonable call for these two, and it keeps the expressions readable, but it means Waves 2–3 should budget a native per scoring-heavy game or grow the DSL's aggregation primitives. Worth an ADR stating the rule for when a native is allowed.
4. **`VarStore.add` ignores type mismatches silently** ("P2 validator owns this"). P2 is done; make a mismatch an `engineFault` so a validator gap surfaces instead of skipping a score.
5. **The conformance stacked-deck override as SPI (ADR-0037)** is fine for now; keep it out of the shipping app target, as `check-imports` already enforces.

## What's solid

- The `Mechanic` protocol (enter / legalIntents / apply / isComplete / pendingSeats / step) is small and general enough for trick, auction, exchange, count-play and show phases; twelve mechanics cover four quite different games without special cases in the reducer.
- Redaction is structurally sound apart from R1: knowledge is monotone within a deal, zone-entry grants (ADR-0038) are applied at every transition tail, hidden zones expose only counts plus known cards, and stale prior-deal events are dropped before redaction (`firstDealEvent`).
- Determinism: seeded xoshiro RNG, sorted canonical encodings for hashing, and golden replays across macOS and iOS.
- Expressions read well (`teams().exists(t, match.games[t] == 2)`, `zone('taken', s).map(c, penalty(c)).sum()`), with rule IDs tying every phase to the rules documents.
