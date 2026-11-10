// SPDX-License-Identifier: GPL-2.0-or-later
// Damaged world textures: renderer slot 0xa8. Implements: SPEC-002 (slot 0xa8), SPEC-410 "Damaged surfaces".
// World faces take their image from the texinfo at draw time, so changing the texinfo is all a frame needs.
// Include after mtl_worldmodel and before MTL_RemoveModel / MTL_BeginRegistration.

/* Each change is journalled: the server starts every map load with undamaged surfaces (SPEC-AMEND-005 G18.23), also
   when the world model is kept because the same map is loaded again with flushmap 0 */
typedef struct
{
	mtexinfo_t *tex;
	struct image_s *image;
	mtexinfo_t *next;
	int numframes;
} mtl_damage_undo_t;

static mtl_damage_undo_t *mtl_damage_undo;
static int mtl_damage_undo_count;

static void
MTL_DamageForget(void)
{
	free(mtl_damage_undo);
	mtl_damage_undo = NULL;
	mtl_damage_undo_count = 0;
}

static void
MTL_DamageRestore(void)
{
	/* newest first: a texinfo damaged twice ends at its original state */
	for (int i = mtl_damage_undo_count - 1; i >= 0; i--)
	{
		mtl_damage_undo[i].tex->image = mtl_damage_undo[i].image;
		mtl_damage_undo[i].tex->next = mtl_damage_undo[i].next;
		mtl_damage_undo[i].tex->numframes = mtl_damage_undo[i].numframes;
	}
	MTL_DamageForget();
}

/* the texinfo shows its image's damaged variant and stops animating (the short travels in a 4-byte slot) */
static void
MTL_SoF_DamageTexture(int texinfo, int unused)
{
	short index = (short)(texinfo & 0xFFFF);
	(void)unused;

	if (!mtl_worldmodel || index < 0 || index >= mtl_worldmodel->numtexinfo)
		return;

	mtexinfo_t *tex = &mtl_worldmodel->texinfo[index];
	mtl_image_t *image = (mtl_image_t *)tex->image;

	if (!image || !image->damage)
		return;

	mtl_damage_undo_t *undo = realloc(mtl_damage_undo, (size_t)(mtl_damage_undo_count + 1) * sizeof(*undo));
	if (undo)
	{
		mtl_damage_undo = undo;
		mtl_damage_undo[mtl_damage_undo_count++] = (mtl_damage_undo_t){tex, tex->image, tex->next, tex->numframes};
	}

	tex->image = (struct image_s *)image->damage;
	tex->next = NULL;
	tex->numframes = 1;
}
