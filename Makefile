.PHONY: all bootstrap project open build test run clean models models-coreml-tiny help dmg release-build e2e package-test bundle-diarization verify-ane

XCODEPROJ := Mila.xcodeproj
SCHEME := Mila
DERIVED := build
RELEASE_DERIVED := build-release
APP := $(DERIVED)/Build/Products/Debug/Mila.app
RELEASE_APP := $(RELEASE_DERIVED)/Build/Products/Release/Mila.app
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Mila/Resources/Info.plist 2>/dev/null || echo "0.0.0")
DMG := Mila-$(VERSION).dmg
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
	@echo "  test          - Run the MilaTests XCTest target"
	@echo "  run           - Build and launch the app"
	@echo "  models        - Pre-download both ggml models into ~/Library/Application Support/Mila/Models"
	@echo "  models-coreml-tiny - Download ggml-tiny + sibling -encoder.mlmodelc into ~/.cache/whisper-coreml-test/ (for CI ANE verification test)"
	@echo "  dmg           - Build a release DMG ($(DMG)) suitable for upload"
	@echo "  e2e           - Run E2E transcription tests (requires ggml-tiny.bin)"
	@echo "  package-test  - Run TranscriptionCore package unit tests"
	@echo "  bundle-diarization - Produce the bundled Python + pyannote.audio runtime under Mila/Resources/PythonRuntime/"
	@echo "  clean         - Remove generated project and build artifacts"

bootstrap:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "Installing xcodegen via Homebrew..."; \
		brew install xcodegen; \
	}

project: bootstrap
	@# PythonRuntime is a .gitignored folder reference (see project.yml). It is
	@# only populated by `make bundle-diarization`. XcodeGen's `optional: true`
	@# suppresses generation errors but still emits the copy-resources phase, so
	@# xcodebuild fails on the missing path. Ensure an (empty) dir exists; the app
	@# detects no bundled python and falls back to system python automatically.
	@mkdir -p Mila/Resources/PythonRuntime
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

# Local (self-hosted) check: verify an upgrade doesn't recompile the CoreML/ANE
# encoder. Needs a real Neural Engine + an installed model + a GUI session, so
# it is NOT runnable on GitHub-hosted CI. See scripts/verify-ane-cache.sh.
verify-ane:
	./scripts/verify-ane-cache.sh

models:
	@mkdir -p "$(HOME)/Library/Application Support/Mila/Models"
	@echo "Downloading ivrit-ai/whisper-large-v3-ggml (~3GB). Press Ctrl-C to abort."
	curl -L --fail --progress-bar \
		"https://huggingface.co/ivrit-ai/whisper-large-v3-ggml/resolve/main/ggml-model.bin" \
		-o "$(HOME)/Library/Application Support/Mila/Models/ivrit-ai-whisper-large-v3.bin"
	@echo "Downloading openai/whisper-large-v3-turbo (~1.6GB). Press Ctrl-C to abort."
	curl -L --fail --progress-bar \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
		-o "$(HOME)/Library/Application Support/Mila/Models/openai-whisper-large-v3-turbo.bin"
	@echo "Done. Models installed."

dmg: release-build
	@./scripts/make-dmg.sh "$(RELEASE_APP)" "$(DMG)" "$(VERSION)"

e2e:
	cd Packages/TranscriptionCore && swift run whisper-e2e \
		--model $(HOME)/.cache/whisper-models/ggml-tiny.bin \
		--fixtures Fixtures \
		--max-wer 0.3

# Download `ggml-tiny.bin` + sibling `ggml-tiny-encoder.mlmodelc` for the
# CoreML/ANE verification test (`WhisperEngineCoreMLTests`). Both go to
# `~/.cache/whisper-coreml-test/` so a CI cache step can persist them
# across runs. The .bin is ~75 MB; the .mlmodelc.zip is ~40 MB.
COREML_TEST_DIR := $(HOME)/.cache/whisper-coreml-test
models-coreml-tiny:
	@mkdir -p "$(COREML_TEST_DIR)"
	@if [ ! -f "$(COREML_TEST_DIR)/ggml-tiny.bin" ]; then \
		echo "Downloading ggml-tiny.bin (~75MB)..."; \
		curl -L --fail --progress-bar \
			"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin" \
			-o "$(COREML_TEST_DIR)/ggml-tiny.bin"; \
	fi
	@if [ ! -d "$(COREML_TEST_DIR)/ggml-tiny-encoder.mlmodelc" ]; then \
		echo "Downloading ggml-tiny-encoder.mlmodelc.zip (~40MB)..."; \
		curl -L --fail --progress-bar \
			"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-encoder.mlmodelc.zip" \
			-o "$(COREML_TEST_DIR)/ggml-tiny-encoder.mlmodelc.zip"; \
		cd "$(COREML_TEST_DIR)" && unzip -q ggml-tiny-encoder.mlmodelc.zip && rm -rf __MACOSX ggml-tiny-encoder.mlmodelc.zip; \
	fi
	@echo "Ready: $(COREML_TEST_DIR)/ggml-tiny.bin (+ sibling .mlmodelc)"

package-test:
	cd Packages/TranscriptionCore && swift test

# Produces Mila/Resources/PythonRuntime/ — a relocatable Python
# 3.11 with pyannote.audio (and deps) pre-installed, minus torch which
# DiarizationBootstrap downloads at first launch. Cached: re-running is
# fast if `python-bundle-cache/` is populated. The output is ~150-200 MB
# uncompressed and is NOT checked into git (see .gitignore). CI fetches
# the produced bundle from an actions/cache entry keyed on the script
# hash; dev machines run this once.
bundle-diarization:
	@bash scripts/build-diarization-bundle.sh

clean:
	rm -rf $(XCODEPROJ) $(DERIVED) $(RELEASE_DERIVED) Mila-*.dmg
