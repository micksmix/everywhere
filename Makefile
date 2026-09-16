APP_NAME := Everywhere
CONFIG ?= release
PYTHON ?= python3
VERSION := 1.0.0
BUNDLE_ID := app.everywhere.macos
BIN_DIR := $(shell swift build -c $(CONFIG) --show-bin-path)
DIST_BIN_DIR = $(shell swift build -c $(CONFIG) --arch arm64 --arch x86_64 --show-bin-path)
APP_DIR := .build/$(APP_NAME).app
DIST_ZIP := .build/$(APP_NAME)-$(VERSION).zip

.PHONY: all build test app bundle dist bump release run install open clean

all: test app

build:
	swift build -c $(CONFIG)

test:
	swift test

Resources/AppIcon.icns: Scripts/make-icon.swift Resources/AppIcon.svg
	@mkdir -p Resources
	swift Scripts/make-icon.swift $@

app: build Resources/AppIcon.icns
	@$(MAKE) --no-print-directory bundle

bundle: Resources/AppIcon.icns
	@mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	@cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP_DIR)/Contents/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(APP_DIR)/Contents/Info.plist"
	@cp "$(BIN_DIR)/$(APP_NAME)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/AppIcon.icns "$(APP_DIR)/Contents/Resources/AppIcon.icns"
	@cp Resources/Credits.html LICENSE "$(APP_DIR)/Contents/Resources/"
	$(PYTHON) Scripts/make-help.py "$(APP_DIR)/Contents/Resources/Everywhere.help"
	@codesign --force --sign - "$(APP_DIR)"
	@touch "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

dist: Resources/AppIcon.icns
	swift build -c $(CONFIG) --arch arm64 --arch x86_64
	@$(MAKE) --no-print-directory bundle BIN_DIR=$(DIST_BIN_DIR)
	$(PYTHON) -c 'import subprocess; assert set(subprocess.check_output(["lipo", "-archs", "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"], text=True).split()) == {"arm64", "x86_64"}, "Universal app must contain ARM64 and x86_64"'
	codesign --verify --strict "$(APP_DIR)"
	ditto -c -k --keepParent "$(APP_DIR)" "$(DIST_ZIP)"
	@cd .build && shasum -a 256 "$(APP_NAME)-$(VERSION).zip" > "$(APP_NAME)-$(VERSION).zip.sha256"
	@cat "$(DIST_ZIP).sha256"
	@echo "Upload $(DIST_ZIP) to a GitHub release tagged v$(VERSION), then record the SHA256 above in the tap's Casks/everywhere.rb."

bump:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make bump VERSION=x.y.z" >&2; exit 1; fi
	@if ! printf '%s' "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then echo "VERSION must be three numbers, e.g. 1.2.0" >&2; exit 1; fi
	@sed -i '' 's/^VERSION := .*/VERSION := $(VERSION)/' Makefile
	@echo "Version is now $(VERSION). GitHub Actions publishes the release and updates the tap after the tag is pushed."

release:
	@if [ "$(origin VERSION)" != "command line" ]; then echo "Usage: make release VERSION=x.y.z" >&2; exit 1; fi
	@if ! printf '%s' "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then echo "VERSION must be three numbers, e.g. 1.2.0" >&2; exit 1; fi
	@if [ -n "$$(git status --porcelain)" ]; then echo "Commit or stash all changes first (including the release workflow)" >&2; exit 1; fi
	@if git show-ref --verify --quiet refs/tags/v$(VERSION); then echo "Tag v$(VERSION) already exists; use a new version or retry its Actions run" >&2; exit 1; fi
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory bump VERSION=$(VERSION)
	@git add Makefile
	@git diff --cached --quiet || git commit -m "v$(VERSION)"
	@git tag v$(VERSION)
	@git push origin v$(VERSION)
	@echo "Tag v$(VERSION) pushed. GitHub Actions builds the universal zip, publishes the GitHub release, and updates the cask."

run:
	swift run -c debug Everywhere

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" /Applications/

open: install
	open "/Applications/$(APP_NAME).app"

clean:
	rm -rf .build
