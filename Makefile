# Kontinuity — task runner.
# CI workflows call these same targets, so `make <x>` behaves identically
# locally and in GitHub Actions. Run `make` (or `make help`) for the list.

# Per-machine overrides (e.g. DEVICE_ID) live here — gitignored, never committed.
# Copy Makefile.local.example to Makefile.local and fill it in. The `-` makes
# the include silent when the file is absent (CI doesn't need it).
-include Makefile.local

PROJECT        := Kontinuity.xcodeproj
SCHEME         := Kontinuity
UNIT_TARGET    := KontinuityTests
UI_TARGET      := KontinuityUITests

# Simulator destination. The iPad is the primary target — iPhone support comes
# later (see .claude/PLAN.md phase 7), so the default sim is an iPad.
SIMULATOR_NAME ?= iPad Pro 13-inch (M5)
# arch=arm64 pins the native slice so xcodebuild doesn't warn about matching
# both the arm64 and x86_64/Rosetta slice of the same simulator.
DESTINATION    ?= platform=iOS Simulator,name=$(SIMULATOR_NAME),arch=arm64

# On-device deploy (free Apple ID). Apps signed by a free Personal Team stop
# launching after 7 days, so re-run `make deploy` weekly with the iPad plugged
# in (or paired over Wi-Fi). DEVICE_ID comes from `xcrun devicectl list devices`
# — set it in Makefile.local (or `make deploy DEVICE_ID=...`).
APP_NAME       ?= Kontinuity
DEVICE_CONFIG  ?= Debug
DEVICE_DERIVED ?= build/device
DEVICE_ID      ?=
DEVICE_APP     := $(DEVICE_DERIVED)/Build/Products/$(DEVICE_CONFIG)-iphoneos/$(APP_NAME).app

# Free Personal Team provisioning profiles expire 7 days after they're *created*,
# not after they're deployed. `-allowProvisioningUpdates` reuses a cached profile
# while it's still valid, so a mid-week deploy re-signs with a profile whose clock
# already started — the app dies 7 days after the FIRST deploy of the cycle. We
# delete our cached profiles before each deploy so Xcode mints fresh ones with a
# full 7-day window. Only profiles matching BUNDLE_PREFIX are touched.
PROFILE_DIR    := $(HOME)/Library/Developer/Xcode/UserData/Provisioning Profiles
BUNDLE_PREFIX  ?= org.mattnitzken.Kontinuity

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

## install-tools: install SwiftLint + SwiftFormat (via Homebrew)
.PHONY: install-tools
install-tools:
	brew install swiftlint swiftformat xcbeautify

## install-hooks: enable the repo's git pre-commit hook
.PHONY: install-hooks
install-hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled (lint + format-check)."

## lint: run SwiftLint (strict — warnings fail)
.PHONY: lint
lint:
	swiftlint lint --strict

## format: rewrite sources with SwiftFormat
.PHONY: format
format:
	swiftformat .

## format-check: verify formatting without rewriting (used in CI)
.PHONY: format-check
format-check:
	swiftformat --lint .

## build: build the app for the simulator
.PHONY: build
build:
	set -o pipefail; $(XCODEBUILD) build \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' $(FORMATTER)

## deploy: re-sign + install to the iPad over cable/Wi-Fi (weekly 7-day refresh)
.PHONY: deploy
deploy:
	@test -n "$(DEVICE_ID)" || { echo "DEVICE_ID is unset. Set it in Makefile.local (copy Makefile.local.example) or pass DEVICE_ID=... — find it via 'xcrun devicectl list devices'."; exit 1; }
	@echo "Purging cached provisioning profiles for $(BUNDLE_PREFIX) so a fresh 7-day profile is minted…"
	@if [ -d "$(PROFILE_DIR)" ]; then \
		for f in "$(PROFILE_DIR)"/*.mobileprovision; do \
			[ -e "$$f" ] || continue; \
			if security cms -D -i "$$f" 2>/dev/null | grep -q "$(BUNDLE_PREFIX)"; then \
				rm -f "$$f" && echo "  removed $$(basename "$$f")"; \
			fi; \
		done; \
	fi
	set -o pipefail; $(XCODEBUILD) build \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(DEVICE_CONFIG) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		-derivedDataPath $(DEVICE_DERIVED) $(FORMATTER)
	xcrun devicectl device install app --device $(DEVICE_ID) "$(DEVICE_APP)"
	@echo "Installed $(APP_NAME) — good for ~7 days. Re-run \`make deploy\` to refresh."

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

## test-unit: run Swift Testing unit tests (the CI gate)
.PHONY: test-unit test
test-unit test:
	set -o pipefail; $(XCODEBUILD) test \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing:$(UNIT_TARGET) $(FORMATTER)

## test-ui: run the XCUITest suite (slower — boots a simulator and drives the app)
.PHONY: test-ui
test-ui:
	set -o pipefail; $(XCODEBUILD) test \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing:$(UI_TARGET) $(FORMATTER)

## test-all: run the unit and UI suites together
.PHONY: test-all
test-all:
	set -o pipefail; $(XCODEBUILD) test \
		-project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' $(FORMATTER)

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
