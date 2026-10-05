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

## Get the source

Add an SSH key to your GitHub account. This repository and its submodules use SSH URLs.

```sh
git clone --recurse-submodules git@github.com:NorseGaud/SiliconCellar.git
cd SiliconCellar
```

If the clone is already on disk and a submodule folder is empty, check out the recorded commits:

```sh
git submodule update --init
```

Run that command again after `git pull`. It moves each submodule to the commit this repository records.

| Path | Branch | When you use it |
|------|--------|-----------------|
| `wine/` | `siliconcellar` | Wine source. Read the Engine here. `make engine-source` compiles this tree (hours; see `wine/build/README.md`). To publish an Engine release, follow [When Wine changes](RELEASING.md#when-wine-changes). |
| `homebrew-siliconcellar/` | `main` | Homebrew tap. `make release` writes `Casks/siliconcellar.rb` in this folder. |
| `siliconcellar-renderers/` | `main` | Builds the DXVK, DXMT, and D3DMetal packages. Change a package here. Play downloads a release of the packages. |

`make lint`, `make test`, `make build`, and `make dev` run in this repository. A playable app downloads the pinned Engine release. It does not compile `wine/`.

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

To compile the submodule yourself, run `make engine-source`. It runs `wine/build/build-engine.sh`. That takes hours and needs x86_64 Homebrew in `/usr/local` (see `wine/build/README.md`). To change the Wine fixes, edit the `wine/` submodule, commit there, then follow [When Wine changes](RELEASING.md#when-wine-changes): `make engine-tag`, wait for the tag build, then `make engine`, `make engine-pin`, and `make release`.

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
| `Sources/SiliconCellarCore/` | Shared library (Wine prefix, launchers, recipes). Files below |
| `Sources/SiliconCellarApp/App.swift` | SwiftUI app (one file) |
| `Sources/siliconcellar/main.swift` | CLI |
| `Tests/SiliconCellarCoreTests/` | Unit tests. `RuntimeTests.swift` has the fake Wine that the other tests use |
| `Recipes/` | Bundled game recipes (JSON) and `QUEUE.md` |
| `wine/` | NorseGaud/wine submodule (SSH). Engine source you edit |
| `homebrew-siliconcellar/` | NorseGaud/homebrew-siliconcellar submodule (SSH). Homebrew cask that `make release` updates |
| `siliconcellar-renderers/` | NorseGaud/siliconcellar-renderers submodule (SSH). Builds the DXVK, DXMT, and D3DMetal packages |
| `engine/manifest.json` | Pinned NorseGaud/wine Engine release |
| `scripts/` | Package, Engine fetch, DMG, `dev.sh`, `steam-app-info.py` |

Files in `Sources/SiliconCellarCore/`:

| File | Role |
|------|------|
| `Recipe.swift` | `Launcher` enum and the `Recipe` fields, with their checks |
| `RecipeStore.swift` | Loads `Recipes/` and the user recipe folder |
| `Runtime.swift` | Prefix setup, Steam, install, play, stop, Wine environment (`wineEnvironment`), `Library` |
| `BattleNet.swift`, `RSI.swift` | Battle.net and RSI Launcher parts of `Runtime` |
| `GameFixes.swift` | Per-game fixes at Play (`switch recipe.id`). Bundled files are in `Fixes/` |
| `Frontmost.swift` | Brings Wine windows to the front, Wine virtual desktop size |
| `SteamWebHelper.swift` | Bytes of the `steamwebhelper` wrapper (`scripts/steamwebhelper-wrap.c`) |
| `SteamLaunchProgress.swift` | Reads Steam logs to show launch progress |
| `Snapshot.swift` | `GameStage` and the state that the app shows |
| `Renderer.swift` | DXVK, DXMT, and D3DMetal packages |
| `LibraryStorage.swift`, `LibraryStorageMove.swift` | Where the library is stored, and moves to other disks |
| `CommandRunner.swift` | Runs processes and reads their output |

## Recipes

See [Add a game](README.md#add-a-game). `scripts/steam-app-info.py <Steam app ID>` prints the install folder and executables from the local Steam caches. `make test` checks that each recipe loads and is in the README "Supported games" list.

## Debugging

All data is in `~/Library/Application Support/SiliconCellar`.

| What | Where |
|------|-------|
| Silicon Cellar logs | `logs/`: `steam-bootstrap.log`, `steam-session.log`, `battlenet-setup.log`, `battlenet-session.log`, `rsi-setup.log`, `rsi-session.log` |
| Wine prefix of each launcher | `prefix`, `prefix-battlenet`, `prefix-rsi` |
| Steam logs | `prefix/drive_c/Program Files (x86)/Steam/logs/`. Start with `console_log.txt`, `gameprocess_log.txt`, `runprocess_log.txt`, `webhelper.txt`, and `cef_log.txt` |
| Steam game files | `prefix/drive_c/Program Files (x86)/Steam/steamapps/common/<installFolder>` |
| Windows user profile | `<prefix>/drive_c/users/crossover` (saves and settings in `AppData`) |
| `make dev` output | The terminal that runs `make dev` |

`wineEnvironment` in `Runtime.swift` sets `WINEDEBUG=-all`. To get a Wine trace, add `WINEDEBUG` to the `environment` of the recipe (for example `"WINEDEBUG": "+key,+keyboard"`). The recipe value replaces `-all`, and the trace goes into the session log of the launcher. `make dev` reloads after the recipe changes. Remove the value when you are done.

Do not start `steam.exe` by hand with your own environment. Steam started from a shell quits after about 2 seconds. Start it from the app or the CLI.

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
