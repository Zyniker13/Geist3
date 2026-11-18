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

### P0.Z Gate G0 run — BLOCKED on simulator environment (2026-11-18)

Work completed since the first failed gate run (`g0-gate.log`, Error 65 at `test-apps`):
- Root cause of the original failure: the plan-named `Accessibility` package collides with Apple's `Accessibility.framework` during the `XCUIAutomation` module build for UI-test targets. Explicit and implicit module modes both fail. Fixed by renaming the package to `A11yKit` (ADR-0021); all references updated (`project.yml`, `Makefile`, `Tools/check-imports.sh`, `.swiftlint.yml`, docs).
- `make test-packages` → 13/13 suites pass (`g0-fix6.log`, `TEST-PACKAGES EXIT: 0`).
- `make build` → all three legs green, `** BUILD SUCCEEDED **` ×3 (`p02-build.log`, exit 0; only 2 `appintentsmetadataprocessor` warnings).
- UI-test API fix: `XCUIApplication.isRunning` was removed in the iOS 27.2 SDK; `UITests/ParlorUITests.swift` now asserts `app.state != .notRunning` (compiles clean).
- App targets: `GENERATE_INFOPLIST_FILE: YES` + explicit `CFBundleIdentifier` in `App/iOS/Info.plist` and `App/macOS/Info.plist` (fixed missing-`CFBundleExecutable` install failure).

Partial gate evidence (`g0-evidence.log`, 2026-11-18 03:21–03:23):
- `make bootstrap lint test-packages coverage conformance validate sim N=200 fuzz-quick snapshot build` → **exit 0, all green** (PARTIAL-GATE EXIT: 0). Every G0 check except the two iOS simulator test legs passes.
- `xcodebuild test -scheme Parlor-macOS`: unit tests passed (`Test Suite 'All tests' passed`, 03:22:09); the macOS UI-test runner then failed with "Timed out while enabling automation mode" (XCTFuture Code=1000) and the build hung in teardown (killed; same wedged automation stack, not a project failure).

**Blocked — environment, not project.** The host's iOS simulator stack cannot boot any device to SpringBoard, so no iOS app can install/launch and no iOS test (unit or UI) can run. Repair attempts on 2026-11-18, all failed:
1. Erase + reboot of `iPhone 17` → `xcodebuild test` hung at test-runner install (`g0-fix17.log`, Mach -308 earlier in `g0-fix16.log`).
2. `killall` + restart of `com.apple.CoreSimulator.CoreSimulatorService`; fresh device `Parlor-iPhone` → `simctl install` worked once, `simctl launch` hung; service wedged again afterward.
3. `simctl runtime dyld_shared_cache update --force` → no effect.
4. Full re-download of the iOS 27.2 runtime build 24B8117 (8.32 GB, verified by the installer) after deleting the old runtime; fresh `iPhone 17` + `iPad Pro 13-inch (M5)` devices → first boot stuck at the Apple-logo progress bar (~40% → ~90% over 35 min, then the device shut itself down mid-boot). A `(Seed)` runtime `24B91016s` fetched by an unqualified `-downloadPlatform iOS` was deleted (incompatible with this Xcode's device types); the correct `-buildVersion 24B8117` runtime is installed and Ready.
5. Retry of the interrupted first boot → frozen at the boot logo for 12+ min, watcher stopped.

Not attempted (needs Mahler): rebooting the Mac. A host reboot is the standard remaining fix for a wedged CoreSimulator/XPC automation stack; nothing else in the environment is suspect (89 GB free disk, runtime verified fresh, device types present).

- `make gate PHASE=P0` full sequence: pending on the simulator fix (the two iOS `test-apps` legs; everything else has passing evidence above).
- Push to `main` + CI green: pending.
