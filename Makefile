.DEFAULT_GOAL := help

.PHONY: help bootstrap generate build test lint format clean open

help:
	@echo "lumi-apple — make targets"
	@echo "  bootstrap   install xcodegen / swiftlint / swiftformat (via brew) and generate"
	@echo "  generate    generate Lumi.xcodeproj from project.yml"
	@echo "  build       swift build (LumiKit + LumiUI)"
	@echo "  test        swift test"
	@echo "  lint        swiftlint --strict"
	@echo "  format      swiftformat ."
	@echo "  open        generate and open Lumi.xcodeproj in Xcode"
	@echo "  clean       remove .build, DerivedData, generated xcodeproj"

bootstrap:
	@command -v xcodegen   >/dev/null 2>&1 || brew install xcodegen
	@command -v swiftlint  >/dev/null 2>&1 || brew install swiftlint
	@command -v swiftformat >/dev/null 2>&1 || brew install swiftformat
	@$(MAKE) generate

generate:
	xcodegen generate

build:
	swift build

test:
	swift test

lint:
	swiftlint --strict

format:
	swiftformat .

open: generate
	open Lumi.xcodeproj

clean:
	rm -rf .build Lumi.xcodeproj DerivedData build
