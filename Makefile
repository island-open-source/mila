.PHONY: all bootstrap project open build test run clean models help dmg release-build

XCODEPROJ := IslandWhisper.xcodeproj
SCHEME := IslandWhisper
DERIVED := build
RELEASE_DERIVED := build-release
APP := $(DERIVED)/Build/Products/Debug/IslandWhisper.app
RELEASE_APP := $(RELEASE_DERIVED)/Build/Products/Release/IslandWhisper.app
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" IslandWhisper/Resources/Info.plist 2>/dev/null || echo "0.0.0")
DMG := IslandWhisper-$(VERSION).dmg
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

all: project

help:
	@echo "Targets:"
	@echo "  bootstrap     - Install xcodegen if missing"
	@echo "  project       - Generate the Xcode project from project.yml"
	@echo "  open          - Open the Xcode project"
	@echo "  build         - Debug build via xcodebuild"
	@echo "  release-build - Release build into $(RELEASE_DERIVED)"
	@echo "  test          - Run the IslandWhisperTests XCTest target"
	@echo "  run           - Build and launch the app"
	@echo "  models        - Pre-download both ggml models into ~/Library/Application Support/IslandWhisper/Models"
	@echo "  dmg           - Build a release DMG ($(DMG)) suitable for upload"
	@echo "  clean         - Remove generated project and build artifacts"

bootstrap:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "Installing xcodegen via Homebrew..."; \
		brew install xcodegen; \
	}

project: bootstrap
	xcodegen generate

open: project
	open $(XCODEPROJ)

build: project
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS' build

release-build: project
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Release -derivedDataPath $(RELEASE_DERIVED) -destination 'platform=macOS' build

test: project
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS' test

run: build
	open $(APP)

models:
	@mkdir -p "$(HOME)/Library/Application Support/IslandWhisper/Models"
	@echo "Downloading ivrit-ai/whisper-large-v3-ggml (~3GB). Press Ctrl-C to abort."
	curl -L --fail --progress-bar \
		"https://huggingface.co/ivrit-ai/whisper-large-v3-ggml/resolve/main/ggml-model.bin" \
		-o "$(HOME)/Library/Application Support/IslandWhisper/Models/ivrit-ai-whisper-large-v3.bin"
	@echo "Downloading openai/whisper-large-v3-turbo (~1.6GB). Press Ctrl-C to abort."
	curl -L --fail --progress-bar \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
		-o "$(HOME)/Library/Application Support/IslandWhisper/Models/openai-whisper-large-v3-turbo.bin"
	@echo "Done. Models installed."

dmg: release-build
	@./scripts/make-dmg.sh "$(RELEASE_APP)" "$(DMG)" "$(VERSION)"

clean:
	rm -rf $(XCODEPROJ) $(DERIVED) $(RELEASE_DERIVED) IslandWhisper-*.dmg
