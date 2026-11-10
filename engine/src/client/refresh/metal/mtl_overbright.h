// SPDX-License-Identifier: GPL-2.0-or-later
// Optional current-GPL overbright. World/alias share the view control;
// the models toggle gates Ghoul drawing light after its unscaled report.
// Implements: SPEC-AMEND-016 optional controls, SPEC-410 and SPEC-411 lighting.
#ifndef OM_METAL_OVERBRIGHT_H
#define OM_METAL_OVERBRIGHT_H
static cvar_t *mtl_overbright,*mtl_overbright_scale,*mtl_overbright_models;
static void MTL_OverbrightInit(void)
{
 mtl_overbright=ri.Cvar_Get("r_om_overbright","0",CVAR_ARCHIVE);
 mtl_overbright_scale=ri.Cvar_Get("r_om_overbright_scale","2",CVAR_ARCHIVE);
 mtl_overbright_models=ri.Cvar_Get("r_om_overbright_models","1",CVAR_ARCHIVE);
}
static float MTL_Overbright(void)
{
 if(!mtl_overbright||!mtl_overbright->value||(mtl_refdef.rdflags&RDF_IRGOGGLES))return 1.0f;
 float scale=mtl_overbright_scale->value;
 return scale<1.0f?1.0f:scale>4.0f?4.0f:scale;
}
static float MTL_OverbrightModels(void)
{
 return mtl_overbright_models&&mtl_overbright_models->value?MTL_Overbright():1.0f;
}
#endif
