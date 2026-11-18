# OPEN QUESTIONS

Purpose: every ambiguity met during the build, logged with date, phase, the default applied (per `docs/plan/ROADMAP.md` §8), and resolution state. Nothing here blocks work: the listed default applies immediately and play proceeds.

| Date | Phase | Question | Default applied | State |
| --- | --- | --- | --- | --- |
| 2026-11-17 | P0.6 | CONVENTIONS §2 says "latest stable Xcode 26.x" but the build machine has Xcode 27.2 stable (Swift 6.4.2); the plan itself references Xcode 27 (Multipeer deprecation per TN3213) | Use Xcode 27.2 stable (latest stable on the build machine); "do not adopt Xcode 27 betas" is satisfied (27.2 is stable). Recorded in ADR-0001 | Resolved by default; no play/scoring impact |
| 2026-11-17 | P0.4 | SwiftLint 0.65 `excluded` does not match subdirectory globs (`.build/` artifacts inside packages would be linted, 728 false violations) | `.swiftlint.yml` and `.swiftlint-pure.yml` use an `included:` whitelist of source/test dirs instead of `excluded:`; intent (zero warnings, no linting of generated artifacts) preserved | Resolved by default; tooling constraint, not a plan ambiguity |
| 2026-11-17 | P0.Z | Plan mandates package name `Accessibility` (ARCHITECTURE §3), which collides with Apple's `Accessibility.framework` (ships a Swift interface): explicit module builds pin our same-named module into `XCUIAutomation`'s interface compile (target iOS 17.0) and fail the deployment-target check (min 26.0) | Rename the package to `A11yKit`; update all imports, project.yml, Makefile, check-imports.sh allow-list, and .swiftlint.yml. ADR-0021 records the decision. | Resolved; package renamed |
