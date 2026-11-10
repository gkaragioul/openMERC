/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit: the in-game Performance HUD setting (design decision 2026-11-05). Apple's Metal Performance HUD can be
 * switched per layer only when the process started with MTL_HUD_ENABLED=1 (the app launcher sets it); its overlay
 * then follows CAMetalLayer.developerHUDProperties: mode "default" (shown) or "disabled" (hidden, the default).
 *
 * This version was written on 2026-11-08 for the Soldier of Fortune port; it keeps the earlier kit's
 * behaviour and log lines.
 */
#ifndef RLK_HUD_H
#define RLK_HUD_H

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when the process was started with MTL_HUD_ENABLED=1 (the HUD can be switched; show the setting) */
int rlk_hud_available(void);

/* show or hide the HUD on `metal_layer` (a CAMetalLayer *); nothing when the HUD is not available */
void rlk_hud_set(void *metal_layer, int on);

#ifdef __cplusplus
}
#endif

#endif
