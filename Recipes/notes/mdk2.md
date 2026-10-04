# MDK 2

Recipe: [mdk2.json](../mdk2.json)

## Video mode and display lists

**Symptom.** The game does not open a usable window, or the picture does not update.

**Change.** Play writes `save/config.lua`. The video mode uses the display size. Sound uses the software mixer. Display lists stay off. `wineVirtualDesktop` is `fit`, so the desktop is the largest standard size that fits the Mac screen. `wineD3DRenderer` is `gl`. `directLaunch` starts `mdk2Main.exe`.

**Reuse.** Use `seedFiles` when a game reads its video mode from a config file before the first frame. Use `fit` when an odd Mac size, such as 1920×1242, makes the game exit with no window.
