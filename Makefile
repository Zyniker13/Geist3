SHELL := /bin/bash
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
PROJECT := Parlor.xcodeproj
DERIVED_DATA := .build/xcode

.PHONY: help gen build

help:
	@echo "Parlor build targets (P0.2 subset; full target set lands in P0.4):"
	@echo "  gen   - regenerate $(PROJECT) with XcodeGen"
	@echo "  build - build Parlor-iOS (iOS Simulator) and Parlor-macOS (macOS)"

gen:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme Parlor-iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED_DATA) build
	xcodebuild -project $(PROJECT) -scheme Parlor-macOS -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) build
