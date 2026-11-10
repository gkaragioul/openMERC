#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Native Metal must pass the same Ghoul lighting-method controls as GL3.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$root/engine/src/client/refresh/metal/mtl_main.m"
draw_body=$(sed -n '/MTL_DrawGhoulEntity(entity_t \*e,/,/^}/p' "$source_file")
ghoul_draw="$root/engine/src/ghoul/ghoul_draw.cpp"
native_body=$(sed -n '/DrawOwnNative(Inst \*in,/,/^}/p' "$ghoul_draw")
bridge="$root/engine/src/ghoul/ghoul_host.h"

for required in \
  'ghl_light_method' \
  'ghl_light_multiply' \
  'params.use_gl_lights' \
  'params.specular' \
  'RF_MINLIGHT'; do
	if ! grep -Fq "$required" <<<"$draw_body" && ! grep -Fq "$required" "$source_file"; then
		printf 'FAIL: native Metal Ghoul lighting is missing %s\n' "$required" >&2
		exit 1
	fi
done

if ! grep -Fq 'LightVertex(pos, nrm, ambient, lights' <<<"$native_body"; then
	echo 'FAIL: native Ghoul sink bypasses the shared per-vertex light calculation' >&2
	exit 1
fi

for required in 'specVertices' 'swSpecTex' 'OM_GHOUL_NATIVE_BLEND_ADDITIVE'; do
	if ! grep -Fq "$required" <<<"$native_body"; then
		printf 'FAIL: native Ghoul sink does not export the shared specular pass (%s)\n' "$required" >&2
		exit 1
	fi
done

for required in 'OMGhoul_ClearLights' 'OMGhoul_AddDynamicLight'; do
	if ! grep -Fq "$required" "$bridge" || ! grep -Fq "$required" "$source_file"; then
		printf 'FAIL: native Metal does not import frame Ghoul light records via %s\n' "$required" >&2
		exit 1
	fi
done

for required in 'OMGhoul_BeginWorldLights' 'OMGhoul_AddWorldLight' 'OMGhoul_FinishWorldLights'; do
	if ! grep -Fq "$required" "$bridge" || ! grep -Fq "$required" "$source_file"; then
		printf 'FAIL: native Metal does not register BSP model lights via %s\n' "$required" >&2
		exit 1
	fi
done

if ! grep -Fq 'OMGhoul_SetGamma' "$bridge" || ! grep -Fq 'OMGhoul_SetGamma' "$source_file"; then
	echo 'FAIL: native Metal does not hand its colour-correction table to Ghoul' >&2
	exit 1
fi

for required in 'OMGhoul_SetTextureDetail' 'ghl_mip' 'nomip' 'MTLSamplerMipFilterNearest'; do
	if ! grep -Fq "$required" "$bridge" && ! grep -Fq "$required" "$source_file" && ! grep -Fq "$required" "$ghoul_draw"; then
		printf 'FAIL: native Metal does not preserve Ghoul texture sampling state (%s)\n' "$required" >&2
		exit 1
	fi
done

for required in 'MTL_NewGhoulTextureChain' 'MTL_GhoulDownsample' 'MTL_NewGhoulTextureChain(draw->texture->rgba'; do
	if ! grep -Fq "$required" "$source_file"; then
		printf 'FAIL: native Metal does not upload the Ghoul CPU mip chain (%s)\n' "$required" >&2
		exit 1
	fi
done

if ! grep -Fq 'LUMP_LIGHTS' "$source_file"; then
	echo 'FAIL: native Metal does not load the BSP model-light lump' >&2
	exit 1
fi

for required in 'native_light_count' 'native_ambient'; do
	if ! grep -Fq "$required" "$bridge" || ! grep -Fq "$required" "$source_file"; then
		printf 'FAIL: native Ghoul lighting diagnostics are missing %s\n' "$required" >&2
		exit 1
	fi
done

for required in 'params.hardware_lights' 'ghl_gllight_attenuation' 'ghl_gllight_max_lights'; do
	if ! grep -Fq "$required" "$source_file"; then
		printf 'FAIL: native Metal does not forward GL3 hardware-light state (%s)\n' "$required" >&2
		exit 1
	fi
done

for required in 'HardwareLightVertex' 'G().gs.lightAmbient'; do
	if ! grep -Fq "$required" "$ghoul_draw"; then
		printf 'FAIL: native Ghoul does not emulate the GL hardware-light base pass (%s)\n' "$required" >&2
		exit 1
	fi
done

if ! grep -Fq 'P->hardwareLights' <<<"$native_body"; then
	echo 'FAIL: native Ghoul does not select the hardware-light base pass' >&2
	exit 1
fi

for required in 'native_hardware_lights' 'native_gl_attenuation' 'native_first_light'; do
	if ! grep -Fq "$required" "$bridge" || ! grep -Fq "$required" "$source_file"; then
		printf 'FAIL: native Ghoul hardware-light diagnostic is missing %s\n' "$required" >&2
		exit 1
	fi
done

echo 'PASS: native Metal Ghoul lighting controls are present'
