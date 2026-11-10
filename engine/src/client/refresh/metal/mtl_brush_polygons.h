// SPDX-License-Identifier: GPL-2.0-or-later
// Count submitted brush faces once, independently of traversal and draw passes.
// Implements: SPEC-AMEND-006 I4c.4; SPEC-412 warning overlay brush count.
#ifndef OM_METAL_BRUSH_POLYGONS_H
#define OM_METAL_BRUSH_POLYGONS_H
#include <limits.h>
static int mtl_brush_polygons;
static void MTL_BrushPolygonDrawn(void)
{
 if(mtl_brush_polygons<INT_MAX)mtl_brush_polygons++;
}
#endif
