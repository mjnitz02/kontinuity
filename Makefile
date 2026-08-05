# Kontinuity — task runner.
# CI workflows call these same targets, so `make <x>` behaves identically
# locally and in GitHub Actions. Run `make` (or `make help`) for the list.

# Per-machine overrides (e.g. DEVICE_ID) live here — gitignored, never committed.
# Copy Makefile.local.example to Makefile.local and fill it in. The `-` makes
# the include silent when the file is absent (CI doesn't need it).
-include Makefile.local

# Pinned linter versions — downloaded straight from GitHub releases so
# `make lint`/`make format-check` run the exact same binary locally and in
# CI, instead of drifting with `brew upgrade`. Bump these deliberately.
SWIFTFORMAT_VERSION := 0.62.1
SWIFTLINT_VERSION   := 0.64.1
GITLEAKS_VERSION    := 8.30.1
TOOLS_DIR           := .tools/bin
SWIFTFORMAT_BIN     := $(TOOLS_DIR)/swiftformat-$(SWIFTFORMAT_VERSION)
SWIFTLINT_BIN       := $(TOOLS_DIR)/swiftlint-$(SWIFTLINT_VERSION)
GITLEAKS_BIN        := $(TOOLS_DIR)/gitleaks-$(GITLEAKS_VERSION)

PROJECT        := Kontinuity.xcodeproj
SCHEME         := Kontinuity
UNIT_TARGET    := KontinuityTests
UI_TARGET      := KontinuityUITests

# Simulator destination. The iPad is the primary target and the CI gate —
# `test-ui`/`test-all` never point at anything else, even with 6B's iPhone
# lane below (PLAN 6B §E).
SIMULATOR_NAME ?= iPad Pro 11-inch (M5)
# arch=arm64 pins the native slice so xcodebuild doesn't warn about matching
# both the arm64 and x86_64/Rosetta slice of the same simulator.
DESTINATION    ?= platform=iOS Simulator,name=$(SIMULATOR_NAME),arch=arm64

# The iPhone lane (PLAN 6B): compact-height Mode B only exists there, so it
# needs its own destination — `test-ui-iphone` runs `ReaderIPhoneUITests`
# against it. The iPad `DESTINATION` above is untouched and stays the default
# for every other target.
IPHONE_SIMULATOR_NAME ?= iPhone 17 Pro
IPHONE_DESTINATION    ?= platform=iOS Simulator,name=$(IPHONE_SIMULATOR_NAME),arch=arm64

# On-device deploy (paid Apple Developer Program membership). Profiles are good
# for a year, so `make deploy` is only needed when you want new code on the
# iPad — plugged in, or paired over Wi-Fi. DEVICE_ID comes from
# `xcrun devicectl list devices` and is set in Makefile.local (or
# `make deploy DEVICE_ID=...`).
APP_NAME       ?= Kontinuity
DEVICE_CONFIG  ?= Debug
DEVICE_DERIVED ?= build/device
DEVICE_ID      ?=
DEVICE_APP     := $(DEVICE_DERIVED)/Build/Products/$(DEVICE_CONFIG)-iphoneos/$(APP_NAME).app

# TestFlight distribution. Unlike `deploy` — Debug, development-signed, straight
# to the iPad over cable/Wi-Fi — this builds Release, signs for distribution,
# and goes through App Store Connect. Slower loop: uploads take 5-15 minutes to
# process, and TestFlight builds expire after 90 days. `deploy` stays the inner
# loop; this is for cable-free installs and stable checkpoints.
ARCHIVE_CONFIG ?= Release
ARCHIVE_PATH   ?= build/$(APP_NAME).xcarchive
EXPORT_OPTIONS ?= ExportOptions.plist

# App Store Connect refuses a duplicate build number for a given
# MARKETING_VERSION. Deriving it from the commit count keeps it monotonic
# without hand-editing (and churning) the pbxproj on every release.
BUILD_NUMBER   ?= $(shell git rev-list --count HEAD)

# NOTE: `archive` and `testflight` deliberately omit `-allowProvisioningUpdates`.
# That flag lets xcodebuild mint signing assets on the Apple Developer account —
# including distribution certificates, which are capped per account. The cert and
# the App Store profiles are provisioned by hand instead (the one-time Xcode
# Product > Archive > Distribute run), so this automation can only ever *consume*
# credentials, never create them. The cost is that an expired profile fails the
# build rather than silently renewing: re-download it from the portal (or archive
# once through Xcode) and the CLI path works again.

# App Store Connect API key, set in Makefile.local. The .p8 itself lives outside
# the repo and downloads exactly once — if it's lost, revoke and reissue.
ASC_KEY_ID     ?=
ASC_ISSUER_ID  ?=
ASC_KEY_PATH   ?= $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8

# Local Komga instance for testing (see ~/workspaces/komga-docker). Credentials
# live in Makefile.local, never here — this file is committed. `komga-check`
# degrades gracefully when they're unset.
KOMGA_DIR      ?= $(HOME)/workspaces/komga-docker
KOMGA_URL      ?= http://localhost:25600
KOMGA_EMAIL    ?=
KOMGA_PASSWORD ?=
KOMGA_API_KEY  ?=
# Separate derived-data root: the .xctestrun there gets credentials injected,
# so it must not be the tree `make build` / `make test-unit` share.
INTEGRATION_DERIVED ?= build/integration

XCODEBUILD     := xcodebuild
# Pretty-print xcodebuild output when xcbeautify is installed; otherwise raw.
FORMATTER      := $(shell command -v xcbeautify >/dev/null 2>&1 && echo "| xcbeautify" || echo "")

.DEFAULT_GOAL := help

## help: list available targets
.PHONY: help
help:
	@grep -hE '^## ' $(MAKEFILE_LIST) | sed 's/## //' | awk -F': ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## install-tools: fetch pinned SwiftLint + SwiftFormat + gitleaks, install xcbeautify (via Homebrew)
.PHONY: install-tools
install-tools: $(SWIFTFORMAT_BIN) $(SWIFTLINT_BIN) $(GITLEAKS_BIN)
	brew install xcbeautify

# Universal macOS binary straight from the SwiftFormat release, not Homebrew —
# Homebrew only ever offers the latest formula, which is what let CI and a
# local install drift apart.
$(SWIFTFORMAT_BIN):
	@mkdir -p $(TOOLS_DIR)
	curl -sL -o /tmp/swiftformat-$(SWIFTFORMAT_VERSION).zip \
		https://github.com/nicklockwood/SwiftFormat/releases/download/$(SWIFTFORMAT_VERSION)/swiftformat.zip
	unzip -p /tmp/swiftformat-$(SWIFTFORMAT_VERSION).zip swiftformat > $@
	chmod +x $@
	xattr -cr $@
	@rm /tmp/swiftformat-$(SWIFTFORMAT_VERSION).zip

# Same deal for SwiftLint — the "portable" release asset is the universal
# macOS binary (the arm64/amd64-named zips are Windows builds, confusingly).
$(SWIFTLINT_BIN):
	@mkdir -p $(TOOLS_DIR)
	curl -sL -o /tmp/swiftlint-$(SWIFTLINT_VERSION).zip \
		https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/portable_swiftlint.zip
	unzip -p /tmp/swiftlint-$(SWIFTLINT_VERSION).zip swiftlint > $@
	chmod +x $@
	xattr -cr $@
	@rm /tmp/swiftlint-$(SWIFTLINT_VERSION).zip

# gitleaks ships a per-platform tarball (no zip); darwin_arm64 is what both
# Matt's machine and the macOS GitHub runners are.
$(GITLEAKS_BIN):
	@mkdir -p $(TOOLS_DIR)
	curl -sL -o /tmp/gitleaks-$(GITLEAKS_VERSION).tar.gz \
		https://github.com/gitleaks/gitleaks/releases/download/v$(GITLEAKS_VERSION)/gitleaks_$(GITLEAKS_VERSION)_darwin_arm64.tar.gz
	tar -xzf /tmp/gitleaks-$(GITLEAKS_VERSION).tar.gz -O gitleaks > $@
	chmod +x $@
	xattr -cr $@
	@rm /tmp/gitleaks-$(GITLEAKS_VERSION).tar.gz

## install-hooks: enable the repo's git pre-commit hook
.PHONY: install-hooks
install-hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled (lint + format-check + secret scan)."

## lint: run SwiftLint (strict — warnings fail)
.PHONY: lint
lint: $(SWIFTLINT_BIN)
	$(SWIFTLINT_BIN) lint --strict

## format: rewrite sources with SwiftFormat
.PHONY: format
format: $(SWIFTFORMAT_BIN)
	$(SWIFTFORMAT_BIN) .

## format-check: verify formatting without rewriting (used in CI)
.PHONY: format-check
format-check: $(SWIFTFORMAT_BIN)
	$(SWIFTFORMAT_BIN) --lint .

## secrets: scan staged changes for leaked secrets (gitleaks, used by pre-commit)
.PHONY: secrets
secrets: $(GITLEAKS_BIN)
	$(GITLEAKS_BIN) protect --staged --config .gitleaks.toml -v --redact

## secrets-scan: scan the full repo history for leaked secrets (used in CI)
.PHONY: secrets-scan
secrets-scan: $(GITLEAKS_BIN)
	$(GITLEAKS_BIN) detect --config .gitleaks.toml -v --redact

## build: build the app for the simulator
.PHONY: build
build:
	set -o pipefail; $(XCODEBUILD) build \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' $(FORMATTER)

## deploy: build + install to the iPad over cable/Wi-Fi
.PHONY: deploy
deploy:
	@test -n "$(DEVICE_ID)" || { echo "DEVICE_ID is unset. Set it in Makefile.local (copy Makefile.local.example) or pass DEVICE_ID=... — find it via 'xcrun devicectl list devices'."; exit 1; }
	set -o pipefail; $(XCODEBUILD) build \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(DEVICE_CONFIG) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		-derivedDataPath $(DEVICE_DERIVED) $(FORMATTER)
	xcrun devicectl device install app --device $(DEVICE_ID) "$(DEVICE_APP)"
	@echo "Installed $(APP_NAME)."

## ipa: package an unsigned .ipa for SideStore/AltStore (which auto-refreshes)
.PHONY: ipa
ipa:
	set -o pipefail; $(XCODEBUILD) build \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(DEVICE_CONFIG) \
		-destination 'generic/platform=iOS' \
		CODE_SIGNING_ALLOWED=NO \
		-derivedDataPath $(DEVICE_DERIVED) $(FORMATTER)
	rm -rf build/ipa && mkdir -p build/ipa/Payload
	cp -R "$(DEVICE_APP)" build/ipa/Payload/
	cd build/ipa && zip -qry ../$(APP_NAME).ipa Payload
	@echo "Wrote build/$(APP_NAME).ipa — import it into SideStore/AltStore once."

## archive: build a Release .xcarchive (upload with `make testflight`)
.PHONY: archive
archive:
	set -o pipefail; $(XCODEBUILD) archive \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(ARCHIVE_CONFIG) \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE_PATH) \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) $(FORMATTER)
	@echo "Archived build $(BUILD_NUMBER) -> $(ARCHIVE_PATH)"

## testflight: archive + upload to App Store Connect for internal testing
.PHONY: testflight
testflight: archive
	@test -n "$(ASC_KEY_ID)" || { echo "ASC_KEY_ID is unset. Set it in Makefile.local — it's the 10-character code in the key filename (AuthKey_XXXXXXXXXX.p8)."; exit 1; }
	@test -n "$(ASC_ISSUER_ID)" || { echo "ASC_ISSUER_ID is unset. Set it in Makefile.local — find it at the top of App Store Connect > Users and Access > Integrations > App Store Connect API."; exit 1; }
	@test -f "$(ASC_KEY_PATH)" || { echo "No API key at $(ASC_KEY_PATH). The .p8 downloads only once; if it's gone, revoke the key in App Store Connect and issue a new one."; exit 1; }
	set -o pipefail; $(XCODEBUILD) -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportOptionsPlist $(EXPORT_OPTIONS) \
		-exportPath build/export \
		-authenticationKeyPath $(ASC_KEY_PATH) \
		-authenticationKeyID $(ASC_KEY_ID) \
		-authenticationKeyIssuerID $(ASC_ISSUER_ID) $(FORMATTER)
	@echo "Uploaded build $(BUILD_NUMBER). Processing takes 5-15 min, then it appears in TestFlight."

## test-unit: run Swift Testing unit tests (the CI gate)
.PHONY: test-unit test
test-unit test:
	set -o pipefail; $(XCODEBUILD) test \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing:$(UNIT_TARGET) $(FORMATTER)

## test-ui: run the XCUITest suite (slower — boots a simulator and drives the app)
# ReaderIPhoneUITests is skipped here — compact-height Mode B auto-entry
# (PLAN 6B §B) never triggers on the iPad, by design, so it can't pass on
# this destination. `test-ui-iphone` is its lane.
.PHONY: test-ui
test-ui:
	set -o pipefail; $(XCODEBUILD) test \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing:$(UI_TARGET) \
		-skip-testing:$(UI_TARGET)/ReaderIPhoneUITests $(FORMATTER)

## test-all: run the unit and UI suites together
.PHONY: test-all
test-all:
	set -o pipefail; $(XCODEBUILD) test \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-skip-testing:$(UI_TARGET)/ReaderIPhoneUITests $(FORMATTER)

## test-ui-iphone: run the iPhone-only reader suite (PLAN 6B) against IPHONE_SIMULATOR_NAME
.PHONY: test-ui-iphone
test-ui-iphone:
	set -o pipefail; $(XCODEBUILD) test \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(IPHONE_DESTINATION)' \
		-only-testing:$(UI_TARGET)/ReaderIPhoneUITests $(FORMATTER)

## komga-up: start the local Komga test instance (docker)
.PHONY: komga-up
komga-up:
	@test -d "$(KOMGA_DIR)" || { echo "KOMGA_DIR not found: $(KOMGA_DIR). Set it in Makefile.local."; exit 1; }
	$(MAKE) -C "$(KOMGA_DIR)" up
	@printf "waiting for Komga to answer /actuator/health"
	@for i in $$(seq 1 60); do \
		if curl -fsS -m 2 "$(KOMGA_URL)/actuator/health" >/dev/null 2>&1; then \
			echo " — up."; exit 0; \
		fi; \
		printf "."; sleep 2; \
	done; \
	echo " — timed out. Try 'make komga-logs'."; exit 1

## komga-down: stop and remove the local Komga container (data/ is kept)
.PHONY: komga-down
komga-down:
	$(MAKE) -C "$(KOMGA_DIR)" down

## komga-stop: stop the local Komga container, keep it around
.PHONY: komga-stop
komga-stop:
	$(MAKE) -C "$(KOMGA_DIR)" stop

## komga-logs: follow the local Komga container logs
.PHONY: komga-logs
komga-logs:
	$(MAKE) -C "$(KOMGA_DIR)" logs

## komga-check: verify the local Komga instance is reachable and the key works
.PHONY: komga-check
komga-check:
	@echo "URL: $(KOMGA_URL)"
	@printf "health:   "
	@curl -fsS -m 5 "$(KOMGA_URL)/actuator/health" || { echo "UNREACHABLE — run 'make komga-up'."; exit 1; }
	@echo
	@if [ -n "$(KOMGA_API_KEY)" ]; then \
		printf "api key:  "; \
		curl -fsS -m 5 -H "X-API-Key: $(KOMGA_API_KEY)" "$(KOMGA_URL)/api/v2/users/me" \
			|| { echo "REJECTED — the key may have been revoked."; exit 1; }; \
		echo; \
	else \
		echo "api key:  (KOMGA_API_KEY unset — skipped)"; \
	fi
	@if [ -n "$(KOMGA_EMAIL)" ] && [ -n "$(KOMGA_PASSWORD)" ]; then \
		printf "basic:    "; \
		curl -fsS -m 5 -o /dev/null -w "OK (bootstrap path works)\n" \
			-u "$(KOMGA_EMAIL):$(KOMGA_PASSWORD)" "$(KOMGA_URL)/api/v2/users/me" \
			|| echo "REJECTED — check KOMGA_EMAIL/KOMGA_PASSWORD."; \
	else \
		echo "basic:    (KOMGA_EMAIL/KOMGA_PASSWORD unset — skipped)"; \
	fi

## komga-address: print what to type on the connect screen (simulator vs device)
.PHONY: komga-address
komga-address:
	@echo "simulator: localhost:25600"
	@echo "device:    $$(ipconfig getifaddr en0 2>/dev/null || echo '<mac-lan-ip>'):25600"
	@echo
	@echo "The simulator shares the Mac's network stack, so localhost reaches the"
	@echo "container. A physical iPad is a separate host and needs the LAN address."

## test-integration: run the live-server tests against local Komga (needs komga-up)
.PHONY: test-integration
test-integration:
	@test -n "$(KOMGA_API_KEY)" || { echo "KOMGA_API_KEY is unset — set it in Makefile.local."; exit 1; }
	@curl -fsS -m 5 "$(KOMGA_URL)/actuator/health" >/dev/null 2>&1 \
		|| { echo "Komga is not answering at $(KOMGA_URL) — run 'make komga-up'."; exit 1; }
	# There is no xcodebuild flag for test-process environment variables, and
	# TEST_RUNNER_* only applies to UI-test runners — for app-hosted unit tests
	# it silently does nothing. So: build, inject into the generated .xctestrun,
	# then run that. Credentials go into a gitignored build/ artifact, never a
	# committed scheme or test plan.
	set -o pipefail; $(XCODEBUILD) build-for-testing \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(INTEGRATION_DERIVED) $(FORMATTER)
	@xctestrun=$$(ls -t $(INTEGRATION_DERIVED)/Build/Products/*.xctestrun 2>/dev/null | head -1); \
	test -n "$$xctestrun" || { echo "No .xctestrun produced."; exit 1; }; \
	for pair in KOMGA_URL:'$(KOMGA_URL)' KOMGA_API_KEY:'$(KOMGA_API_KEY)' \
	            KOMGA_EMAIL:'$(KOMGA_EMAIL)' KOMGA_PASSWORD:'$(KOMGA_PASSWORD)'; do \
		key=$${pair%%:*}; value=$${pair#*:}; \
		[ -n "$$value" ] || continue; \
		plutil -replace "$(UNIT_TARGET).EnvironmentVariables.$$key" -string "$$value" "$$xctestrun"; \
	done; \
	echo "Injected Komga settings into $$(basename "$$xctestrun")"; \
	set -o pipefail; $(XCODEBUILD) test-without-building \
		-xctestrun "$$xctestrun" \
		-destination '$(DESTINATION)' \
		-only-testing:$(UNIT_TARGET) $(FORMATTER)

## clean: remove build artifacts
.PHONY: clean
clean:
	$(XCODEBUILD) clean -project $(PROJECT) -scheme $(SCHEME)
	rm -rf .build KontinuityCore/.build build
