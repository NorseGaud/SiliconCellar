# Releasing

Bare `make` (the `all` target) runs lint, tests, a debug build, a **forced** Engine refresh (`make engine` downloads the pinned NorseGaud/wine Engine release), then a Developer ID–signed, notarized, stapled DMG. CI stays unsigned (`make ci` only) and does not download the Engine.

Pin lives in `engine/manifest.json` (NorseGaud/wine release tag, URL + SHA-256). `make engine` sets `FORCE_ENGINE_BUILD=1` so release always refreshes from that pin (archive cache under `.build/engine-cache/` is reused when the hash matches).

## Version

Set the marketing version in the root `VERSION` file (for example `0.1.0`). `make` and `make app` use that for `CFBundleShortVersionString`.

The build number defaults to the git commit count (`git rev-list --count HEAD`). Override once with:

```sh
make version=0.1.1 build_number=42
```

The DMG name is `SiliconCellar-<version>-<build>.dmg`.

## One-time credentials

Credentials stay in your login keychain. Do not put Apple passwords, API keys, or `.p8` files in the repository.

1. Install a **Developer ID Application** certificate for team `4JD8RUCQ2W` in your login keychain.
2. Store a notary profile (default name `siliconcellar`):

```sh
xcrun notarytool store-credentials siliconcellar
```

Prefer an **App Store Connect API** key:

1. Create a key in [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).
2. Download the `.p8` once.
3. When `store-credentials` asks for the private key path, give the **full path to the `.p8` file** (not a folder).
4. Enter the Key ID and Issuer ID.

You can leave the API key path empty and use an Apple ID plus an [app-specific password](https://appleid.apple.com/account/manage) instead.

## Build the DMG

```sh
make
```

That flow:

1. Lints sources, recipes, and shell scripts
2. Runs `swift test`
3. Runs `swift build` (debug)
4. Refreshes the Wine Engine into `.build/engine` from the pinned NorseGaud/wine release (`FORCE_ENGINE_BUILD=1`), then release `dist/SiliconCellar.app` with `Contents/Resources/Engine`. `scripts/slim-engine.py` removes debug data from the Windows DLLs, GStreamer plugins that Wine does not use, and the dylibs that only those plugins used (about 1.2 GB to 600 MB)
5. Codesigns every Engine Mach-O (`wine`, `wineserver`, `*.so`, tools) with Wine entitlements, then the nested CLI and the app (hardened runtime + timestamp)
6. Creates an LZMA-compressed (`ULMO`) DMG with the app and an Applications shortcut
7. Submits the DMG with `notarytool`, waits, staples, and validates

Use `make dist` if you only need the release package steps (app, sign, DMG, notarize).

## Overrides

```sh
make NOTARY_PROFILE=other-name
make CODESIGN_IDENTITY='Developer ID Application: …'
```

## GitHub release and Homebrew cask

The cask is `Casks/siliconcellar.rb` in the tap repo [NorseGaud/homebrew-siliconcellar](https://github.com/NorseGaud/homebrew-siliconcellar). It is a separate repo because `brew tap` clones the full repo and `brew update` fetches every new commit. Users install with:

```sh
brew install --cask norsegaud/siliconcellar/siliconcellar
```

One time:

1. Sign in to `gh` with write access to `NorseGaud/SiliconCellar` (`gh auth login`)
2. Clone the tap next to this repo: `git clone git@github.com:NorseGaud/homebrew-siliconcellar.git ../homebrew-siliconcellar` (or set `HOMEBREW_TAP_DIR` to another checkout)

```sh
make release
```

That flow:

1. Stops if the tap checkout is missing, the working tree has uncommitted changes, `HEAD` is not pushed, or release `<version>` is already published (then bump `VERSION`)
2. Runs `make dist` (signed, notarized DMG)
3. Creates or updates the **draft** release `<version>` at `HEAD`. The notes list the commits since the last published release and are replaced on every run
4. Deletes old `SiliconCellar-<version>-*.dmg` assets from the draft and uploads the new DMG
5. Writes `version "<version>,<build>"` and the DMG `sha256` into `../homebrew-siliconcellar/Casks/siliconcellar.rb`

Then, by hand:

1. Download the DMG from the draft release and test it
2. Publish the release and set it as latest
3. Commit and push `Casks/siliconcellar.rb` in the tap repo

Homebrew cannot download draft assets, so `brew install --cask norsegaud/siliconcellar/siliconcellar` works only after step 2 and step 3. To update the cask without a release (for example, after a manual upload), run `./scripts/update-cask.sh <version> <build> <dmg>`.

The cask is not in the official `homebrew/cask` repo yet. That repo needs at least 225 stars, 90 forks, or 90 watchers for a self-submission, and a repo at least 30 days old. It also does not accept new casks that need Rosetta while macOS 27 is the latest macOS, and the bundled Wine is x86_64. See [Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy) and [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks).
