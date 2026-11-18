# STATUS — Parlor Build Status and Gate Evidence

Purpose: the running log of the Parlor build (phases P0–P11 per `docs/plan/ROADMAP.md`). This file records the current phase, every gate's evidence (command, output summary, numbers, commit SHA — `docs/plan/CONVENTIONS.md` §9), and review sign-offs. Together with `docs/plan/ROADMAP.md` it is the source of truth when session context is lost; read it first.

## Current Phase

**P0 — Setup and Tooling** · branch `phase/P0-bootstrap-tooling` · plan of record: `docs/plan/` (package moved verbatim from the repo root in P0.1; `docs/plan/` is followed and never edited).

## Gate Ledger

| Gate | Phase | Mode | Status | Evidence |
| --- | --- | --- | --- | --- |
| G0 | P0 Setup and Tooling | GLM-SELF | pending | below |

## G0 — P0 Setup and Tooling (GLM-SELF) — PENDING

Criteria (`docs/plan/ROADMAP.md` §P0): CI green on both platforms; lint and import checks proven to fail on violations; 20 ADRs recorded; `make gate PHASE=P0` exits 0.

### P0.4 Tooling — evidence

- `make lint` → exit 0, zero violations (SwiftLint 0.65, `.swiftlint.yml` whitelist of App/Tests/UITests + 13 packages' Sources/Tests; `.swiftlint-pure.yml` banned-API rules — `banned-date`, `banned-uuid`, `banned-system-rng`, `banned-random-unseeded` — scoped to the 6 pure packages per CONVENTIONS §5).
- `swift-format lint --strict --recursive .` → exit 0.
- `Tools/check-imports.sh` → exit 0 on clean tree. Proven to fail (exit 1, VIOLATION printed) on three planted classes: banned framework (`import SwiftUI` in CardModel), wrong direction (`import CardAI` in CardModel), `@_spi(HostOnly)` import outside the allow-list (in `App/Shared`). Planted files removed; final clean run exit 0.
- `Tools/rules-cli`, `Tools/net-fuzz`: P0 stubs (no-op with printed notice until P3/P8).
- Note: SwiftLint 0.65 `excluded` does not match subdirectory globs (verified empirically); whitelist approach logged in `docs/OPEN_QUESTIONS.md`.

### P0.5 CI — evidence

- `.github/workflows/ci.yml` written per CONVENTIONS §7: `macos-latest`, 120 min, concurrency group, toolchain report, simulator preflight, `make bootstrap`, `make lint` + `check-imports`, package tests with coverage, app builds (iPhone 17, iPad Pro 13-inch (M5), macOS), app tests, `make validate`, `make conformance`, `make sim N=200`, `make fuzz-quick`, `make snapshot`, artifact upload.
- `reports/` added to `.gitignore` (local artifacts; CI uploads them).
- Green CI run on `main`: pending push (see below).

### P0.6 ADRs — evidence

- `docs/DECISIONS.md` lists ADR-0001–ADR-0020, all status Accepted. ADR-0001 records the exact toolchain (Xcode 27.2, Swift 6.4.2, language mode 6, strict concurrency complete; XcodeGen 2.46.0, SwiftLint 0.65, swift-format). The CONVENTIONS "Xcode 26.x" wording vs. installed Xcode 27.2 stable is logged in `docs/OPEN_QUESTIONS.md` (default applied: latest stable, no betas).

### P0.7 Competitor test sheet — evidence

- `docs/research/COMPETITORS.md` exists: structured checklist (setup steps, time-to-first-card, tap counts, accessibility audit notes, network behavior) for The Card Table, Stillwind Table, Play Table, Trickster, BBO, Funbridge, Card Shark, Accessible Solitaire; comparison table and per-app sections have blank columns and fill-in instructions. To be completed by Mahler or a reviewer on real devices.

### G0 gate run — pending

- `make test` rerun for evidence (background job, in progress at time of writing).
- `make gate PHASE=P0` full sequence: pending.
- Push to `main` + CI green: pending.
