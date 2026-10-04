# Age of Empires II (2013)

Recipe: [aoe2-hd.json](../aoe2-hd.json)

## Launcher window

**Symptom.** Steam starts a small launcher. The launcher fails or shows an empty window.

**Change.** `directLaunch` is true. The recipe starts `AoK HD.exe`.

**Reuse.** Use this when Steam starts a launcher and the real game executable is in the install folder.

## Steam restart check

**Symptom.** A direct start stops with a Steam error, or Steam opens the launcher again.

**Change.** The recipe sets `SteamAppId` and `SteamGameId` to `221380`, and writes `steam_appid.txt` with that id.

**Reuse.** Use this when the game calls `SteamAPI_RestartAppIfNecessary`.

## Intro video

**Symptom.** The game stops on the first frame of an intro video.

**Change.** The recipe passes `SKIPINTRO`.

**Reuse.** Look in the executable for a skip argument. Pass it in `executableArguments`, or move the video aside with `quarantineFiles`.
