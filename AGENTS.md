# Agent notes

Repo map: [CONTRIBUTING.md#project-layout](CONTRIBUTING.md#project-layout). Logs, prefixes, and Wine traces: [CONTRIBUTING.md#debugging](CONTRIBUTING.md#debugging).

## Host automation

Do not move the mouse on the host. Do not click at screen coordinates. Do not send keystrokes.

Automation is scripts and code: tests, the CLI, files, logs, and process checks. Drive Silicon Cellar and Wine through those. A pointer click, a coordinate click, or a keystroke on the host is not automation.

## Add a game

1. `scripts/steam-app-info.py <Steam app ID>` prints `installFolder` and the launch executables. Do not write a new Steam cache reader.
2. Copy the recipe of a similar game. Follow [Add a game](README.md#add-a-game). The field list with comments is `Recipe` in `Sources/SiliconCellarCore/Recipe.swift`.
3. Add the game to README "Supported games" with `[ ]`. `make test` (`testReadmeListsEveryBundledGame`) fails without it. Do not add the ID to a test list.
4. Run `swift test --filter testBundledRecipesValidate`. `make dev` reloads the recipe.
5. When the user confirms that the game plays, mark it `[x]` in README "Supported games" and in `Recipes/QUEUE.md`. When the recipe needs more than the default launch, write `Recipes/notes/<id>.md`. Link that file from the queue line.
6. If the game fails, read [Known patterns](#known-patterns) and [`Recipes/notes`](Recipes/notes/README.md) first.

## Add a launcher

Copy the RSI Launcher work (`RSI.swift`, `RSITests.swift`). Change these places:

1. `Recipe.swift`: a case in `Launcher` (`displayName`, `engineEnvironment`), the recipe field that enables it (like `rsiChannel`), `supportedLaunchers`, and the checks in `validate`.
2. `<Launcher>.swift`: the installer pin (versioned URL and SHA-256), process checks, and an `extension Runtime` with setup, sign-in, install, play, and logout.
3. `Runtime.swift`: each `switch recipe.launcherKind`. The compiler lists them when the enum has a new case: `isSignedIn`, `isLauncherClientInstalled`, `gameFolder`, `isGameInstalled`, `isLauncherClientRunning`, `setup`, `openLauncher`, `logout`, `installGame`, `uninstallGame`, `playGame`. Also add the `expected...SetupSHA256` and timeout properties.
4. `App.swift`: `widestActionTitle` (the longest button title), and the `launcherFrontActions` check when the launcher raises its own installer window.
5. `main.swift`: the `launcher --use` help text and its error text.
6. `RuntimeTests.swift`: a fake installer next to `fakeBattleNet` and `fakeRSI`.
7. README: "What you need", "Launcher", "Flow", "Network", and the prefix list.

## Known patterns

These fixes worked before. Try them before a new investigation. Do not search old agent chats for them.

- **Steam starts a small launcher that fails or shows an empty window.** Set `directLaunch: true` and `executable` to the real game (`aoe2-hd`, `assassins-creed`).
- **A direct start stops with a Steam error, or Steam opens the launcher again.** The game calls `SteamAPI_RestartAppIfNecessary`. Add `SteamAppId` and `SteamGameId` to `environment`, and `"seedFiles": {"steam_appid.txt": "<id>\n"}` (`aoe2-hd`).
- **The game stops on the first frame of an intro video.** Wine does not finish some WMV files. Look in the executable for a skip argument (`strings`), and pass it in `executableArguments` (`SKIPINTRO` in `aoe2-hd`). Or move the video aside with `quarantineFiles`.
- **A launcher picks DirectX 10 and the game freezes.** Start the DirectX 9 executable directly (`assassins-creed`).
- **A dialog says that a DLL is missing.** Find which import the DLL needs. If Wine does not have it, bundle it (see [Bundled libraries](#bundled-libraries)) and copy it in `GameFixes` (`aoe3-2007` and `mfc42.dll`).
- **A Chromium or Electron launcher page stays black, white, or loading.** It needs `WINE_SIMULATE_WRITECOPY=1` (`Launcher.engineEnvironment`) and `--in-process-gpu`. Battle.net also needs `Client.HardwareAcceleration` set to `false`.
- **The wrong window comes to the front.** The Steam windows belong to the Wine process that macOS names `steamwebhelper-valve`, not `steam.exe`. `Frontmost.swift` activates the process that owns the window, and raises its windows from the largest to the smallest, so dialogs stay on top. Raise once after a click. An installer window opens later, so raise it by name after it exists (`RSIInstaller.windowTitle`).
- **Keyboard input in Steam stops, but focus and the caret are correct.** Restart Steam from the app. The cause is not known. Turn on a key trace (see [Debugging](CONTRIBUTING.md#debugging)) before you try to find it.
- **A test passes on the Mac but times out in CI.** The GitHub macOS runner is slower. Do not use calls that can block in a pipe handler (`FileHandle.availableData`).

## Release notes

Release notes say that a game is supported. Name the game. When two editions exist, name the edition. Do not explain the fix.

When the recipe does not follow the default launch of its launcher, or needs another special step, write `Recipes/notes/<id>.md`. Use the sections in [Recipes/notes/README.md](Recipes/notes/README.md). Do not explain the fix in the release notes.

## X post

Use this shape. Put the game name in the first line. When two editions exist, name the edition there. `<Store>` is Steam, Battle.net, or the RSI Launcher (the launcher of the recipe). Do not explain the fix.

```
<Game> now runs in Silicon Cellar.

It is a Windows <Store> game, on Apple Silicon.

Check out the full library of supported games and help us add more to the open source project!

https://github.com/NorseGaud/SiliconCellar
```

Example: [Assassin's Creed](https://x.com/norsegaud/status/2106179251112132703).

## Bundled libraries

Store a play-time binary in `Sources/SiliconCellarCore/Fixes` as a `.tar.xz` archive. Play unpacks it only when the destination file's SHA-256 does not match. Pin the archive SHA-256 and the unpacked file SHA-256 in `GameFixes`. Record the source in `Fixes/PROVENANCE.txt`.

Archive a library the app copies into a game folder, such as a DLL. Leave small text files as they are: XML, INI, GLSL, licence, and notice files. Do not archive Wine's prefix or the Engine.

## Wine source

The Engine source is the `wine/` submodule (Wine 11.0 from CrossOver 26.3). Read Wine code there. Do not use another Wine tree, for example an upstream Wine release.
