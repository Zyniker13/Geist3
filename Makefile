SHELL := /bin/bash
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
PROJECT := Parlor.xcodeproj
DERIVED_DATA := .build/xcode
IOS_SIM ?= iPhone 17
IPAD_SIM ?= iPad Pro 13-inch (M5)
PACKAGES := CardModel CardExpr RulesEngine RulesetKit GameLibrary CardAI Teaching TableNet TableUI Library A11yKit Persistence Platform

.PHONY: help bootstrap gen build test test-packages test-apps lint format validate conformance sim fuzz-quick snapshot coverage perf gate

help:
	@echo "Parlor build targets (CONVENTIONS §7):"
	@echo "  bootstrap   - verify the fixed toolchain (XcodeGen, SwiftLint, swift-format, xcodebuild)"
	@echo "  gen         - regenerate $(PROJECT) with XcodeGen"
	@echo "  build       - build Parlor-iOS (iOS Simulator) and Parlor-macOS (macOS)"
	@echo "  test        - swift test in every package + xcodebuild test (iOS + macOS)"
	@echo "  lint        - SwiftLint (main + pure), swift-format, check-imports.sh (zero warnings)"
	@echo "  format      - swift-format --in-place"
	@echo "  validate    - rules-cli validate (no-ops until P3 rulesets land)"
	@echo "  conformance - rules-cli conformance (no-ops until P3)"
	@echo "  sim N=200   - random-legal / bot-vs-bot games (no-ops until P3)"
	@echo "  fuzz-quick  - 60s protocol fuzz (no-ops until P8)"
	@echo "  snapshot    - snapshot suite (no-ops until P5)"
	@echo "  coverage    - package code coverage"
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
	xcodebuild -project $(PROJECT) -scheme Parlor-iOS -destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath $(DERIVED_DATA) test
	xcodebuild -project $(PROJECT) -scheme Parlor-iOS -destination 'platform=iOS Simulator,name=$(IPAD_SIM)' -derivedDataPath $(DERIVED_DATA) test

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
	@for p in $(PACKAGES); do \
		echo "=== coverage $$p ==="; \
		(cd "Packages/$$p" && swift test --parallel --enable-code-coverage) || exit 1; \
		find "Packages/$$p/.build" -name '*.profraw' 2>/dev/null | while IFS= read -r f; do \
			cp "$$f" "reports/coverage/$$p-$$(basename "$$f")"; \
		done; \
	done
	@echo "coverage: profraw files in reports/coverage/"

perf:
	@echo "perf: perf harness lands in P9; nothing to measure yet"

gate:
	@test -n "$(PHASE)" || { echo "gate: usage: make gate PHASE=Pn" >&2; exit 1; }
	@case "$(PHASE)" in \
		P0) $(MAKE) bootstrap lint test-packages coverage conformance validate sim N=200 fuzz-quick snapshot build test-apps ;; \
		*) echo "gate: PHASE=$(PHASE) checks land with that phase" >&2; exit 1 ;; \
	esac
	@echo "gate: PHASE=$(PHASE) PASSED"
