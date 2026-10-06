.PHONY: all build test app engine engine-source engine-tag engine-pin dev clean lint ci sign create-dmg notarize dist release require-engine-tools

# Developer ID release signing (non-CI). Credentials stay in the login keychain.
CODESIGN_IDENTITY?=Developer ID Application: ONLYHUMN LLC (4JD8RUCQ2W)
DEVELOPMENT_TEAM?=4JD8RUCQ2W
NOTARY_PROFILE?=siliconcellar

version_file=VERSION
version_from_file=$(shell test -s $(version_file) && tr -d ' \t\r\n' <$(version_file))
version?=$(if $(version_from_file),$(version_from_file),0.1.0)
build_number?=$(shell git rev-list --count HEAD 2>/dev/null || echo 1)

APP=dist/SiliconCellar.app
DMG=SiliconCellar-$(version)-$(build_number).dmg

# Default: lint, test, debug build, fresh Wine Engine, then signed/notarized release DMG.
# CI must use `make ci` (unsigned app only; no Engine compile).
all: require-engine-tools lint test build engine dist

build:
	swift build

test:
	swift test
	./scripts/test-update-cask.sh

# Refresh the pinned NorseGaud/wine Engine release into .build/engine (download + unpack).
engine:
	FORCE_ENGINE_BUILD=1 ./scripts/build-wine-engine.sh

# Compile the wine/ submodule into .build/engine (hours; x86_64 Homebrew needed).
engine-source:
	./scripts/build-engine-source.sh

# Push the wine submodule, the next sc-* tag, and the submodule pointer. See RELEASING.md.
engine-tag:
	./scripts/tag-wine-engine.sh

# Commit and push engine/manifest.json after make engine.
engine-pin:
	./scripts/pin-wine-engine.sh

# mingw-w64 strip tools. scripts/slim-engine.py needs them. CI skips the Engine.
require-engine-tools:
ifndef CI
	python3 scripts/slim-engine.py --require-tools
endif

app: require-engine-tools
	VERSION="$(version)" BUILD_NUMBER="$(build_number)" ./scripts/package-app.sh

dev:
	./scripts/dev.sh

lint:
	swift format lint --strict --recursive Sources Tests Package.swift
	python3 -c 'import json, pathlib; paths = list(pathlib.Path("Recipes").glob("*.json")); [json.loads(path.read_text()) for path in paths]; print(f"validated {len(paths)} recipes")'
	sh -n scripts/app-bundle.sh
	sh -n scripts/package-app.sh
	sh -n scripts/build-wine-engine.sh
	sh -n scripts/build-engine-source.sh
	sh -n scripts/tag-wine-engine.sh
	sh -n scripts/pin-wine-engine.sh
	sh -n scripts/sign-app.sh
	sh -n scripts/make-dmg.sh
	python3 -c 'import ast, pathlib; [ast.parse(pathlib.Path(f"scripts/{name}").read_text()) for name in ("slim-engine.py", "steam-app-info.py")]'
	sh -n scripts/dev.sh
	sh -n scripts/update-cask.sh
	sh -n scripts/test-update-cask.sh
	sh -n scripts/publish-release.sh
	sh -n scripts/confirm-engine-pin.sh
	sh -n scripts/homebrew-tap.sh

ci: lint test app

sign: $(APP)
ifdef CI
	@echo 'CI: skipping codesign'
else
	CODESIGN_IDENTITY='$(CODESIGN_IDENTITY)' ./scripts/sign-app.sh '$(APP)'
endif

create-dmg: $(APP)
	./scripts/make-dmg.sh "$(version)" "$(build_number)"

notarize:
ifdef CI
	@echo 'CI: skipping notarize'
else
	@set -euo pipefail; \
	dmg='$(DMG)'; \
	test -f "$$dmg" || (echo "missing $$dmg; run make create-dmg first"; exit 1); \
	submission="$$(xcrun notarytool submit "$$dmg" --keychain-profile '$(NOTARY_PROFILE)' --wait --output-format json)"; \
	echo "$$submission"; \
	status="$$(printf '%s' "$$submission" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"; \
	if [ "$$status" != "Accepted" ]; then \
		id="$$(printf '%s' "$$submission" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"; \
		echo "Notarization status: $$status (expected Accepted)" >&2; \
		if [ -n "$$id" ]; then xcrun notarytool log "$$id" --keychain-profile '$(NOTARY_PROFILE)' >&2 || true; fi; \
		exit 1; \
	fi; \
	xcrun stapler staple "$$dmg"; \
	xcrun stapler validate "$$dmg"; \
	echo "Notarized $$dmg"
endif

# Release package step used by `all`. CI skips sign/DMG/notarize.
dist: app
ifdef CI
	@echo 'CI: skipping sign/DMG/notarize (use make ci)'
else
	$(MAKE) sign version="$(version)" build_number="$(build_number)"
	$(MAKE) create-dmg version="$(version)" build_number="$(build_number)"
	$(MAKE) notarize version="$(version)" build_number="$(build_number)"
endif

# Signed DMG → draft GitHub release → cask in homebrew-siliconcellar/. Publish and commit by hand.
release: require-engine-tools
ifdef CI
	@echo 'CI: skipping release'
else
	./scripts/publish-release.sh check "$(version)"
	@set -eu; \
	keep_pin="$$(./scripts/confirm-engine-pin.sh)"; \
	$(MAKE) dist KEEP_ENGINE_PIN="$$keep_pin" version="$(version)" build_number="$(build_number)"
	./scripts/publish-release.sh publish "$(version)" "$(build_number)" "$(DMG)"
endif

clean:
	rm -rf .build dist SiliconCellar-*.dmg
