#!/usr/bin/env bash
# check-imports.sh — enforces:
#   1. Framework bans for the pure packages (CONVENTIONS §3.1).
#   2. Package-to-package import direction (ARCHITECTURE §3 "May Import"
#      table, widened for TableUI/Library/A11yKit per CONVENTIONS §3.1
#      "any of the above"; see docs/OPEN_QUESTIONS.md OQ-001).
#   3. The @_spi(HostOnly) allow-list (ARCHITECTURE §3 SPI rule).
# Fails CI on any violation.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

violation() {
    echo "check-imports: VIOLATION: $*" >&2
    FAIL=1
}

ALL_PKGS="CardModel CardExpr RulesEngine RulesetKit GameLibrary CardAI Teaching TableNet TableUI Library A11yKit Persistence Platform"
PURE_PKGS="CardModel CardExpr RulesEngine RulesetKit GameLibrary CardAI Teaching"
BANNED_FW="SwiftUI UIKit AppKit GameKit Network AVFoundation"

# --- 1. Framework bans (CONVENTIONS §3.1) ---------------------------------
# The seven pure packages must not import SwiftUI, UIKit, AppKit, GameKit,
# Network, or AVFoundation (Sources and Tests). TableNet may import Network
# and GameKit (CONVENTIONS §3.1); A11yKit may import AVFoundation
# (ARCHITECTURE §3).
for pkg in $PURE_PKGS; do
    for dir in Sources Tests; do
        [ -d "$ROOT/Packages/$pkg/$dir" ] || continue
        while IFS= read -r f; do
            for fw in $BANNED_FW; do
                if grep -qE "^[[:space:]]*(import[[:space:]]+|@_spi\([^)]*\)[[:space:]]+import[[:space:]]+)${fw}([[:space:]]|$)" "$f"; then
                    violation "$pkg: ${f#"$ROOT"/} imports banned framework $fw"
                fi
            done
        done < <(find "$ROOT/Packages/$pkg/$dir" -name '*.swift' 2>/dev/null)
    done
done

# --- 2. Package-to-package direction (ARCHITECTURE §3) ---------------------
# Direct-import allow-list per package (transitive closure of the "May
# Import" column; TableUI/Library/A11yKit may import any package per
# CONVENTIONS §3.1; Platform imports no Parlor package per ARCHITECTURE §3).
# Case-based on purpose: macOS ships bash 3.2, which has no associative
# arrays.
allow_list() {
    case "$1" in
        CardModel) echo "" ;;
        CardExpr) echo "CardModel" ;;
        RulesEngine) echo "CardModel CardExpr" ;;
        RulesetKit) echo "CardModel CardExpr RulesEngine" ;;
        GameLibrary) echo "CardModel CardExpr RulesEngine RulesetKit" ;;
        CardAI) echo "CardModel CardExpr RulesEngine RulesetKit" ;;
        Teaching) echo "CardModel CardExpr RulesEngine RulesetKit CardAI" ;;
        TableNet) echo "CardModel CardExpr RulesEngine RulesetKit" ;;
        Persistence) echo "CardModel CardExpr RulesEngine RulesetKit" ;;
        TableUI) echo "CardModel CardExpr RulesEngine RulesetKit GameLibrary CardAI Teaching TableNet Persistence Platform Library A11yKit" ;;
        Library) echo "CardModel CardExpr RulesEngine RulesetKit GameLibrary CardAI Teaching TableNet Persistence Platform TableUI A11yKit" ;;
        A11yKit) echo "CardModel CardExpr RulesEngine RulesetKit GameLibrary CardAI Teaching TableNet Persistence Platform TableUI Library" ;;
        *) echo "" ;;
    esac
}

for pkg in $ALL_PKGS; do
    allowed=" $(allow_list "$pkg") "
    [ -d "$ROOT/Packages/$pkg/Sources" ] || continue
    while IFS= read -r f; do
        imports="$(grep -oE '^[[:space:]]*(import[[:space:]]+|@_spi\([^)]*\)[[:space:]]+import[[:space:]]+)[A-Za-z_][A-Za-z0-9_]*' "$f" \
            | sed -E 's/.*import[[:space:]]+//' | sort -u)"
        for imp in $imports; do
            case " $ALL_PKGS " in
                *" $imp "*)
                    case "$allowed" in
                        *" $imp "*) ;;
                        *) violation "$pkg: ${f#"$ROOT"/} imports $imp (not in allow-list)" ;;
                    esac
                    ;;
            esac
        done
    done < <(find "$ROOT/Packages/$pkg/Sources" -name '*.swift' 2>/dev/null)
done

# --- 3. @_spi(HostOnly) allow-list (ARCHITECTURE §3 SPI rule) --------------
# Only RulesEngine (its tests), RulesetKit (simulator), TableNet (SessionHost),
# Persistence (SaveStore), Tools/rules-cli, and test targets may write the
# HostOnly SPI import of RulesEngine. Everywhere else fails.
while IFS= read -r f; do
    rel="${f#"$ROOT"/}"
    case "$rel" in
        Tools/check-imports.sh)
            ;;
        Packages/RulesEngine/* | Packages/RulesetKit/* | Packages/TableNet/* | Packages/Persistence/* | Tools/rules-cli/* | *Tests/* | Tests/*)
            ;;
        *)
            violation "SPI: $rel uses @_spi(HostOnly) (not in the ARCHITECTURE §3 allow-list)"
            ;;
    esac
done < <(grep -rlE '@_spi\(HostOnly\)' "$ROOT/Packages" "$ROOT/Tools" "$ROOT/App" "$ROOT/Tests" 2>/dev/null)

if [ "$FAIL" -ne 0 ]; then
    echo "check-imports: FAILED" >&2
    exit 1
fi
echo "check-imports: OK"
