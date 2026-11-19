SHELL := /bin/bash
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
PROJECT := Parlor.xcodeproj
DERIVED_DATA := .build/xcode
IOS_SIM ?= iPhone 17
IPAD_SIM ?= iPad Pro 13-inch (M5)
PACKAGES := CardModel CardExpr RulesEngine RulesetKit GameLibrary CardAI Teaching TableNet TableUI Library A11yKit Persistence Platform
COVERAGE_MIN ?= 90

# Host-local simulator lock (no-op on CI where the lock does not exist).
SIM_LOCK := $(shell test -x "$(HOME)/.hermes/bin/sim-lock" && echo "$(HOME)/.hermes/bin/sim-lock")

.PHONY: help bootstrap gen build test test-packages test-packages-ios test-replays-ios test-apps lint format validate schema-check conformance sim fuzz-quick snapshot coverage coverage-check perf gate

help:
	@echo "Parlor build targets (CONVENTIONS §7):"
	@echo "  bootstrap   - verify the fixed toolchain (XcodeGen, SwiftLint, swift-format, xcodebuild)"
	@echo "  gen         - regenerate $(PROJECT) with XcodeGen"
	@echo "  build       - build Parlor-iOS (iOS Simulator) and Parlor-macOS (macOS)"
	@echo "  test        - swift test in every package + xcodebuild test (iOS + macOS)"
	@echo "  test-packages-ios - swift package tests on the iOS simulator (all packages)"
	@echo "  test-replays-ios  - RulesEngine suite (golden replays) on the iOS simulator"
	@echo "  lint        - SwiftLint (main + pure), swift-format, check-imports.sh (zero warnings)"
	@echo "  format      - swift-format --in-place"
	@echo "  validate    - rules-cli validate (no-ops until P3 rulesets land)"
	@echo "  schema-check - rules-cli schema --check (exported schemas fresh)"
	@echo "  conformance - rules-cli conformance (no-ops until P3)"
	@echo "  sim N=200   - random-legal / bot-vs-bot games (no-ops until P3)"
	@echo "  fuzz-quick  - 60s protocol fuzz (no-ops until P8)"
	@echo "  snapshot    - snapshot suite (no-ops until P5)"
	@echo "  coverage    - package code coverage"
	@echo "  coverage-check - enforce >= $(COVERAGE_MIN)% line coverage in CardModel and RulesEngine"
	@echo "  perf        - perf harness (no-ops until P9)"
	@echo "  gate        - run the checks for PHASE=Pn (default P0)"

bootstrap:
	@command -v xcodegen >/dev/null || { echo "bootstrap: xcodegen missing (brew install xcodegen)" >&2; exit 1; }
	@command -v swiftlint >/dev/null || { echo "bootstrap: swiftlint missing (brew install swiftlint)" >&2; exit 1; }
	@command -v swift-format >/dev/null || { echo "bootstrap: swift-format missing (Xcode toolchain)" >&2; exit 1; }
	@command -v xcodebuild >/dev/null || { echo "bootstrap: xcodebuild missing (install Xcode)" >&2; exit 1; }
	@echo "bootstrap: toolchain OK (xcodegen $$(xcodegen --version | tail -1), swiftlint $$(swiftlint version))"

gen:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme Parlor-iOS -destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath $(DERIVED_DATA) build
	xcodebuild -project $(PROJECT) -scheme Parlor-iOS -destination 'platform=iOS Simulator,name=$(IPAD_SIM)' -derivedDataPath $(DERIVED_DATA) build
	xcodebuild -project $(PROJECT) -scheme Parlor-macOS -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) build

test: test-packages test-apps

test-packages:
	@for p in $(PACKAGES); do \
		echo "=== swift test $$p ==="; \
		(cd "Packages/$$p" && swift test) || exit 1; \
	done

test-apps:
	$(SIM_LOCK) xcodebuild -project $(PROJECT) -scheme Parlor-iOS -destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath $(DERIVED_DATA) test
	$(SIM_LOCK) xcodebuild -project $(PROJECT) -scheme Parlor-iOS -destination 'platform=iOS Simulator,name=$(IPAD_SIM)' -derivedDataPath $(DERIVED_DATA) test

# Package unit tests on the iOS simulator (package schemes via xcodebuild).
test-packages-ios:
	@for p in $(PACKAGES); do \
		echo "=== xcodebuild test $$p (iOS Simulator) ==="; \
		(cd "Packages/$$p" && $(SIM_LOCK) xcodebuild test -scheme "$$p" -destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath ../../.build/xcode/$$p-ios) || exit 1; \
	done

# Cross-platform golden replay leg (G1): the RulesEngine suite (replays, RNG
# vectors, redaction) must pass on the iOS simulator, matching the macOS run.
test-replays-ios:
	cd Packages/RulesEngine && $(SIM_LOCK) xcodebuild test -scheme RulesEngine-Package -destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath ../../.build/xcode/RulesEngine-ios

# macOS UI-test leg (ADR-0022): excluded from gate until the runner's TCC
# automation prompt is approved once on this host; required again from G9.
test-apps-macos-ui:
	@xcodebuild -project $(PROJECT) -scheme Parlor-macOS -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) test

lint:
	swiftlint lint --quiet
	swiftlint lint --quiet --config .swiftlint-pure.yml
	swift-format lint --strict --recursive .
	Tools/check-imports.sh

format:
	swift-format format --in-place --recursive .

validate:
	Tools/rules-cli validate

# P2.9: the committed JSON Schemas must match the exporter exactly
# (freshness), and CI validates the reference rulesets against the schema
# (scripts/validate-schemas.py, run by the CI workflow with a jsonschema venv).
schema-check:
	Tools/rules-cli schema --check

conformance:
	Tools/rules-cli conformance

sim:
	Tools/rules-cli sim $(or $(N),200)

fuzz-quick:
	Tools/net-fuzz quick

snapshot:
	@echo "snapshot: no snapshot suite yet (lands in P5); nothing to run"

coverage:
	@mkdir -p reports/coverage
	@df -h / | tail -1 | sed 's/^/disk: /'
	@for p in $(PACKAGES); do \
		echo "=== coverage $$p ==="; \
		(cd "Packages/$$p" && swift test --parallel --enable-code-coverage) > "reports/coverage/$$p.log" 2>&1 || { echo "coverage: $$p FAILED (log: reports/coverage/$$p.log)" >&2; tail -30 "reports/coverage/$$p.log" >&2; exit 1; }; \
		grep -E "Test run with" "reports/coverage/$$p.log" || true; \
		find "Packages/$$p/.build" -name '*.profraw' 2>/dev/null | while IFS= read -r f; do \
			cp "$$f" "reports/coverage/$$p-$$(basename "$$f")"; \
		done; \
	done
	@echo "coverage: profraw files in reports/coverage/"

# Threshold enforcement: >= 90% line coverage in CardModel and RulesEngine,
# >= 95% in CardExpr (G2 requirement).
coverage-check:
	@mkdir -p reports/coverage
	@set -e; \
	SPECS=""; \
	for p in CardModel RulesEngine CardExpr; do \
		echo "=== coverage $$p ==="; \
		swift test --package-path "Packages/$$p" --enable-code-coverage --build-path ".build/coverage-$$p" >/dev/null; \
		PROF=".build/coverage-$$p/out/Products/Debug/codecov/default.profdata"; \
		BUNDLE=$$(find ".build/coverage-$$p" -name '*Tests.xctest' -type d | head -1); \
		BIN="$$BUNDLE/Contents/MacOS/$$(basename "$$BUNDLE" .xctest)"; \
		SPECS="$$SPECS $$BIN:$$PROF"; \
	done; \
	RESULT=$$(COVERAGE_THRESHOLDS="CardExpr=95" bash Tools/coverage-report.sh $$SPECS || true); \
	echo "$$RESULT" | tee reports/coverage/summary.txt; \
	if echo "$$RESULT" | grep -q BELOW; then \
		echo "coverage-check: FAILED (thresholds: CardModel/RulesEngine 90%, CardExpr 95%)" >&2; exit 1; \
	fi; \
	echo "coverage-check: all package thresholds met (CardModel/RulesEngine >= 90%, CardExpr >= 95%)"

perf:
	@echo "perf: perf harness lands in P9; nothing to measure yet"

gate:
	@test -n "$(PHASE)" || { echo "gate: usage: make gate PHASE=Pn" >&2; exit 1; }
	@case "$(PHASE)" in \
		P0|P1) $(MAKE) bootstrap lint test-packages coverage-check coverage conformance validate sim N=200 fuzz-quick snapshot build test-apps test-replays-ios ;; \
		P2) $(MAKE) bootstrap lint test-packages coverage-check schema-check validate sim N=200 coverage fuzz-quick snapshot build test-apps test-replays-ios ;; \
		*) echo "gate: PHASE=$(PHASE) checks land with that phase" >&2; exit 1 ;; \
	esac
	@echo "gate: PHASE=$(PHASE) PASSED"
