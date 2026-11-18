# PERF

Purpose: performance measurements against the budgets in `docs/plan/CONVENTIONS.md` §8, each entry with device, OS, build, and date.

| Budget | Target | Measured | Device | OS | Build | Date |
| --- | --- | --- | --- | --- | --- | --- |
| `Engine.apply` p99 (P1.8) | < 1 ms | **10.8 µs** (2,000 samples) | CI Mac (M-series, host) | macOS 27.2, Swift 6.4.2 -O debug tests | `a3c9f0d`+ | 2026-11-18 |
| `Engine.observation` p99 (P1.8) | < 0.5 ms | **13.4 µs** (2,000 samples) | CI Mac (M-series, host) | macOS 27.2, Swift 6.4.2 -O debug tests | `a3c9f0d`+ | 2026-11-18 |

XCTest `measure` steady-state agrees (~13 µs apply, ~15 µs observation). Toy game (10 cards, 2 seats) is the smallest workload; P4 records the same measurements on real games and devices. Source: `Packages/RulesEngine/Tests/PerfTests.swift`.
