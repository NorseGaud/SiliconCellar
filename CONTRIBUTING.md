# Contributing

This guide is for local development on Silicon Cellar. For signed release DMGs, see [RELEASING.md](RELEASING.md). For product use, see [README.md](README.md).

## What you need

- An Apple Silicon Mac
- Xcode with Command Line Tools (Swift 5.9+, macOS 14+ SDK)
- Rosetta (`softwareupdate --install-rosetta --agree-to-license` if it is missing)
- `git`, `python3`, `curl`, `tar`, and `make`
- Network access to GitHub when you fetch the Engine

You do **not** need Apple Game Porting Toolkit or a local Wine compile. The app uses a pinned [Gcenx Wine Staging](https://github.com/Gcenx/macOS_Wine_builds/releases) package.

## Clone and enter the repo

```sh
git clone git@github.com:NorseGaud/SiliconCellar.git
cd SiliconCellar
```

## Fast loop (code and tests)

Use this for most day-to-day work. It does not compile Wine Staging and does not make a DMG.

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

If `.build/engine/bin/wine` exists, `make dev` copies that Engine into the dev app. Without it, the UI may report that the game runtime is missing until you fetch the Engine (below).

## Wine Staging Engine (first playable package)

The release app ships Wine at `Contents/Resources/Engine/`. Fetch the pinned Gcenx package once:

```sh
./scripts/build-wine-engine.sh
# or: make engine
```

Pin: `engine/manifest.json` (URL + SHA-256 for `wine-staging-*-osx64.tar.xz`). Output: `.build/engine/` (not committed). The binary is x86_64 and needs Rosetta.

Then package an unsigned app for local play:

```sh
make app
open dist/SiliconCellar.app
```

`make app` reuses `.build/engine` when the pin marker matches. Set `SKIP_ENGINE_BUILD=1` to package without Engine (for layout checks only). CI never downloads the Engine.

## Full local release (optional)

Bare `make` runs lint, test, debug build, a **fresh** Wine Staging Engine (`make engine`), then sign / DMG / notarize. That needs Developer ID and notary credentials. See [RELEASING.md](RELEASING.md).

| Command | Engine |
|---------|--------|
| `make` / `make engine` | Always re-fetches Engine (`FORCE_ENGINE_BUILD=1`) |
| `make app` | Fetches Engine only if missing or pin differs |
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
| `engine/manifest.json` | Pinned Gcenx Wine Staging package |
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
