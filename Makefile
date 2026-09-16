APP_NAME := Everywhere
CONFIG ?= release
PYTHON ?= python3
VERSION := 1.0.0
BUNDLE_ID := app.everywhere.macos
BIN_DIR := $(shell swift build -c $(CONFIG) --show-bin-path)
DIST_BIN_DIR = $(shell swift build -c $(CONFIG) --arch arm64 --arch x86_64 --show-bin-path)
APP_DIR := .build/$(APP_NAME).app
DIST_ZIP := .build/$(APP_NAME)-$(VERSION).zip
TAP_DIR ?= ../homebrew-tap

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
	ditto -c -k --keepParent "$(APP_DIR)" "$(DIST_ZIP)"
	@shasum -a 256 "$(DIST_ZIP)"
	@echo "Upload $(DIST_ZIP) to a GitHub release tagged v$(VERSION), then record the SHA256 above in the tap's Casks/everywhere.rb."

bump:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make bump VERSION=x.y.z" >&2; exit 1; fi
	@if ! printf '%s' "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then echo "VERSION must be three numbers, e.g. 1.2.0" >&2; exit 1; fi
	@sed -i '' 's/^VERSION := .*/VERSION := $(VERSION)/' Makefile
	@echo "Version is now $(VERSION). The tap cask is updated automatically during make release."

release:
	@if [ "$(origin VERSION)" != "command line" ]; then echo "Usage: make release VERSION=x.y.z" >&2; exit 1; fi
	@if ! printf '%s' "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then echo "VERSION must be three numbers, e.g. 1.2.0" >&2; exit 1; fi
	@if ! command -v gh >/dev/null 2>&1; then echo "GitHub CLI is required: brew install gh" >&2; exit 1; fi
	@if [ ! -f "$(TAP_DIR)/Casks/everywhere.rb" ]; then echo "No tap cask at $(TAP_DIR)/Casks/everywhere.rb" >&2; exit 1; fi
	@if [ -n "$$(git status --porcelain -- Makefile)" ]; then echo "Commit or stash Makefile changes first" >&2; exit 1; fi
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory bump VERSION=$(VERSION)
	@$(MAKE) --no-print-directory dist
	@git add Makefile
	@git commit -m "v$(VERSION)"
	@git tag v$(VERSION)
	@git push origin v$(VERSION)
	@gh release create v$(VERSION) "$(DIST_ZIP)" --title "v$(VERSION)" --generate-notes
	@SHA=$$(shasum -a 256 "$(DIST_ZIP)" | awk '{print $$1}'); \
		sed -i '' -e 's/^  version ".*"/  version "$(VERSION)"/' -e "s/^  sha256 .*/  sha256 \"$${SHA}\"/" "$(TAP_DIR)/Casks/everywhere.rb"
	@git -C "$(TAP_DIR)" commit -m "everywhere v$(VERSION)" Casks/everywhere.rb
	@git -C "$(TAP_DIR)" push
	@echo "Released v$(VERSION). Remember to push this repo: git push"

run:
	swift run -c debug Everywhere

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" /Applications/

open: install
	open "/Applications/$(APP_NAME).app"

clean:
	rm -rf .build
