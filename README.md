<p align="center">
  <img src="design/app-icon-artwork.png" alt="Silicon Cellar artwork" width="420">
</p>

# Silicon Cellar

Run Windows Steam games that you own on Apple Silicon. The app bundles Wine Staging. It does not include game files or a game license.

> **Limited time.** macOS warns that support for Intel-based apps is ending. Silicon Cellar bundles Wine Staging, which still runs as Intel code under Rosetta. Enjoy it while you can.
>
> <p align="center">
>   <img src="images/ending-support-intel.png" alt="macOS alert: Support Ending for Intel-based Apps" width="480">
> </p>

## What you need

- An Apple Silicon Mac
- Rosetta
- Wine Staging 11.x bundled in the app (`Contents/Resources/Engine`). Packaging downloads a pinned [Gcenx macOS Wine build](https://github.com/Gcenx/macOS_Wine_builds/releases).
- A Steam account that owns the game

## Install

```sh
brew install --cask norsegaud/siliconcellar/siliconcellar
```

The cask is in [NorseGaud/homebrew-siliconcellar](https://github.com/NorseGaud/homebrew-siliconcellar). Or download the DMG from [Releases](https://github.com/NorseGaud/SiliconCellar/releases). `brew uninstall --zap --cask siliconcellar` also removes the Wine prefix, Steam, and games under `~/Library/Application Support/SiliconCellar`.

## Build

For day-to-day development (lint, test, `make dev`, Engine build), see [CONTRIBUTING.md](CONTRIBUTING.md).

```sh
cd ~/DEV/siliconcellar
make
```

Bare `make` runs lint, tests, a debug build, a fresh Engine fetch from the pinned Gcenx release, then the signed and notarized release DMG. See [RELEASING.md](RELEASING.md) for credentials.

CLI binary: `.build/debug/siliconcellar-cli`  
App bundle: `dist/SiliconCellar.app`  
Engine: `dist/SiliconCellar.app/Contents/Resources/Engine/`  
DMG: `SiliconCellar-<version>-<build>.dmg`

For daily UI work, run `make dev`. That builds SiliconCellar, wraps it in `.build/dev/SiliconCellar.app` (with the app icon), opens the window, and relaunches after you save a Swift or recipe file. This is a rebuild, not an in-place hot reload. Stop with Ctrl+C. `make app` builds only the packaged `dist/SiliconCellar.app`. `make ci` is the unsigned CI path (no Engine download).

## Add a game

Copy `Recipes/spacewar.json` and change the fields:

```json
{
  "id": "my-game",
  "title": "My Game",
  "steamID": "123456",
  "installFolder": "My Game Folder",
  "executable": "MyGame.exe",
  "executableRelativePath": "Binaries/Win64/MyGame.exe",
  "wineWindowsVersion": "win10",
  "steamArguments": [],
  "environment": {},
  "dllOverrides": "dxgi,d3d11,d3d12=n,b"
}
```

Put the file in `Recipes/` or in `~/Library/Application Support/SiliconCellar/Recipes/`. The `id` must match the file name. `steamID` is the Steam app number. `installFolder` is the Steam `installdir` name.

## CLI

```sh
siliconcellar list
siliconcellar setup --game spacewar
siliconcellar steam --game spacewar
siliconcellar logout --game spacewar
siliconcellar install --game spacewar
siliconcellar uninstall --game spacewar
siliconcellar play --game spacewar
siliconcellar stop --game spacewar
```

Optional: `--data-root PATH`, `--recipes PATH`, `SILICONCELLAR_WINE`, `SILICONCELLAR_RECIPES`.

All games share one Wine prefix at `~/Library/Application Support/SiliconCellar/prefix`. The Steam client lives in that prefix. Setup deletes leftover `Games/` and `SteamCMD/` folders from older Silicon Cellar builds. Recipes stay.

## Flow

**App:** Install Rosetta if it is missing. Launch `SiliconCellar.app` with a bundled Engine. The detail pane shows one action per row, in order: **Install Steam** / **Stop Steam**, **Sign in** / **Sign out of Steam**, **Install game** / **Uninstall**, **Play** / **Stop**. Each button swaps when the status changes. **Sign in** opens the Steam window. Sign in there. Silicon Cellar does not take an account name or password.

**CLI:** Install Rosetta. Use a packaged app Engine, or set `SILICONCELLAR_WINE` to a `wine` binary. Then:

1. Run `setup`. The tool creates a Wine prefix and installs the official Steam client.
2. Run `steam` and sign in in the Steam window.
3. Run `install`, then `play`. Play starts Steam with `-applaunch`.

The Steam client owns sign-in, ownership, and updates. Only one Wine session may run. **Sign out** / `logout` clears local `loginusers.vdf` when Steam is not running. If Steam is open, sign out in the Steam window.

## Wine location

The tool looks for Wine in this order:

1. `SILICONCELLAR_WINE`
2. `SiliconCellar.app/Contents/Resources/Engine/bin/wine` (bundled)
3. `~/Library/Application Support/SiliconCellar/Wine/Wine Staging.app/.../wine` (one-release fallback)

Pin and fetch script: `engine/manifest.json` and `scripts/build-wine-engine.sh` (Gcenx Staging tarball).

## Network

Silicon Cellar starts these HTTPS connections. A firewall may ask you to allow them.

**Gcenx Wine Staging package (package time only)**

- When: local `make engine` / `make app` / `make` if Engine is missing or forced
- Host: `github.com` (release assets), TCP 443
- Why: download the pinned `wine-staging-*-osx64.tar.xz` from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds/releases)

**Official Steam installer**

- When: `setup` or first Steam launch, if `SteamSetup.exe` is not already cached with the pinned SHA-256
- Command: `/usr/bin/curl` with `--proto =https` and `--proto-redir =https`
- Host: `cdn.akamai.steamstatic.com`, TCP 443
- URL: `https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe`
- Why: install the official Steam client in the shared Wine prefix. Setup checks the SHA-256 before the installer runs.

The Steam client talks to Valve servers for sign-in, ownership, game files, and updates. A game may open more connections. Silicon Cellar does not control those.

The toolkit does not send analytics.

## Support

If Silicon Cellar helps you, you can [buy me a coffee](https://buymeacoffee.com/t2ihlmy2bu).
