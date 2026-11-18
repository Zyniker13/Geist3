#!/bin/bash
# Generate the 20 golden toy replays into Packages/RulesEngine/Tests/Fixtures/Replays/.
# Regenerate whenever the toy game or engine changes; commit the output.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Packages/RulesEngine/Tests/Fixtures/Replays
rm -f Packages/RulesEngine/Tests/Fixtures/Replays/*.json
swift run --package-path Packages/RulesEngine golden-gen Packages/RulesEngine/Tests/Fixtures/Replays
