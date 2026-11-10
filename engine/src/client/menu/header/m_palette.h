/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs 2026-11-05 (play-tester: "Menu buttons look silly, dont feel like SOF. the entire menu buttons and colors"):
 * the menu's colours, taken from Soldier of Fortune's own HUD art (pics/interface2 frame_*): worn olive-green
 * metal, black inset slots, bright green LCD digits, a red indicator light, bone-white text.
 * Menu colours are 0xAABBGGRR; SOFC builds one from r, g, b, a.
 */
#ifndef M_PALETTE_H
#define M_PALETTE_H

#define SOFC(r, g, b, a) (((unsigned)(a) << 24) | ((unsigned)(b) << 16) | ((unsigned)(g) << 8) | (unsigned)(r))

/* owner, same day: "u can use the elements of the original main menu, but keep the simplified design" - the
   original ARC terminal menu (ghoul/menus): riveted olive and sand metal plates, aqua-cyan highlights */
#define SOF_LCD        SOFC(72, 236, 226, 255)  /* the original menu's cyan: hover, current, accents */
#define SOF_LCD_DIM    SOFC(40, 150, 146, 255)
#define SOF_SAND       SOFC(204, 188, 132, 255) /* headings, like the ARC nameplate */
#define SOF_BONE       SOFC(220, 214, 192, 255) /* text */
#define SOF_OLIVE_HI   SOFC(140, 150, 104, 255) /* metal highlight */
#define SOF_OLIVE_TOP  SOFC(92, 104, 62, 255)   /* metal, top of a gradient */
#define SOF_OLIVE_BOT  SOFC(42, 52, 28, 255)    /* metal, bottom */
#define SOF_OLIVE_EDGE SOFC(78, 88, 54, 255)    /* panel borders */
#define SOF_DARK_EDGE  SOFC(14, 17, 10, 255)
#define SOF_SLOT       SOFC(6, 8, 5, 255)       /* black inset slot */
#define SOF_LED_ON     SOFC(255, 64, 40, 255)
#define SOF_LED_OFF    SOFC(112, 26, 18, 255)

#endif
