# MDK

Recipe: [mdk.json](../mdk.json)

## Steam ddraw.dll

**Symptom.** The game does not draw. Steam ships `ddraw.dll` beside the executable.

**Change.** Play moves `ddraw.dll` aside. `dllOverrides` sets `ddraw=b`, so Wine supplies ddraw. The nGlide environment variables select the glide backend.

**Reuse.** Use `quarantineFiles` when an install-folder DLL replaces a Wine DLL and the game then fails to draw.

## Virtual desktop

**Symptom.** The game draws no window, or the window size does not match the Mac screen.

**Change.** `wineVirtualDesktop` is `display`. The Wine desktop matches the Mac screen. `wineD3DRenderer` is `gl`. `directLaunch` starts `MDK3DFX.EXE`.

**Reuse.** Use a Wine virtual desktop for an old Glide or DirectDraw title that does not draw in a normal window.
