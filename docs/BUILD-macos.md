# Building OpenMerc on macOS (Apple Silicon)

Status 2026-11-10: **the engine, the Metal renderer and the game/player modules build for arm64 and the game
plays** on macOS 27.2 with Apple clang and Homebrew SDL3. All 32 campaign levels load and run with `ref_metal`
(see `docs/METAL.md`). The build is green: `sofpm_test` 360/0, Ghoul 176/0. Without game data the engine stops at
`Could not open string package 'str_server'`; that is the expected missing-data message.

## Play

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