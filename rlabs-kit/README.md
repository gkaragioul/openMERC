# RLabs kit

Small Mac helpers shared by the RLabs ports (GPL-2.0-or-later): pointer handling, display refresh, variable refresh,
the Metal Performance HUD setting, mouse resampling and the app launcher.

| Part | Files | What it does |
|---|---|---|
| Pointer | `macos/rlk_pointer.*` | One pointer over the game window: blank cursor + `CGDisplayHideCursor` while the app is active, its window key and the pointer inside; shown again otherwise (first used in the Thief Gold Mac port) |
| Refresh switch | `macos/rlk_display.*` | The game's screen runs at the fastest same-size mode the frame cap divides (144 -> 120 Hz), for this app only; restored on quit (Time Crisis, Thief) |
| Variable refresh | `macos/rlk_vrr.*` | VRR screens in full screen: present after a minimum duration; log lines for on/off |
| Performance HUD | `macos/rlk_hud.*` | Apple's Metal Performance HUD switched per layer when the launcher set `MTL_HUD_ENABLED=1` |
| Mouse | `input/rlk_mouse_motion.*` | Mouse reports resampled to frame times (first used in the Thief Gold Mac port) |
| Launcher | `launcher/rlk_launcher.c` | Compiled app launcher: folders in ~/Library, run log, environment, exec of the game |
| App | `launcher/make-app.sh`, `launcher/install-app.sh` | Self-contained app (bundled libraries, ad-hoc signature); install with rollbacks and a project copy |

## Use

`engine/CMakeLists.txt` takes the kit from `RLABS_KIT` (environment or `-DRLABS_KIT=`), else from this folder.
`tools/build/make-macos-app.sh` uses `launcher/` from the same place. Objective-C files are built with `-fobjc-arc`.

## Tests

`tests/run-kit-tests.sh` builds `tests/rlk_kit_test.m` against the sources (and, when a folder of
earlier compiled objects is present in `build.nosync/kit-baseline/objects`, against those too) and compares the results: the mouse resampler on recorded
and random report streams, the VRR interval, and the VRR/display/HUD answers that do not change the screen.
