# Building OpenMerc on macOS (Apple Silicon)

Status 2026-11-10: **the engine, the Metal renderer and the game/player modules build for arm64 and the game
plays** on macOS 27.2 with Apple clang and Homebrew SDL3. All 32 campaign levels load and run with `ref_metal`
(see `docs/METAL.md`). The build is green: `sofpm_test` 360/0, Ghoul 176/0. Without game data the engine stops at
`Could not open string package 'str_server'`; that is the expected missing-data message.

## Play

A ready-made app without game data can be built and given away: see "An app for other people" below. It asks for
your own game files on its first start. To build a private app with your game inside instead:

openMERC contains no game files. Copy the `.pak` files of your own copy of the game (`pak0.pak` ... `pak3.pak`,
`gs.pak`) into `game-data/sof/base` in this folder (git-ignored), then:

```sh
tools/build/build-macos.sh                 # builds into build-macos-arm64-Release/release
tools/build/make-macos-app.sh --install    # "Soldier of Fortune.app" in /Applications, with your game data inside
```

The app is a private build for your own copy of the game: it carries your game files, so never publish or share
it. Settings and saves go to `~/Library/Application Support/Soldier of Fortune/user`, the log of the last run to
`~/Library/Logs/Soldier of Fortune/last-run.log`. An app icon is optional: `tools/build/macos/AppIcon.icns`
(git-ignored) is used when present.

## What works

| Item | State |
|---|---|
| `openMerc`, `openMerc-ded` | arm64 Mach-O, start and print `--help`; client reaches data init and renders with `ref_metal` |
| `ref_gl3.dylib`, `ref_gles3.dylib` | built; development parity references only, not shipped |
| `ref_metal.dylib` | built; native Metal renderer, no GL/CGL/`NSOpenGL*`/Vulkan/MoltenVK/ANGLE dependency |
| `base/gamex86.dylib`, `base/player.dylib` | built; `GetGameAPI`, `GetPlayerClientAPI`, `GetPlayerServerAPI` resolve with `dlopen`/`dlsym` |
| `base/zz_openmerc.pak` | built from `data/base` |
| `OMsnd.dylib` | built when OpenAL Soft is installed (1.25.2 measured); engine exports made default-visible on Apple |
| unit tests | `pm_unit` all pass, `omghoul_test` passes, `sofpm_test` 360/0, Ghoul 175/0 |
| Metal contracts | 12 focused GPU/CPU contract scripts pass (targets, post-math, emission, bloom, fog, etc.) |

## Dependencies

```sh
xcode-select --install            # Apple clang (Command Line Tools are enough)
brew install cmake ninja sdl3     # SDL3 3.4.18 measured here; the tree asks for SDL 3
brew install openal-soft          # for the sound module (OMsnd.dylib)
```

The engine and renderers need no OpenGL headers or frameworks: `glad` resolves GL entry points
through SDL at runtime for `ref_gl3` (dev only). There is deliberately no Homebrew `libGL`/`mesa`
dependency. `ref_metal` links only Metal, QuartzCore, Foundation and SDL3.

## Build

```sh
tools/build/build-macos.sh                 # arm64 Release
tools/build/build-macos.sh arm64 Debug
OM_NO_TESTS=1 tools/build/build-macos.sh   # skip the unit tests
OM_SKIP_SOUND=1 tools/build/build-macos.sh # never build OMsnd
OM_BUILD_DIR=/tmp/om tools/build/build-macos.sh
```

The script configures and builds four CMake trees under `build-macos-arm64-Release/` (engine, game,
player, and sound when OpenAL Soft is present) and stages the result in `release/`:

| File | From |
|---|---|
| `release/openMerc`, `release/openMerc-ded` | engine (client, dedicated server) |
| `release/ref_metal.dylib` | engine renderer — **the shipping path** |
| `release/ref_gl3.dylib`, `release/ref_gles3.dylib` | engine renderers (dev parity only) |
| `release/OMsnd.dylib` | `modules/sound` (only when OpenAL Soft is installed) |
| `release/base/gamex86.dylib`, `release/base/player.dylib` | `game`, `player` |
| `release/base/zz_openmerc.pak` | `data/base` via `tools/mkpak.py` |

SDL3 is taken from `OM_SDL3_PREFIX` (default `/opt/homebrew`) through `CMAKE_PREFIX_PATH`; it is
linked as `/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib`, so a distributed app must bundle it or
relink with an `@rpath` install name.

The RLabs kit (pointer hiding, 120 Hz switch, variable refresh, Metal HUD setting, mouse resampling, app launcher)
is in `rlabs-kit/` in this project (see `rlabs-kit/README.md`). `RLABS_KIT=/other/rlabs-kit` names another copy:

```sh
tools/build/build-macos.sh                 # uses rlabs-kit/
tools/build/make-macos-app.sh --install    # the same kit folder the engine was configured with
rlabs-kit/tests/run-kit-tests.sh           # kit checks (against the old compiled kit when present)
```

Without the kit the engine still builds (CMake warns), but `make-macos-app.sh` refuses to package it.
A build tree configured in another folder (the project was moved) is configured afresh automatically.

## An app for other people (no game data)

`tools/build/make-macos-app.sh --no-data` builds the app that can be given away: it holds no game file. On its first
start it asks for the folder of the player's own copy of the game (the installed game's folder, its `base` folder, or
the folder an installer was unpacked into; it looks four folders deep, in upper or lower case), checks that
`pak0.pak` ... `pak3.pak` are there, copies them (and `gs.pak` when it is there) to
`~/Library/Application Support/Soldier of Fortune/game/base` and starts the game from that copy. Later starts ask
nothing. The chosen folder is only read. A folder without the game, or with files missing, gets a message that names
what is missing; files of another size than the 1.07f set get a warning and can be used anyway.
`--game-files <folder>` on the app's command line names the folder without the window (and brings in another copy
later). The code is `rlabs-kit/launcher/rlk_gamedata.m`; `rlabs-kit/tests/run-gamedata-test.sh` checks it on made-up
folders.

Homebrew's SDL3 and OpenAL Soft only run on the macOS they were bottled for (`minos 27.0` on a macOS 27 Homebrew),
so this app needs its own builds of both, for the oldest macOS it supports (`OM_MACOS_MIN`, default 13.0):

```sh
tools/build/build-macos-deps.sh        # SDL 3.4.18 and OpenAL Soft 1.25.2 from their release archives (SHA-256 checked)
P=$PWD/build-macos-deps/prefix
OM_SDL3_PREFIX=$P OM_OPENAL_PREFIX=$P OM_BUILD_DIR=$PWD/build-macos-release tools/build/build-macos.sh
OM_BUILD_DIR=$PWD/build-macos-release tools/build/make-macos-app.sh --no-data --version 1.0 --dmg /tmp/sof-out
```

The last command writes `Soldier of Fortune.app` and `Soldier-of-Fortune-for-Mac-1.0.dmg` and stops unless every
binary in the app runs on `OM_MACOS_MIN`, no Homebrew path is left in it, the ad-hoc signature verifies (also inside
the image) and no game file is in the app or the image. The only archive inside is openMERC's own
`zz_openmerc.pak` (menus, fonts and key defaults built from `data/base`). The licence texts and the source address are
in `Contents/Resources/licenses`. The app is signed ad hoc, not notarised: on the first start macOS asks the player
to allow it once in System Settings > Privacy & Security. Build outside iCloud-synced folders (`/tmp` above): codesign
refuses bundles made there.

### The oldest macOS: 13.0

- **Calls.** Built for macOS 11 with `-Wunguarded-availability`, the whole tree (engine, renderer, game, player,
  sound, kit) needs three newer calls: `NSScreen.minimumRefreshInterval` and `maximumRefreshInterval` (macOS 12,
  variable refresh) and `CAMetalLayer.developerHUDProperties` (macOS 13, the Performance HUD setting). At 13.0 nothing
  is newer, and `build-macos.sh` keeps `-Werror=unguarded-availability`, so a later call that needs a newer macOS
  stops the build.
- **Shaders.** `ref_metal` compiles its shaders at run time in the newest language of the running macOS; on macOS 13
  that is Metal Shading Language 3.0. `tools/build/tests/test-metal-msl-floor.sh` builds a small library that forces
  3.0 for every compile. Measured on 2026-11-10 (six levels on the Quality setting: subway, landscape, snow with fog,
  sewer, desert town, hotel): 35 shader libraries compiled, none failed, the levels drew normally.
- **Libraries.** SDL3 and OpenAL Soft are built for 13.0 by `build-macos-deps.sh`; `make-macos-app.sh --no-data`
  refuses an app with a binary that needs more.
- **Not checked.** The app has only been run on macOS 27.2 (Apple M5 Pro). No Mac with macOS 13 to 26 was
  available, so how the older systems' own Metal compilers and drivers behave is not known. Apple silicon only.

### Getting the game files from the Platinum Edition CD

The CD does not hold loose `.pak` files: they are inside an InstallShield archive (`Setup/data1.cab`).
[unshield](https://github.com/twogood/unshield) (`brew install unshield`) unpacks the data group and nothing else
(no program of the game is unpacked or run). With the CD or its image mounted as `/Volumes/Sofplat`:

```sh
mkdir ~/sof-files && cd ~/sof-files
unshield -g "Game Data Files" -d . x /Volumes/Sofplat/Setup/data1.cab
```

Measured with unshield 1.6.2 (about 6 seconds): `~/sof-files/Game_Data_Files/base` then holds the five files below,
and the app accepts `~/sof-files` as the game folder. The CD's `README.txt` says the Platinum Edition "is based upon
the 1.07f code"; these are the files the port was made and tested with.

| File | Bytes | SHA-256 |
|---|---|---|
| `pak0.pak` | 705825871 | `226766cd2ffa8329c3cd49db28818b8ddb55f65a1cc44115c405d99dde53548a` |
| `pak1.pak` | 20517183 | `46a4027c830060f405833c3ee8e1c1ab6400449f817deb8dae6d577082645a5e` |
| `pak2.pak` | 48985072 | `418517b10ca275d3b21ab9aa7d2b20f8810a027058b6bf33bac9b5526acf134f` |
| `pak3.pak` | 9406518 | `d72940364fbf523dd7ea208d1a51a56e0b55fab65ab2342a102d6f02d43dc970` |
| `gs.pak` | 205126 | `cd86986026a994c7aeec5bae5a633880661c0abda3be35b61b2b1a4d060898ce` |

Not tested: the GOG installer (a Windows program; no copy was available), and a game older than 1.07f. The app
refuses a folder that lacks `pak2.pak` or `pak3.pak` and says so; `gs.pak` (multiplayer menus of the 1.07f GameSpy
update) is optional, the menus and the first level were checked without it.

## Darwin changes in this port

1. `engine/src/server/sv_game.c`, `sv_player.c`: the non-Windows module name is `gamex86.dylib` /
   `player.dylib` on Apple (`#elif defined(__APPLE__)`) instead of `.so`. CMake already produces
   Mach-O `.dylib` for these targets on Darwin.
2. `tools/build/build-macos.sh`: the platform build script (model: `tools/build/build-linux.sh`),
   `-arch arm64`, `CMAKE_OSX_ARCHITECTURES=arm64`, `CURL_SUPPORT=OFF`, Homebrew SDL3 discovery.
3. `tools/build/check-modules-macos.c`: module-load smoke test (`dlopen` + `dlsym` of the entry
   points the engine looks up). Build and run it against `release/`.
4. `OM snd` exports: engine symbols made default-visible on Apple so OpenAL Soft resolves them via
   `dlsym(RTLD_DEFAULT, ...)` (Mach-O has no ELF version-script counterpart).

## Verified

- **`sofpm_test` W15b fixed**: Apple clang fused an expression where SPEC-314 requires separate
  float rounding; source-scoped `FP_CONTRACT OFF` in `sof_pmove.c` restores the contract. 360/0
  after the fix (was 345/1).
- **`omghoul_test`**: passes.
- **Ghoul**: 175/0 (expanded from 156 after M3 native Ghoul path).
- **No translation layers**: `otool -L` on `ref_metal.dylib` shows only Metal, QuartzCore,
  Foundation, SDL3 and system libs. No GL, CGL, `NSOpenGL*`, Vulkan, MoltenVK or ANGLE.

## Not done yet

- A ready-made download: the app is ad-hoc signed and built with your own game data; there is no notarised,
  data-free app that asks for the game on first start. No universal binary; the binaries target the macOS they
  are built on.
- Mode A (original 32-bit `gamex86.dll`/`player.dll`) is impossible on macOS; this port is
  mode B only.
- Full M5 post chain (bloom/emissive, soft particles, MSAA): see `docs/METAL.md` for what is done.
- Remaining M3/M4 acceptance: controlled MD2/SP2 fixtures, brush transforms, ground shadows,
  actual game-driven FX, standard particles, broader liquid variants.
- Stability workload (full campaign map with saves), input testing, clean rebuild reproduction.