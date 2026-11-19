# Takeover — native macOS SwiftUI app (+ TakeoverCLI)
# Run `make help` for a grouped list of targets.

APP         := Takeover
SCHEME      := Takeover
CLI_SCHEME  := TakeoverCLI
CLI_NAME    := takeover
PROJECT     := Takeover.xcodeproj
BUNDLE_ID   := org.perfectink.takeover

BUILD_DIR   := build
DEV_APP     := $(BUILD_DIR)/Build/Products/Debug/$(APP).app
RELEASE_APP := $(BUILD_DIR)/Build/Products/Release/$(APP).app
CLI_SRC     := $(BUILD_DIR)/Build/Products/Release/$(CLI_NAME)

DMG         := $(BUILD_DIR)/$(APP).dmg

INSTALL_DST := /Applications/$(APP).app
# macOS caches app icons by bundle path, so an in-place update keeps showing
# the old icon. Touching the bundle and re-registering it refreshes the cache.
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PREFIX      ?= /usr/local
CLI_DST     := $(PREFIX)/bin/$(CLI_NAME)

# A Mac without an "Apple Development" identity (e.g. a fresh Mac with only
# Xcode installed) signs Release builds ad hoc instead, so build/install/cli
# still work there. Ad hoc signatures change on every build, so Full Disk
# Access has to be granted again after each reinstall.
HAS_DEV_ID  := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" && echo yes)
ifeq ($(HAS_DEV_ID),yes)
SIGN_FLAGS  :=
else
SIGN_FLAGS  := CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
endif

# The app's version is VERSION (semver), and its build number is the commit
# count, so every build says exactly what it is. `make release` bumps VERSION;
# nothing else does (docs/rules/versioning.md).
VERSION       := $(shell cat VERSION)
BUILD_NUMBER  := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
VERSION_FLAGS := MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

# Extra xcodebuild settings for Release builds, e.g. a Developer ID signing
# identity from CI.
XCODE_FLAGS ?=

.DEFAULT_GOAL := all

.PHONY: all help setup dev open close test build install uninstall reinstall \
        package cli install-cli verify-sign reset-tcc catalog clean version release

##@ Common

all: setup dev ## Default. Same as `make setup dev`.

help: ## Show this help, grouped by category.
	@awk 'BEGIN {FS = ":.*##"; printf "\nTakeover make targets\n"} \
		/^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
		/^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""

##@ Setup

setup: ## Set up the environment if needed: check the toolchain, resolve SPM deps.
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found (install Xcode)"; exit 1; }
	@xcodebuild -version | head -n 1
	@echo "Resolving Swift package dependencies..."
	@xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME) -quiet
	@if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then \
		echo "note: no \"Apple Development\" signing identity found — Release builds"; \
		echo "      (build/install/cli) will be signed ad hoc."; \
	fi

##@ Development

dev: ## Build a debug .app (replacing any previous one) and open it.
	-killall $(APP) 2>/dev/null; true
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(BUILD_DIR) -quiet build $(VERSION_FLAGS)
	@touch "$(DEV_APP)"; $(LSREGISTER) -f "$(DEV_APP)" 2>/dev/null; true
	open "$(DEV_APP)"

open: ## Open the already-built dev app (run `make dev` first if there isn't one).
	@if [ ! -d "$(DEV_APP)" ]; then \
		echo "No dev build at $(DEV_APP) yet — run 'make dev' first."; exit 1; \
	fi
	open "$(DEV_APP)"

close: ## Kill the running app. Only if native.
	-killall $(APP) 2>/dev/null; true

# Unit tests for the app target. (TakeoverUITests is intentionally excluded — it
# boots the full app and is slow/flaky for a plain `make test`.)
test: ## Run the unit-test suite.
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -only-testing:TakeoverTests test $(SIGN_FLAGS) $(VERSION_FLAGS)
	@echo "Tests completed successfully!"

##@ Production

build: catalog ## Build for production (Release), no install. Refreshes the offline catalogs first.
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(BUILD_DIR) -quiet build $(SIGN_FLAGS) $(VERSION_FLAGS) $(XCODE_FLAGS)
	@echo "==> $(RELEASE_APP)"

install: build ## Build for production and install to /Applications.
	-killall $(APP) 2>/dev/null; true
	@# Update in place (preserve the bundle path/inode) instead of rm -rf + cp -R.
	@# --delete removes files that no longer exist in the fresh build.
	mkdir -p "$(INSTALL_DST)"
	rsync -a --delete "$(RELEASE_APP)/" "$(INSTALL_DST)/"
	@touch "$(INSTALL_DST)"; $(LSREGISTER) -f "$(INSTALL_DST)" 2>/dev/null; true
	@$(MAKE) --no-print-directory verify-sign
	open "$(INSTALL_DST)"
	@echo "$(APP).app installed to $(INSTALL_DST)"

uninstall: close ## make close. Remove from /Applications, if installed.
	@if [ -d "$(INSTALL_DST)" ]; then \
		rm -rf "$(INSTALL_DST)"; echo "Uninstalled $(INSTALL_DST)"; \
	else \
		echo "$(APP) is not installed"; \
	fi

reinstall: uninstall install ## make uninstall, make install.

# For installing on another Mac without Xcode: copy the .dmg over, open it and
# drag Takeover to Applications. It isn't notarized, so the first launch
# needs right-click > Open (or System Settings > Privacy & Security > Open Anyway).
package: build ## Build for production and package it as build/Takeover.dmg.
	@rm -rf "$(BUILD_DIR)/dmg" "$(DMG)"
	mkdir -p "$(BUILD_DIR)/dmg"
	ditto "$(RELEASE_APP)" "$(BUILD_DIR)/dmg/$(APP).app"
	ln -s /Applications "$(BUILD_DIR)/dmg/Applications"
	hdiutil create -volname "$(APP)" -srcfolder "$(BUILD_DIR)/dmg" -ov -format UDZO "$(DMG)" -quiet
	@rm -rf "$(BUILD_DIR)/dmg"
	@echo "==> $(DMG)"

##@ CLI

cli: ## Build the `takeover` command-line tool (TakeoverCLI target).
	xcodebuild -project $(PROJECT) -scheme $(CLI_SCHEME) -configuration Release \
		-derivedDataPath $(BUILD_DIR) -quiet build $(SIGN_FLAGS) $(VERSION_FLAGS) $(XCODE_FLAGS)
	@echo "==> $(CLI_SRC)"

install-cli: cli ## Install the CLI to $(PREFIX)/bin.
	install -d "$(PREFIX)/bin"
	install -m 0755 "$(CLI_SRC)" "$(CLI_DST)"
	@echo "$(CLI_NAME) installed to $(CLI_DST)"

##@ Diagnostics

# Fails if the signature is broken, and prints the designated requirement so
# any drift in the signing identity (which is what silently revokes Full Disk
# Access / App Management grants) is visible on every install.
verify-sign: ## Verify the installed app's code signature.
	@echo "Verifying code signature..."
	codesign --verify --deep --strict --verbose=2 "$(INSTALL_DST)"
	@echo "Designated requirement:"
	@codesign -d --requirements - "$(INSTALL_DST)" 2>&1 | sed -n 's/^designated => /  /p'

reset-tcc: ## Forget every TCC grant for the app (re-prompt from a clean slate).
	-tccutil reset SystemPolicyAllFiles $(BUNDLE_ID)
	-tccutil reset SystemPolicyAppBundles $(BUNDLE_ID)
	-tccutil reset AppleEvents $(BUNDLE_ID)
	@echo "TCC grants reset for $(BUNDLE_ID)."

##@ Release

version: ## Print the app version and build number.
	@echo "$(VERSION) ($(BUILD_NUMBER))"

# Bumps VERSION (BUMP=patch, minor or major; patch by default), commits it,
# tags vX.Y.Z and pushes both. The tag makes CI build and publish the GitHub
# Release. Patch for fixes, minor for new features and UI changes; a major
# bump is Alex's call.
BUMP ?= patch
release: ## Bump VERSION (BUMP=patch|minor|major), tag vX.Y.Z and push; CI publishes it.
	@case "$(BUMP)" in patch|minor|major) ;; *) echo "error: BUMP must be patch, minor or major"; exit 1;; esac
	@test -z "$$(git status --porcelain)" || { echo "error: commit or stash your changes first"; exit 1; }
	@test "$$(git rev-parse --abbrev-ref HEAD)" = main || { echo "error: release from main"; exit 1; }
	@git fetch -q origin main && git merge-base --is-ancestor origin/main HEAD || { echo "error: pull origin/main first"; exit 1; }
	@new=$$(awk -F. -v b="$(BUMP)" '{ if (b == "major") print $$1+1 ".0.0"; else if (b == "minor") print $$1 "." $$2+1 ".0"; else print $$1 "." $$2 "." $$3+1 }' VERSION); \
	if git rev-parse -q --verify "refs/tags/v$$new" >/dev/null; then echo "error: tag v$$new already exists"; exit 1; fi; \
	echo "$$new" > VERSION && git add VERSION && git commit -q -m "Release v$$new" && \
	git tag -a "v$$new" -m "Takeover $$new" && git push origin main "v$$new" && \
	echo "Released v$$new. CI builds and publishes it."

##@ Maintenance

# Recipes live only in takeover-site's public/catalog/*.yaml. The app fetches
# them at runtime; the bundled copies are just the offline fallback, and every
# production build refreshes them first. Each catalog has a `version` (its
# revision), so the bundled copy is only replaced by a newer or equal one,
# and kept if takeoverapp.site can't be reached.
CATALOG_URL := https://takeoverapp.site/catalog

catalog: ## Refresh the bundled offline recipe catalogs from takeoverapp.site.
	@mkdir -p $(BUILD_DIR)
	@for pair in mac-defaults:mac-defaults-catalog apps:apps-catalog; do \
		src=$${pair%%:*}; dst="$(APP)/$${pair##*:}.yaml"; tmp="$(BUILD_DIR)/download-$$src.yaml"; \
		if ! curl -fsSL "$(CATALOG_URL)/$$src.yaml" -o "$$tmp"; then echo "warning: couldn't fetch $$src.yaml; keeping the bundled copy"; continue; fi; \
		new=$$(sed -n 's/^version: *//p' "$$tmp"); old=$$(sed -n 's/^version: *//p' "$$dst"); \
		if ! [ "$$new" -ge 1 ] 2>/dev/null; then \
			echo "warning: the site's $$src.yaml has no version; keeping the bundled copy"; \
		elif [ "$$new" -lt "$${old:-0}" ]; then \
			echo "warning: the site's $$src.yaml is v$$new, older than the bundled v$$old (not deployed yet?); keeping the bundled copy"; \
		else mv "$$tmp" "$$dst"; echo "Updated $$dst (v$$new)"; fi; \
	done

clean: ## Clean existing builds.
	rm -rf $(BUILD_DIR)
	@echo "Cleaned $(BUILD_DIR)"


AGENT_RULES ?= $(HOME)/Sites/agent-rules

rules: ## Sync shared agent rules from agent-rules into docs/rules/
	@$(AGENT_RULES)/bin/agent-rules sync "$(CURDIR)"

rules-check: ## Show what `make rules` would change (exit 1 if anything)
	@$(AGENT_RULES)/bin/agent-rules check "$(CURDIR)"
