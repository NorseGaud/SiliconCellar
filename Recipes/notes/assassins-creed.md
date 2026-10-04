# Assassin's Creed

Recipe: [assassins-creed.json](../assassins-creed.json)

## DirectX 10 launcher

**Symptom.** The launcher picks DirectX 10 and the game freezes.

**Change.** `directLaunch` is true. The recipe starts `AssassinsCreed_Dx9.exe`.

**Reuse.** Use this when a launcher picks a DirectX 10 executable and a DirectX 9 executable is in the install folder.
