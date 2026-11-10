# Native Metal renderer (`ref_metal`)

Status 2026-10-29: the generic M1 2D/window path and exercised M2 world fixtures work; native
SoF HUD and the exercised native menu controls/lit model pass their fixed fixtures.
The arm64 renderer owns its window through a
`CAMetalLayer`, draws the generic 2D path, and renders visible BSP world surfaces with PVS,
depth, lightmaps, sky and repeating world textures. M3 is in progress: the direct native Ghoul
sink now renders the exercised opaque, source-over and additive inputs. The C114 kos2 weapon
patch meets the bounded 1/255 gate; MD2/SP2 fixtures and ground shadows remain open. Inline
brush models are implemented with unit/lifecycle checks; transformed scene proof remains open.
The kos2 world detail pass now meets the bounded 1/255 gate in
fullbright, normal-lit and red-dynamic-light fixtures (C100–C104). M4's native SoF billboard,
oriented quad and beam pass the C118 same-record fixture at 0.317/255. Alternate blend/lit,
chains and LOD pass C123–C129 after the static-light cache repair. Actual game-driven FX and
visible standard particles remain open. The C156 water fixture passes 0.000973/255 after
the earlier 24.459/255 failure; clean C155 sky passes 0.012002/255 after loaded-ring repair.
Rotation/mip and broader liquid variants remain open. M5's per-pixel world lights are exercised;
native attachment-aware identity/emission/bloom helpers are integrated with offscreen checks,
while rebuilt scene acceptance, legacy/volumetric fog, soft particles and MSAA remain open.
The aggregate build is green (sofpm_test 360/0, Ghoul 175/0) after the arm64 W15b rounding repair.
C163 completes a full kos2→tsr1→saved-kos2 lifecycle with save/reload and cached thumbnail.
M5 post-identity, bloom and fog helpers are integrated; main fog render and MSAA remain open.
`ref_metal.dylib` links Metal, QuartzCore, Foundation and
SDL3 — no OpenGL, CGL, `NSOpenGL*`, Vulkan, MoltenVK or ANGLE symbol or library.

Build: `tools/build/build-macos.sh` produces `release/ref_metal.dylib`.
Run: `./openMerc -basedir <game data> +set vid_renderer metal`.

## Why a renderer module

The engine already loads renderers through `refexport_t` (28 entries, SPEC-002), so Metal is a
sibling of `ref_gl3`, not a fork of the engine. `ref_gl3` stays as the development parity
reference and is **not** shipped in a Metal release.

## Design decisions so far

- **No translation layer.** Metal only, reached from a `CAMetalLayer` that SDL3 attaches to the
  engine's window (`SDL_Metal_CreateView` / `SDL_Metal_GetLayer`).
- **Runtime MSL compilation** (`newLibraryWithSource`): the Command Line Tools on this host have
  no offline `metal`/`metallib` tool. Shaders are embedded as source strings, which keeps the
  build free of an Xcode toolchain dependency. Moving to a precompiled `.metallib` is a packaging
  step, not an architectural one.
- **NDC and winding follow GL**: Metal NDC is Y-up like GL, so the engine's projection keeps its
  Y sign; pixel-space 2D maps with `y_ndc = 1 - 2y/H`. Texture UVs keep the GL convention.
- **Textures** are `RGBA8Unorm`, uploaded from the shared loaders (`files/*.c`) with 8-bit
  palette expansion to RGBA on the CPU, so the SoF palette alpha survives.
- **Tracked attachments and view-local post passes.** World scene/emission and window/menu
  depth have separate ownership. Fences and thumbnails resume the actual targets and raster;
  post composition precedes screen tint and ordinary 2D. Single-sample helpers are verified;
  actual post/MSAA/lifecycle scene acceptance remains a separate gate.

## Milestones

| # | Scope | State |
|---|---|---|
| M1 | Window + layer + present, textures, full 2D path, `screenshot` command | Native HUD/menu/lit GPM and C163 cached thumbnail/save/load pass; gamma/restart and larger restoration workflows open |
| M2 | World: BSP surfaces, lightmaps, depth, PVS leaf marking, node walk | **done for the exercised world fixtures**; C57 repairs PVS; C100–C104 detail-enabled world patch passes at 0.109/255 fullbright, 0.295/255 normal, 0.189/255 red-lit |
| M3 | Sky faces, texture wrapping, models (MD2/SP2/Ghoul), skins, view weapon | **in progress**: Ghoul/weapon/stock sky pass fixed patches; C163 stock map/save reload passes; rotation/mip, brush transforms, MD2/SP2 scenes and ground shadows open |
| M4 | Water/turb, particles, temp entities, FX | **in progress**: primitives/blend/lit/chains/LOD and stock water pass bounded fixtures; actual game-driven FX, standard particles and broader liquid variants open |
| M5 | Post: bloom/emissive, volumetric + region fog, soft particles, per-pixel dlights | **in progress**: per-pixel dlights pass; identity/emission/bloom helper GPU checks pass; SPEC-410 region fog draws since 2026-11-08 (`mtl_fog_frame.h`; not `gl_fogmode 1`, and generic MD2 models are not fogged); volumetric fog pass since 2026-11-09 (`mtl_volfog_pass.h`, `r_om_volfog*`, A/B against GL); real post scene, soft particles and MSAA remain open |
| M6 | CSM shadows, MetalFX upscaling + dynamic resolution, argument buffers, indirect draws | CSM sun shadows done 2026-11-09 (`mtl_csm*.h`, `r_om_csm*`, see below); MetalFX, argument buffers and indirect draws not started |

### Defects found and fixed on the way

- **MSL `float3` is 16-byte aligned.** The shader vertex struct was 32 bytes while the C
  struct and descriptor were 28, so every vertex was read from the wrong offset while all data
  probes passed. Pad the C vertex and put uv/lightmap at 16/24.
- **World texture coordinates repeat.** Q2 `s`/`t` are texture-space multiples; sampling them
  with a clamp sampler flattens every surface to its edge texel. World = repeat, lightmaps =
  clamp. SoF UI uses separate repeat samplers, nearest at whole scale and linear at fractional scale; RAW follows the texture-mode magnification filter without mips.
- **Visibility belongs to the active renderer refdef.** The native renderer keeps its current
  frame in `mtl_refdef`; using GL3's `r_newrefdef` selected a PVS at `(0,0,0)` and culled the
  current camera's corridor. C57 proves that Metal's own refdef restores normal-culling world
  submission.
- **Ghoul needs model-owned winding, game time and system-level material preparation.** C105
  shows inside-out surfaces because the BSP clockwise convention was copied to CCW model
  fronts. C106 repairs winding; C108 preserves SoF game time to align pose. C111 proves GL's
  active specular pass; C112 enables Ghoul system method 2 as well as the per-draw flag. C113's
  explicit specular-off control reproduces the old image. C114's HUD-free weapon patch passes
  at 0.231352/255, compared to 9.20479/255 before specular preparation. The original taller
  crop included HUD pixels and is retained as a measurement correction in its receipt.

The world also owns a separate SPEC-410 detail/environment pass after opaque geometry. It
loads `.m32` detail metadata and uses 2x-modulate blending, read-only depth, dedicated no-alpha-
test pipelines and the configured polygon offset. C99 identifies the missing pass by disabling
only GL3 detail; C100 restores detail-enabled parity. Environment/distance/scroll variants are
implemented but still need attributable fixture evidence.

Each milestone is validated the same way: the same scene rendered by `ref_gl3` and `ref_metal`,
captured through the in-engine `screenshot` command, compared pixel by pixel, with a deliberate
mismatch as a control (a pattern proven on another Mac port).

## Goal: M5

The owner's target is a renderer that reaches **M5**: sky, models, water, particles and the
modern post chain (bloom/emissive, volumetric and region fog, soft particles, per-pixel dynamic
lights), all native Metal. Order of work: remaining M3 sky/model proof, M4 water/particles/FX,
M5 (post). Each step is gated by a capture diff against `ref_gl3` at the same camera.

## Current gates

- C115's native SoF HUD passes at 0.071591/255 in the bottom band. Real Set2D/Set3DInMenu/
  ReadThumbnail now activate native menus while preserving the capability guard. C139–C148:
  legacy controls0/255, modern full page0, fractional0.000140, lit GPM0.099881. Menu-state104/0
  and readback100/0 GPU checks pass. C163 completes kos2→tsr1→saved kos2 with a visibly valid
  cached thumbnail, 7035 save chunks/0 bad and exit0. Gamma/restart/larger workloads remain.
- M3 still needs controlled MD2/SP2, brush-entity and native ground-shadow coverage, plus
  broader Ghoul parity beyond the fixed kos2 weapon patch.
- M4 still needs actual game-driven FX, standard particles and liquid variants. World alpha now
  joins the shared entity/effect sort; C134/C135 stock fence patches pass0.023/0.029 per255.
  Overlap and animated/flow variants remain unproven.
- M5 identity/emission/bloom has native helper GPU evidence; root scene integration is awaiting
  a synchronized rebuild and controlled captures. Fog allocation is validated against all76
  shipped BSPs; this does not prove fog drawing. Legacy fog and MSAA remain required,
  alongside the remaining M3/M4 inputs. Soft particle math (mode, uniforms, eye-distance, fade)
  is implemented and tested (27/0). Volumetric fog region packing (sort, 8-float4 format,
  wanted/steps/noise/overlay) now matches GL3_Fog_VolumeRegions (test-metal-volfog.sh); the MSL
  raymarch (`mtl_volfog_shader.h`) and its integration landed 2026-11-09.
- The renderer currently favors one draw call per surface/quad for correctness. Batching and
  argument buffers are M6 work.


## Volumetric fog and cascaded sun shadows (2026-11-09)

`r_om_volfog` (`mtl_volfog.h` packing, `mtl_volfog_shader.h` MSL, `mtl_volfog_pass.h` glue) is the same design as
GL's: after the opaque world and its overlay pass, one full-view triangle reads the depth copy, clips the eye ray
against the regions seen this frame and marches `r_om_volfog_quality` steps (6/10/16/28). With the volumetric pass on the overlay
gives up part of its alpha (`r_om_volfog_overlaydim`, default 0.85, `mtl_fog_frame.h`). Noise, height falloff and
intensity as GL; `r_om_volfog_shafts` reads the static CSM layers when sun shadows are active.

`r_om_csm` (`mtl_csm_math.h`, `mtl_csm_shader.h`, `mtl_csm.h`) ports gl3_csm.c: the map's sun comes from the worldspawn keys
(SPEC-AMEND-016 R16.2, the same parser), four cascades are fitted to the view with whole-texel snapping, and two
depth layers are kept per cascade (static world, dynamic Ghoul casters of the previous frame). A lit world fragment
loses light only where the static world lets the sun through and a dynamic caster blocks it (`omCsmApply`, down to
the map's sun ambient), applied to the lightmap before dynamic lights; Ghoul ground shadows give way in the sun
(`r_om_csm_replace_ghl`), with the same contact-shadow remainder as GL. Metal-side savings that change no image:
the dynamic layer taps are skipped outside a CPU-computed box around the casters, and a static layer is only
redrawn when its whole-texel matrix changes. The depth array is sampled through a comparison sampler with linear
filtering (PCF) at the GL depth convention (`p.z * 0.5 + 0.5`), so the GL bias values carry over. Not ported: the layer
coverage dump of `r_om_csm_info <arg>` (debug only). World draws use a separate shader variant (`OM_CSM`,
buffer 7, texture 8) so frames without a sun pay nothing.

## Tests

`tools/build/tests/test-metal-world-parity.sh` checks the fixed 1728x1117 kos2 world patch,
excluding HUD/weapon/console; `test-metal-dlight-fixture.sh` checks the controlled light's
visible response. These bounded checks do not prove whole-frame or campaign parity. The full
build now exits0 after the source-scoped arm64 rounding repair: physics360/0 and Ghoul175/0.
Asset-dependent skips are retained as skips; they do not establish stock-model/shadow proof.
