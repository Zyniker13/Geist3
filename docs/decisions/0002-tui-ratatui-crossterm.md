# 0002: TUI stack — ratatui with crossterm

## Context

ROADMAP.md names `ratatui` + `crossterm` as the expected TUI stack and asks for the choice to be confirmed in a decision. Requirements from DESIGN.md and the parity list: htop-style meters and process tables, tree views, mouse support, correct 80x24 layout, snapshot tests, and the same binary on macOS and Linux.

## Decision

- Build the TUI on `ratatui`, taking `crossterm` through ratatui's re-export (`ratatui::crossterm`) so the two versions cannot drift apart.
- Deterministic tests render through `ratatui::backend::TestBackend`; real terminals get crossterm raw mode and the alternate screen.

## Consequences

- One immediate-mode render loop; TUI state lives in a plain struct the loop mutates.
- Snapshot tests never touch a real terminal, so CI needs no pty and the 80x24 requirement is testable.
- ratatui is the most actively maintained Rust TUI toolkit and what htop-style Rust tools converge on, which lowers the cost of the later parity milestones (M1, M3).
- Update (2026-11-14): the workspace tracks `ratatui 0.30`, not 0.29. ratatui 0.29 pulled in `paste`, an archived (unmaintained) crate that raised a dependency advisory; 0.30 dropped it, so the minor bump clears the advisory with no API cost to the skeleton.
