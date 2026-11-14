# Decision 0001: Record Decisions

Date: 2026-11-14 (M0)

## Context

zTop is built over many sessions, often by an agent whose memory of earlier sessions is incomplete. Choices made without a record get re-made, or undone by accident.

## Decision

Every significant choice gets a numbered record in `docs/decisions/` with Context, Decision and Consequences. A later decision that changes an earlier one says so and links it.

## Consequences

Stack choices, protocol changes, dependency additions and anything a future session might second-guess are written down before or with the change that makes them.
