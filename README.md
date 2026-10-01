<p align="center">
  <img src="design/app-icon-artwork.png" alt="Silicon Cellar artwork" width="420">
</p>

# Silicon Cellar

Run Windows Steam games that you own on Apple Silicon. The app bundles Wine. It does not include game files or a game license.

> **Limited time.** macOS warns that support for Intel-based apps is ending. Silicon Cellar bundles Wine, which still runs as Intel code under Rosetta. Enjoy it while you can.
>
> <p align="center">
>   <img src="images/ending-support-intel.png" alt="macOS alert: Support Ending for Intel-based Apps" width="480">
> </p>

## What you need

- An Apple Silicon Mac
- Rosetta
- The Wine Engine bundled in the app (`Contents/Resources/Engine`). It is Wine 11.0 from the CodeWeavers CrossOver 26.3 source with Silicon Cellar fixes, built in [NorseGaud/wine](https://github.com/NorseGaud/wine). Packaging downloads the pinned [release](https://github.com/NorseGaud/wine/releases).
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

Bare `make` runs lint, tests, a debug build, a fresh Engine fetch from the pinned NorseGaud/wine release, then the signed and notarized release DMG. See [RELEASING.md](RELEASING.md) for credentials.

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

### Launcher

A recipe with `steamID` can use Steam. A recipe with `battleNetProductCode` can use Battle.net. That code is the one that Battle.net uses in `--exec="launch <code>"` (for example `OSI` for Diablo II: Resurrected). For Battle.net, `installFolder` is the folder that Battle.net makes in `C:\Program Files (x86)`.

A recipe with both can use either launcher. Steam is the default. In the app, choose **Steam** or **Battle.net** at the top of the game page. With the CLI, use `launcher --game ID --use steam|battlenet`. Silicon Cellar saves the choice in `launcher-choices.json` in the data folder. Each launcher has its own prefix, so each launcher installs its own copy of the game. Use the launcher of the store where you bought the game. The optional `launcher` field sets a fixed launcher for a recipe. See `Recipes/d2r.json`.

The optional `profileFolders` field lists folders under the Windows user profile (`C:\users\crossover`) that Silicon Cellar creates before play. D2R from Steam needs `AppData/Local/Blizzard Entertainment/ClientSdk`. Without it, the game says that you were not online in the last 30 days.

### Renderer

The optional `renderer` field selects the Direct3D layer for the game's executable. Steam and other games keep Wine's own layers.

| `renderer` | Layer | Licence |
| --- | --- | --- |
| `wine` (default) | Wine wined3d (Direct3D 9 to 11) and vkd3d (Direct3D 12) | LGPL 2.1 |
| `dxvk` | DXVK-Sikarugir-async v1.10.3 (Direct3D 9 to 11 on Vulkan) | zlib |
| `dxmt` | DXMT v0.80-213-g4ddb20e (Direct3D 10 and 11 on Metal) | LGPL 2.1 |
| `dxmt-v0.72` | DXMT v0.72 | MIT |
| `d3dmetal` | Apple D3DMetal 4.0 beta 2 (Direct3D 11 and 12 on Metal) | Apple EA18380 |
| `d3dmetal-3.0` | Apple D3DMetal 3.0 | Apple EA18380 |

At the first **Play**, Silicon Cellar downloads the pinned package from [NorseGaud/siliconcellar-renderers](https://github.com/NorseGaud/siliconcellar-renderers/releases/tag/r1) into `~/Library/Application Support/SiliconCellar/renderers/<renderer>`, and checks its SHA-256. Each package contains the unchanged upstream files and their licences. Then Silicon Cellar writes `HKCU\Software\Wine\AppDefaults\<executable>\SiliconCellar\DllPath` (and `D3DSharedPath` for D3DMetal). The Engine loads the package DLLs for that executable only. Keep `dllOverrides` at `dxgi,d3d11,d3d12=n,b` (or include the DLLs of the layer).

Before a game uses D3DMetal, you must accept Apple's licence. The app shows it at the first **Play**. In the CLI, read `renderers/d3dmetal/License.rtf`, then run `siliconcellar accept-apple-license`. The licence permits use only to develop, test, or evaluate games, and only for non-commercial purposes.

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
siliconcellar accept-apple-license
```

Optional: `--data-root PATH`, `--recipes PATH`, `SILICONCELLAR_WINE`, `SILICONCELLAR_RECIPES`.

Each launcher has its own Wine prefix in `~/Library/Application Support/SiliconCellar`: `prefix` for Steam and `prefix-battlenet` for Battle.net. All games of a launcher share its prefix, so a problem in one launcher cannot break the other. Steam and Battle.net can run at the same time. **Stop** and `stop` close only the launcher of the selected game. Each launcher runs one install or launch at a time. Setup deletes leftover `Games/` and `SteamCMD/` folders from older Silicon Cellar builds. Recipes stay.

## Flow

**App:** Install Rosetta if it is missing. Launch `SiliconCellar.app` with a bundled Engine. The detail pane shows one action per row, in order: **Install Steam** / **Stop Steam**, **Sign in** / **Sign out of Steam**, **Install game** / **Uninstall**, **Play** / **Stop**. Each button swaps when the status changes. **Sign in** opens the Steam window. Sign in there. Silicon Cellar does not take an account name or password.

**CLI:** Install Rosetta. Use a packaged app Engine, or set `SILICONCELLAR_WINE` to a `wine` binary. Then:

1. Run `setup`. The tool creates a Wine prefix and installs the official Steam client.
2. Run `steam` and sign in in the Steam window.
3. Run `install`, then `play`. Play starts Steam with `-applaunch`.

The Steam client owns sign-in, ownership, and updates. **Sign out** / `logout` clears local `loginusers.vdf` when Steam is not running. If Steam is open, sign out in the Steam window.

For a Battle.net game, the same steps use Battle.net. `setup` installs the official Battle.net client and opens it. Sign in in the Battle.net window. `install` opens the game page. Click **Install** there, and Silicon Cellar waits until Battle.net finishes. `play` sets the renderer, then runs `Battle.net.exe --exec="launch <code>"`. Silicon Cellar sets `Client.HardwareAcceleration` to `false` in `Battle.net.config`, because the Battle.net window can stay black in Wine. It also runs Battle.net with two Wine fixes. `WINE_SIMULATE_WRITECOPY=1` stops the page processes of Battle.net from crashing (only the loading icon shows without it). `--in-process-gpu` makes Chromium draw in the Battle.net window (the window stays white without it). `logout` removes the saved account name. To end the sign-in, sign out in the Battle.net window.

## Wine location

The tool looks for Wine in this order:

1. `SILICONCELLAR_WINE`
2. `SiliconCellar.app/Contents/Resources/Engine/bin/wine` (bundled)
3. `~/Library/Application Support/SiliconCellar/Wine/Wine Staging.app/.../wine` (one-release fallback)

Pin and fetch script: `engine/manifest.json` and `scripts/build-wine-engine.sh` (release tarball). To compile the same tag from source, run `make engine-source`. That clones [NorseGaud/wine](https://github.com/NorseGaud/wine) into `.build/wine-src` and runs its `build/build-engine.sh` (hours; needs x86_64 Homebrew in `/usr/local`, see `build/README.md` there).

The Engine records its ID in `Engine/.siliconcellar-engine-version`. When the ID changes (for example after an app update), the next Steam launch runs `wineboot --update` in the shared prefix. Steam and the games stay.

The CrossOver-based Engine keeps the Windows profile in `C:\users\crossover`. On the first update from an older Engine, the app moves the old profile folder (named after your Mac user) there and leaves a link with the old name. The app sets `CX_REPORT_REAL_USERNAME=1`, so Windows programs still see your Mac user name. Steam needs this to keep the saved sign-in.

The app ships the Wine licence (`Contents/Resources/Licenses/Wine-LGPL.txt`) and the source link (`Wine-SOURCE.txt`). The licences of the bundled libraries are in `Contents/Resources/Engine/share/doc`.

## Network

Silicon Cellar starts these HTTPS connections. A firewall may ask you to allow them.

**Wine Engine package (package time only)**

- When: local `make engine` / `make app` / `make` if Engine is missing or forced
- Host: `github.com` (release assets), TCP 443
- Why: download the pinned `siliconcellar-wine-*-x86_64.tar.xz` from [NorseGaud/wine](https://github.com/NorseGaud/wine/releases)

**Official Steam installer**

- When: `setup` or first Steam launch, if `SteamSetup.exe` is not already cached with the pinned SHA-256
- Command: `/usr/bin/curl` with `--proto =https` and `--proto-redir =https`
- Host: `cdn.akamai.steamstatic.com`, TCP 443
- URL: `https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe`
- Why: install the official Steam client in the shared Wine prefix. Setup checks the SHA-256 before the installer runs.

**Official Battle.net installer**

- When: `setup` of a Battle.net game, if `Battle.net-Setup.exe` is not already cached with the pinned SHA-256
- Command: `/usr/bin/curl` with `--proto =https` and `--proto-redir =https`
- Host: `downloader.battle.net`, TCP 443
- URL: `https://downloader.battle.net/download/installer/win/1.0.66/Battle.net-Setup.exe`
- Why: install the official Battle.net client in the Battle.net Wine prefix. Setup checks the SHA-256 before the installer runs. The installer then downloads the client from Blizzard servers.

**Renderer packages**

- When: first `play` of a game whose recipe sets a `renderer` other than `wine`, if the package is not already installed with the pinned SHA-256
- Command: `/usr/bin/curl` with `--proto =https` and `--proto-redir =https`
- Host: `github.com` (release assets), TCP 443
- URL: `https://github.com/NorseGaud/siliconcellar-renderers/releases/download/r1/<renderer>.tar.xz`
- Why: install DXVK, DXMT, or D3DMetal. Play checks the SHA-256 before it extracts the package.

The Steam client talks to Valve servers for sign-in, ownership, game files, and updates. The Battle.net client talks to Blizzard servers for the same things. A game may open more connections. Silicon Cellar does not control those.

The toolkit does not send analytics.

## Roadmap

Do these items in order. Each item gets its own design, plan, and tests. After each item, the app must build, pass tests, and run the current games. Fork third-party code into the NorseGaud GitHub account when we need a copy.

- [x] **1. Engine.** Fork the CodeWeavers CrossOver 26.3 source (`crossover-sources-26.3.0.tar.gz`, LGPL) into `NorseGaud/wine`. Change `make engine` to build that fork instead of downloading Gcenx Wine Staging. Done in release [`sc-26.3.0-2`](https://github.com/NorseGaud/wine/releases/tag/sc-26.3.0-2). The D3DMetal load check moved to item 2. Add these Wine fixes:
  - `BOOLEAN` syscall arguments: clang assumes that callers extend small arguments, but Windows callers set only the low byte. `NtQueryDirectoryObject` then misreads its flags, and Path of Exile 2 freezes after login. Backport the upstream Wine fix (`d1415ab24e`, `f43402cde3`, test `565091afa4`), which wraps every affected syscall.
  - San Andreas DE: add `--in-process-gpu --use-gl=angle --use-angle=swiftshader` to `SocialClubHelper.exe` so Rockstar sign-in works. The recipe sets `SILICONCELLAR_CHILD_ARGS`.
  - Controllers: build `winebus` with SDL2.
  - Age of Mythology: Retold: fit fullscreen below the MacBook notch in `winemac`. The recipe sets the `FullscreenBelowNotch` Mac driver option (`macDriverOptions`).
  - Add the Wine LGPL notice and a source link to the app.
- [x] **2. Renderers.** Add the recipe `renderer` field (see [Renderer](#renderer)). Packages are in release [`r1`](https://github.com/NorseGaud/siliconcellar-renderers/releases/tag/r1) of [NorseGaud/siliconcellar-renderers](https://github.com/NorseGaud/siliconcellar-renderers). Its `build-packages.sh` makes them from pinned inputs:
  - DXVK and DXMT: from the Sikarugir renderer package ([Sikarugir-App/Wrapper](https://github.com/Sikarugir-App/Wrapper/releases) `Template-1.0.15.tar.xz`, SHA-256 `34273bcce885ce5a7fd6937af9ea344bb9961de7d55d6193f7413142e835c8c3`). Upstream [DXMT v0.72](https://github.com/3Shain/dxmt/releases/tag/v0.72) for Skyrim, because v0.80 crashes after the intro. The Skyrim recipe uses `dxmt-v0.72`.
  - D3DMetal: the unchanged `redist` folder of Apple's "Evaluation environment for Windows games", with Apple's `License.rtf` and `Acknowledgements.rtf`. The Template also contains D3DMetal 3.0, but the package uses Apple's DMG so that it has Apple's licence files. Apple's licence (EA18380) permits non-commercial distribution of `D3DMetal.framework` and of the files in `/redist`. The default is 4.0 beta 2 (DMG SHA-256 `6248a0edc61553790753e5e9c060b8e53c940ed197f11409dcc34a35e05becc1`). The fallback is 3.0 (DMG SHA-256 `d49395fb07e536804d1da0858590e53f6aa6fab12512e18fd80a74c87f9f063c`). The app shows Apple's licence before the first D3DMetal game.
  - Engine [`sc-26.3.0-4`](https://github.com/NorseGaud/wine/releases/tag/sc-26.3.0-4): Steam and the game share one Wine session, so an environment variable cannot select the layer for one game. The Engine reads `AppDefaults\<executable>\SiliconCellar\DllPath` and `D3DSharedPath` when a process starts. This replaces the closed CrossOver `cxcompatdb.so`. The folder can also add DLLs that Wine does not have, such as DXMT `winemetal.dll`.
  - Remove the old cleanup that deleted `/Applications/Game Porting Toolkit.app`.
- [ ] **3. Launchers.** Add a `launcher` field to recipes: `steam` or `battlenet` (see [Launcher](#launcher)). Add the Battle.net install, sign-in, and play flow with the official Blizzard installer (pinned SHA-256). Allow recipes without a `steamID`. Add Diablo II: Resurrected (`D2R.exe`, install folder `Diablo II Resurrected`, renderer `d3dmetal`).
  - Battle.net has its own prefix, `prefix-battlenet`. The process list does not show which prefix a `wineserver` serves, so Silicon Cellar checks the server socket of each prefix (`/tmp/.wine-<uid>/server-<device>-<inode>/socket`).
  - A recipe with both a `steamID` and a `battleNetProductCode` can use either launcher. Steam is the default, and the user chooses for each game. D2R has both (Steam app `2536520`).
  - The code and tests are done. To do: a live test with a Battle.net account, to confirm the sign-in mark (`Client.SavedAccountNames`) and the install mark (`.build.info` in the game folder). Also a live test of D2R from Steam.
- [ ] **4. Per-game fixes.**
  - Witcher 3: fork [tholtman1-del/witcher3-crossover-fix](https://github.com/tholtman1-del/witcher3-crossover-fix) (MIT) to NorseGaud. Build the FidelityFX proxy ourselves. Install it before play and remove it on uninstall.
  - Company of Heroes 3: use the Wine Staging `ucrtbase.dll`.
  - Age of Empires III and Elden Ring: seed default graphics settings.
  - Red Alert 2 and Heroes III: use cnc-ddraw.
  - Zero Hour: install the community GeneralsOnline release (pinned SHA-256).
  - Heroes III: apply the stereo audio fix by Narzoul.
  - Age of Empires II: cache the DLC check that slows the game. This patches game code, so a game update can break it.
- [ ] **5. Shader pre-build.** Build DXMT shader pipelines before play for Counter-Strike 2 and Overwatch to reduce first-play stutter.
- [ ] **6. Re-test every recipe.** Pick the working renderer and launcher for each recipe and record it in the recipe.

## Support

If Silicon Cellar helps you, you can [buy me a coffee](https://buymeacoffee.com/t2ihlmy2bu).
