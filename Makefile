APP_NAME := Everywhere
CONFIG ?= release
PYTHON ?= python3
VERSION := 1.0.0
BUNDLE_ID := app.everywhere.macos
BIN_DIR := $(shell swift build -c $(CONFIG) --show-bin-path)
APP_DIR := .build/$(APP_NAME).app

.PHONY: all build test app run install open clean

all: test app

build:
	swift build -c $(CONFIG)

test:
	swift test

Resources/AppIcon.icns: Scripts/make-icon.swift Resources/AppIcon.svg
	@mkdir -p Resources
	swift Scripts/make-icon.swift $@

app: build Resources/AppIcon.icns
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

run:
	swift run -c debug Everywhere

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" /Applications/

open: install
	open "/Applications/$(APP_NAME).app"

clean:
	rm -rf .build
