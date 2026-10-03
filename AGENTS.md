# Agent notes

## Release notes

Release notes say that a game is supported. Name the game. When two editions exist, name the edition. Do not explain the fix.

Write the fix on that game's line in [`Recipes/QUEUE.md`](Recipes/QUEUE.md), or in the docs, when the recipe does not follow Steam's default launch or needs another special step.

## X post

Use this shape. Put the game name in the first line. When two editions exist, name the edition there. Do not explain the fix.

```
<Game> now runs in Silicon Cellar.

It is a Windows Steam game, on Apple Silicon.

Check out the full library of supported games and help us add more to the open source project!

https://github.com/NorseGaud/SiliconCellar
```

Example: [Assassin's Creed](https://x.com/norsegaud/status/2106179251112132703).

## Bundled libraries

Store a play-time binary in `Sources/SiliconCellarCore/Fixes` as a `.tar.xz` archive. Play unpacks it only when the destination file's SHA-256 does not match. Pin the archive SHA-256 and the unpacked file SHA-256 in `GameFixes`. Record the source in `Fixes/PROVENANCE.txt`.

Archive a library the app copies into a game folder, such as a DLL. Leave small text files as they are: XML, INI, GLSL, licence, and notice files. Do not archive Wine's prefix or the Engine.
