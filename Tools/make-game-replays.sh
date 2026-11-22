#!/usr/bin/env bash
# Generate the four base games' golden replays (P3.5; ARCHITECTURE §10.4).
#
# Builds the RulesetKitGoldenGen executable and writes 20 deterministic deals
# per game — hearts.standard, euchre.standard, contract-bridge.rubber,
# cribbage.six-card — into Packages/RulesetKit/Tests/Fixtures/Replays/ as
# <game-slug>-NN.json (parlor.replay/1). The generator self-verifies each
# deal (it replays the recorded action list and fails on any final-state
# hash mismatch) before writing, so a clean run is itself a full pass over
# the produced files.
#
# Seeds are fixed (1–20 per game) and the deck deals are engine-seeded
# (never host-shuffled), so regenerated fixtures are byte-identical unless
# the ruleset or engine actually changed. Commit the refreshed fixtures in
# that case, with the reason.
#
# Usage: Tools/make-game-replays.sh [game-stem ...]
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GEN="$ROOT/Packages/RulesetKit/.build/out/Products/Debug/RulesetKitGoldenGen"
OUT="$ROOT/Packages/RulesetKit/Tests/Fixtures/Replays"

swift build --package-path "$ROOT/Packages/RulesetKit" --product RulesetKitGoldenGen

if [ "$#" -eq 0 ]; then
    set -- hearts.standard euchre.standard contract-bridge.rubber cribbage.six-card
fi

for stem in "$@"; do
    echo "== $stem"
    "$GEN" "$OUT" "$stem"
done
echo "make-game-replays: done ($(ls "$OUT" | grep -c '\.json$') fixture files in $OUT)"
