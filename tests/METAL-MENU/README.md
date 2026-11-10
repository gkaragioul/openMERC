<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

The `om_menutesttime` cvar selects a fixed presentation clock in milliseconds.
It defaults to `-1`, is not archived, and any negative value selects the normal
OS clock. Zero is a valid fixed timestamp. Fractional values truncate to whole
milliseconds; nonfinite/out-of-range values select the normal clock.

Menu creation/pop timestamps, screen-open timestamps, animation evaluation,
rotation and the per-frame menu snapshot share this clock. A cvar change during
drawing takes effect at the next frame; outside drawing it takes effect at the
next clock query. Switching back to a negative value returns to current OS time.
Existing screen/event timestamps are not rebased: close the menu before changing
clocks, then reopen it. The test tour's timeout, creation-performance timing and
network ping timing continue to use real time.

For a renderer comparison, prepare a fresh isolated `-user` directory for each
run, copy these `.cfg` files into its root and these `.rmf` files into its
`menus/` directory. Never copy into game-data directories. Use identical baseline
config, assets, window size **1920x1080** and engine build for GL3 and Metal;
change only the renderer selector. The native SoF menu table must be integrated
before a Metal image can prove native-menu coverage.

Run one of these console commands per controlled launch:

```text
exec om_clock_legacy.cfg
exec om_clock_modern.cfg
exec om_clock_fractional.cfg
```

The configurations use the existing `om_after`, `om_menushot`, `om_menudump` and
`om_menukey none 0 0` commands. They capture a static clipped-control page and a
stock-model page. The controls use a black background; the model transition
explicitly enables `menu_livebg` so its stock background model is visible. Captures
use fixed frame counts, then restore the normal clock and quit. The stock sequence/model names are references from the user's game data;
the fixture contains no copied game assets. Each model explicitly uses `time
0.0`, avoiding a `waitanim` screen whose animation can never finish when frozen.
The shared pointer position is set after each page opens because menu creation
initially centres it. Avoid physical pointer/gamepad input during capture.

The configurations set `scr_menuoverlay 1` after each page opens, with
`menu_livebg 0` for controls, so `SCR_SoF_Frame` skips the forced offline console and any live
world. `gl_clear 1` with `gl_ztrick 0` clears the GL3 reference to black, matching
Metal's initial frame clear. This matters because `con_notifytime` only governs
transient notify rows: offline `Con_DrawConsole(1.0)` also draws its real-time
date/clock stamp. `con_notifytime -1` additionally rejects even same-tick notify
rows. `om_menudump` runs at frames 3/15; `clear` removes the console text at
frames 4/16; captures run separately at frames 8/20. Clearing the console does
not erase the logfile. `menuoff` resets `scr_menuoverlay`, so the second menu
transition sets it again explicitly.

Expected captures are `<user>/menushots/clock_{legacy,modern,fractional}_{page,model}.tga`.
Legacy uses bitmap fonts and scale 1; modern uses TrueType and scale 2;
fractional uses TrueType and scale 1.5. Compare each visible feature's footprint,
not just a whole-frame average. The model poses and clock should be reproducible
across repeated runs; no capture/repeatability claim is made until the launch
coordinator actually executes and verifies these fixtures.

The title uses `<frame topic 0 48>`: in RMF, zero width cuts a full-width row.
Any nonzero width cuts a column, even if height is also supplied. The following
`<frame main 320 176>` therefore starts below the 48-unit title and keeps a
320-unit control column. With the legacy 1920x1080 scale-1 default rectangle
`(640,300,640,480)`, expected frame rectangles are title `(640,300,640,48)` and
main `(640,348,320,176)`. The control crop is **320x176+640+348**; the combined
title/control crop is **640x224+640+300**. These are legacy coordinates: use each
modern/fractional run's actual dump and renderer scale to derive its pixel crop.
Before accepting image comparisons, require nonzero main dimensions and visible
input, slider, list and text widgets in `om_menudump` and the capture.

C137's original fixture used a 640-wide title column, exhausting the parent and
leaving main at zero width/height. That capture provides no clipped-control
proof. Preserve the original C137/C138 user copies and captures; copy this fixed
fixture only into new run directories and obtain a fresh matching GL3/Metal pair.
The stock model fixture is unchanged by this correction.
The original model capture also includes offline console text; it cannot prove
clean model-image parity against a fresh capture with the corrected background.

To tour existing menus at a fixed initial pose instead:

```text
menuoff
set om_menutesttime 1000
om_menutour 8 stay main player
```

Use pages without `waitanim`, real-time/live network content or an expectation
that a frozen animation reaches EOS. A fixed menu clock does not freeze the game
world, external cvars or server data. After a tour, `menuoff` then `set
om_menutesttime -1` restores normal presentation.

The standalone clock regression is `bash tools/build/tests/test-menu-clock.sh`.
It compiles production clock, creation/pop, draw and model-update functions with
controlled OS/cvar/render boundaries and runs with ASan/UBSan; it does not launch
the game. `OM_MENU_CLOCK_SOURCE` and `OM_MENU_MODEL_SOURCE` allow running the same
checks against retained before-source files.
