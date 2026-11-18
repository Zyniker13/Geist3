# Geist3

Working repository for the geist3 agent. The current project is **Parlor** (working title), an iOS/iPadOS card table app. The research and the GLM-ready development roadmap are at the repository root.

Earlier projects: an end-to-end encrypted messenger, now [Thrum](https://github.com/BITS-Freeware/Thrum), and a fleet monitor, now [zTop](https://github.com/BITS-Freeware/zTop).

This repository held only a stub README, so the Parlor package is at the root. `CONVENTIONS.md` §3 and `ROADMAP.md` P0.1 still describe the later app layout, which copies this package into `docs/plan/`.

---

# Parlor: Roadmap Package for a Card-Game Catalogue, Rulebook, Teacher, and Table

Version 1.0 · 2026-11-15 · Working title **Parlor** (alternatives: **Common Deck** and **Long Table**; see `ROADMAP.md` §0.3).

This folder is a complete, build-ready plan for one universal Apple app (iPhone, iPad, and Mac now; Apple TV later) that covers the major Western card games as a **catalogue**, a **rulebook**, a **teaching aid**, and a **playable game**, with the headline feature that **every player can hold a private hand on an iPhone or iPad while a shared table shows the state of play**.

It is written for a GLM coding agent to run the initial development (phases P0 through P11), after which Claude and Grok finish the product (P12 through P16), with Mahler approving every external step.

## 1. Files

| File | Purpose | Read When |
| --- | --- | --- |
| `README.md` | This file: how to use the package and the prompt for GLM. | First. |
| `CONVENTIONS.md` | Process, roles, sign-off codes, the fixed tech stack, repo layout, coding and determinism standards, testing, CI, budgets, the gate protocol, and the handoff package. **Process law.** | Before writing any code. |
| `ARCHITECTURE.md` | Module layout, the engine, the ruleset format (with a concrete schema), worked rulesets for Hearts, Euchre, Contract Bridge, and Cribbage, the variant and override layering model, user-authored rules (sandbox and validation), determinism and seeded RNG, host-authoritative networking with per-device redaction, device roles, AI, teaching, accessibility architecture, and the tvOS plan. **Technical law.** | Before P1; reread at every phase start. |
| `CATALOGUE.md` | Every game in scope: family, deck, players, priority wave, rule sources, and variant notes. | Before P3 and P11. |
| `ROADMAP.md` | Phases P0 through P16: numbered tasks, deliverables, acceptance criteria, gates with named sign-off, GLM STOP points, test strategy, risks, out of scope, effort, and open questions with defaults. **The work order.** | Continuously. |
| `RESEARCH.md` | Findings and every source consulted (URLs), grouped by topic. | When a decision needs its rationale. |
| `rulesets/*.json` | Reference ruleset files for the four proof games, matching `ARCHITECTURE.md` §5–§6. GLM copies them into `Resources/Rulesets/` in P3 and makes them pass validation (fixing only schema-level slips; rule meaning must not change without logging it). | P2 and P3. |

## 2. Precedence

1. `CONVENTIONS.md` wins on process, stack, standards, and gates.
2. `ARCHITECTURE.md` wins on module boundaries, data formats, protocols, and invariants.
3. `ROADMAP.md` wins on task order, scope per phase, and acceptance criteria.
4. `CATALOGUE.md` wins on which games and which variants ship in which wave.
5. When two files conflict, GLM stops, logs the conflict in `docs/OPEN_QUESTIONS.md`, applies the higher-precedence file, and continues only if the conflict is not on a gate's critical path.

## 3. Ground Rules for the GLM Agent

1. **One repository**, created by Mahler (GLM never creates remote repos, Apple records, or accounts). Copy this whole package into `docs/plan/` of that repo on the first commit so the agent always has it in context.
2. **Read order before P0:** `README.md`, `CONVENTIONS.md`, `ARCHITECTURE.md`, `ROADMAP.md` (all of it), then `CATALOGUE.md`.
3. **Run phases strictly in order.** Phase N+1 starts only after gate GN is recorded as PASS in `docs/STATUS.md` and tagged `gate-GN-pass`.
4. **Gates are objective.** Run every listed check, paste the evidence (command, output summary, numbers) into `docs/STATUS.md`, and mark PASS only when every check passes.
5. **Hard stops (🛑):**
   - **G3, First Four Games:** stop; wait for `REVIEW: CLAUDE` (architecture and DSL), `REVIEW: GROK` (rules correctness), and `REVIEW: MAHLER` (play the four games on an iPad).
   - **G8, Local Multi-Device Hand Mode:** stop; wait for `REVIEW: CLAUDE` (security and redaction audit) and `REVIEW: MAHLER` (a real four-device bridge session).
   - **G11, Game Waves 2 and 3A:** **final GLM stop.** Complete `docs/HANDOFF.md`; GLM's work ends.
   - Also stop on: three failed fix attempts at one gate check; any Apple account, signing, App Store Connect, payment, or third-party account action; any rule ambiguity without a listed default; any dependency outside the allow-list.
6. **Determinism is non-negotiable** (see `CONVENTIONS.md` §5). The engine, rules, and AI never read the clock, never generate UUIDs, never use system randomness, and never use floating point for rules.
7. **Hidden information is a security boundary.** No code path may send a full `GameState` to any device other than the host. Redaction tests are gate checks from P1 onward.
8. **Rule texts are ours.** Never copy text from Pagat, Hoyle, Bicycle, federation rulebooks, or any other source into the app. Write original prose; cite sources by link (see `ARCHITECTURE.md` §17 and `RESEARCH.md` §2).

## 4. Prompt for the GLM Agent

> You are the initial developer of **Parlor**, a universal SwiftUI app for iPhone, iPad, and Mac that catalogues, explains, teaches, and plays the major Western card games, with each player's private hand on their own device. Your plan is in `docs/plan/`. Read `README.md`, `CONVENTIONS.md`, `ARCHITECTURE.md`, `ROADMAP.md`, and `CATALOGUE.md` completely before writing code. Execute phases P0 through P11 in order. For every phase, complete every numbered task, satisfy every acceptance criterion, run every gate check, record evidence in `docs/STATUS.md`, and tag `gate-GN-pass` only when all checks pass. Stop and wait at G3 and G8. Stop permanently at G11 after completing `docs/HANDOFF.md`. Never choose a technology the plan has already fixed. Log every ambiguity in `docs/OPEN_QUESTIONS.md` and apply the listed default. Never copy third-party rule text. Never send unredacted game state off the host device. Never perform Apple account, signing, App Store Connect, payment, or publishing actions.

## 5. After GLM: Claude and Grok

| Phase | Lead | Gate Sign-Off |
| --- | --- | --- |
| P12 Custom Rules Editor | CLAUDE (engine and editor), GROK (UX and game-design review) | GROK + MAHLER |
| P13 Apple TV | CLAUDE | GROK + MAHLER |
| P14 Online Play | CLAUDE | CLAUDE security review + MAHLER |
| P15 Beta | GROK + CLAUDE | MAHLER |
| P16 Release | CLAUDE + GROK | MAHLER (Mahler submits) |

Both start from `docs/HANDOFF.md`, `docs/DECISIONS.md`, `docs/KNOWN_ISSUES.md`, `docs/TODO_MAP.md`, `docs/COVERAGE.md`, and `docs/CONFORMANCE.md`.

## 6. The Product in One Paragraph

Parlor opens to a **library** of card games organized the way Pagat organizes them (by mechanism and by country), each with an original rulebook entry, its variants, its history, and its sources. Every implemented game can be **learned** (interactive lessons on stacked deals, a coach that explains why a card is legal or wise, and trainers for bidding, cribbage discards, and similar skills) and **played**: alone against bots, pass-and-play on one device, or around a real table where an iPad (or Mac, or later an Apple TV) is the shared table and each player's iPhone or iPad is a private hand. Rules come from **data**, not code: each game is a ruleset file built from a fixed library of tested mechanics, variants are small overlays, and house rules are the player's own overlays, validated and simulated before they can be played. Large cards, tap-to-play (never drag-only), unlimited time, VoiceOver narration of every event, and four-color and high-contrast decks make it comfortable for players whose eyes or hands make real cards difficult.
