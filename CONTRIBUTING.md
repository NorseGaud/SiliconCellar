# Contributing

This guide is for local development on Silicon Cellar. For signed release DMGs, see [RELEASING.md](RELEASING.md). For product use, see [README.md](README.md).

## What you need

- An Apple Silicon Mac
- Xcode with Command Line Tools (Swift 5.9+, macOS 14+ SDK)
- Rosetta (`softwareupdate --install-rosetta --agree-to-license` if it is missing)
- `git`, `python3`, `curl`, `tar`, and `make`
- `mingw-w64` (`brew install mingw-w64`) when you package the app with the Engine. `scripts/slim-engine.py` uses its `strip` tools
- Network access to GitHub when you fetch the Engine

You do **not** need Apple Game Porting Toolkit or a local Wine compile. The app uses a pinned [NorseGaud/wine](https://github.com/NorseGaud/wine/releases) Engine release (Wine 11.0 from the CrossOver 26.3 source with Silicon Cellar fixes).

## Clone and enter the repo

```sh
git clone git@github.com:NorseGaud/SiliconCellar.git
cd SiliconCellar
```

## Fast loop (code and tests)

Use this for most day-to-day work. It does not fetch or compile Wine and does not make a DMG.

```sh
make lint
make test
make build
```

| Command | What it does |
|---------|----------------|
| `make lint` | Swift format, recipe JSON, shell script syntax |
| `make test` | XCTest suite (`swift test`) |
| `make build` | Debug build of the CLI and app products |
| `make ci` | Lint + test + unsigned `make app` (CI path; skips Engine download) |

Debug binaries:

- CLI: `.build/debug/siliconcellar-cli`
- App binary: `.build/debug/SiliconCellar`

Override Wine for CLI tests against an existing install:

```sh
export SILICONCELLAR_WINE=/path/to/wine
.build/debug/siliconcellar-cli list
```

## UI development

```sh
make dev
```

This builds SiliconCellar, wraps it in `.build/dev/SiliconCellar.app`, opens the window, and rebuilds after you save Swift or recipe files. Stop with Ctrl+C. It is a full rebuild, not hot reload.

At start, `make dev` checks the latest [NorseGaud/wine](https://github.com/NorseGaud/wine/releases) release, gets it if it differs from `.build/engine` (below), then copies `.build/engine` into the dev app. Offline, it uses the Engine that `.build/engine` already has. File-change reloads keep the Engine that is in the dev app.

## Wine Engine (first playable package)

The release app ships Wine at `Contents/Resources/Engine/`. Fetch the latest release:

```sh
./scripts/build-wine-engine.sh
# or: make engine
```

Pin: `engine/manifest.json` (tag, URL and SHA-256 for `siliconcellar-wine-*-x86_64.tar.xz`). Output: `.build/engine/` (not committed). The binary is x86_64 and needs Rosetta.

Each run asks the GitHub API for the latest NorseGaud/wine release. If its tag differs from the pin, the script writes the new tag, URL and SHA-256 (from the release asset digest) into `engine/manifest.json`, then downloads and checks the archive. Commit the changed `engine/manifest.json`. If GitHub is not available, the script uses the current pin.

To compile the same tag yourself, run `make engine-source`. It clones [NorseGaud/wine](https://github.com/NorseGaud/wine) into `.build/wine-src` and runs `build/build-engine.sh` from that repo. That takes hours and needs x86_64 Homebrew in `/usr/local` (see `build/README.md` in the Wine repo). To change the Wine fixes, work in the Wine repo, push a new `sc-*` tag, and publish its release. The next `make engine`, `make app` or `make dev` pins it.

Then package an unsigned app for local play:

```sh
make app
open dist/SiliconCellar.app
```

`make app` reuses `.build/engine` when it matches the latest release. Set `SKIP_ENGINE_BUILD=1` to package without Engine (for layout checks only). CI never downloads the Engine.

## Full local release (optional)

Bare `make` runs lint, test, debug build, a **fresh** Wine Engine (`make engine`), then sign / DMG / notarize. That needs Developer ID and notary credentials. See [RELEASING.md](RELEASING.md).

| Command | Engine |
|---------|--------|
| `make` / `make engine` | Pins the latest release, then always re-fetches Engine (`FORCE_ENGINE_BUILD=1`) |
| `make app` / `make dev` | Pins the latest release, then fetches Engine only if missing or different |
| `make ci` | Skips Engine download |

For unsigned packaging only, use `make app` or `make ci`.

## Project layout

| Path | Role |
|------|------|
| `Sources/SiliconCellarCore/` | Shared library (Wine prefix, Steam, recipes) |
| `Sources/SiliconCellarApp/` | SwiftUI app |
| `Sources/siliconcellar/` | CLI |
| `Tests/SiliconCellarCoreTests/` | Unit tests |
| `Recipes/` | Bundled game recipes (JSON) |
| `engine/manifest.json` | Pinned NorseGaud/wine Engine release |
| `scripts/` | Package, Engine fetch, DMG, `dev.sh` |

## Recipes

Copy `Recipes/spacewar.json`, edit fields, keep `id` equal to the file name. Put personal recipes in `~/Library/Application Support/SiliconCellar/Recipes/` if you do not want them in git. Validate with `make lint`.

## Before you open a pull request

```sh
make lint
make test
make build
```

Keep changes focused. Do not commit `.build/`, Engine binaries, or Apple credentials.

## Clean

```sh
make clean
```

Removes `.build`, `dist`, and local DMGs. You must run `make engine` again after a clean if you need a playable app.
