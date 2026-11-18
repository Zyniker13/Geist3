# HANDOFF

Purpose: the handoff package required at every 🛑 stop (`docs/plan/CONVENTIONS.md` §10): state, what works and what does not, architecture deltas, fragile areas, rule decisions, metrics, next steps, and a 10-minute reviewer script. Sections 1–3 and 7 are refreshed at every phase close; the full package is required at the G3, G8, and G11 stops.

1. **State:** P0 and P1 complete (G0, G1 gates; evidence in `STATUS.md`). P1 delivers CardModel (decks, seats, faces), SeededRNG (xoshiro256**), engine core (`GameState`, zones, knowledge, vars, phase cursor), the reducer (`Engine.start/apply/legalIntents`), the toy game mechanics (`deal`, `trick-play`), post-shuffle card IDs, `Observation`/`Redactor`, replays with 20 golden fixtures + SHA-256 final-state hash, and the perf harness. Next: P2 (Ruleset DSL, CardExpr, overlays, validator).

2. **What works:** deck catalog round-trips and per-deck contents (8/8 CardModel tests); deterministic engine across 10,000-seed toy games; card-conservation invariant enforced in `ZoneStore.move`; hidden-information boundary byte-scan-verified (0 leaks over 2,000 games, every viewer kind); 20 golden replays with stable SHA-256 hashes on macOS (iOS-simulator leg: `make test-replays-ios`); perf p99 apply 10.8 µs / observation 13.4 µs (budgets: 1 ms / 0.5 ms); lint (SwiftLint main+pure, swift-format, check-imports) at 0 violations.

3. **What does not:** see `KNOWN_ISSUES.md`. Note KI-1: macOS UI-test leg excluded from `test-apps` (ADR-0022) pending a one-time TCC approval — required again from G9. Rulesets are Swift-configured only until P2; JSON rulesets, DSL, validator, and real games land in P2–P3.

4. **Architecture deltas:** see `DECISIONS.md`.

5. **Fragile areas:** golden-replay hashes are sensitive to any change in serialized engine state (canonical Codable encodings, RNG JSON keys `s0`–`s3` kept stable across internal renames via explicit `CodingKeys`) — any engine-state field change requires regenerating the 20 fixtures with `Tools/make-golden-replays.sh` and justifying the hash change in `STATUS.md`. `@_spi(HostOnly)` is load-bearing for test/CLI access to host-only APIs; `swift-format` strips duplicated imports, so test files must import via SPI only (no `@testable` alongside).

6. **Rule decisions:** see `OPEN_QUESTIONS.md`.

7. **Metrics:** see `COVERAGE.md` (G1: CardModel 94.3%, RulesEngine 97.3%, ToyGame 96.6%), `PERF.md` (P1.8 harness), `SECURITY.md` (G1: 0 leaks / 2,000 games), `CONFORMANCE.md`.

8. **Next steps:** P2.1 CardExpr lexer/parser onward; G1's async review is `REVIEW: CLAUDE` on the engine API (fires post-gate, non-blocking).

9. **How to verify:** `make gate PHASE=P1` (bootstrap, lint, 13 package suites, coverage threshold ≥90% for CardModel/RulesEngine, profraw collection, conformance/validate/sim/fuzz/snapshot stubs, 3 build legs, `test-apps` on iPhone 17 + iPad Pro 13-inch, `test-replays-ios` on iPhone 17). Toolchain: Xcode with `swift-tools-version: 6.0`, xcodegen, swiftlint, swift-format (see `docs/plan/CONVENTIONS.md` §7).
