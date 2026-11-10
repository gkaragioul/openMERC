// SPDX-License-Identifier: GPL-2.0-or-later
// Pure emission selection from material/pass provenance. No renderer globals.
// Implements: SPEC-AMEND-016 R16.7 and current GPL gl3_post.c/gl3_ghoulemu.c.
#ifndef OM_METAL_POST_MATH_H
#define OM_METAL_POST_MATH_H

typedef struct { float value[4]; } mtl_emission_t;
typedef struct {
	int enabled;
	float surface_scale, ghoul_min, fullbright_scale, fx_scale;
} mtl_post_emission_controls_t;
typedef struct { float emission[4]; } mtl_post_fragment_uniform_t;
#ifdef __cplusplus
static_assert(sizeof(mtl_post_fragment_uniform_t)==16,"OMPostUniforms is one MSL float4");
#else
_Static_assert(sizeof(mtl_post_fragment_uniform_t)==16,"OMPostUniforms is one MSL float4");
#endif

/* These are the GL3 effect blend IDs, not MTL_BLEND_DETAIL/DARKEN's private
 * factory values. Opaque0, alpha1, additive2, darken3, multiply4, double5. */
static mtl_emission_t
MTL_PostEmissionForBlend(int blend,float glow,const mtl_post_emission_controls_t *controls)
{
	mtl_emission_t out={{0,0,0,0}};
	if (!controls || !controls->enabled) return out;
	if (blend==2) {
		out.value[0]=glow>0?glow:controls->fx_scale;
		out.value[3]=1;
	} else if (blend==4 || blend==5) {
		out.value[0]=out.value[1]=out.value[2]=blend==5?.5f:1;
		out.value[3]=2;
	} else if (blend==3) {
		out.value[3]=2; // dst*(1-src): zero source leaves prior glow unchanged
	} else if (glow>0) {
		out.value[0]=glow;
		out.value[3]=1;
	}
	return out;
}

static float
MTL_PostSurfaceEmission(int flags,int value,const mtl_post_emission_controls_t *controls)
{
	if (!controls || !controls->enabled || !(flags&1)) return 0;
	float source=value/1000.f;
	if (source<.35f) source=.35f;
	if (source>1) source=1;
	return source*controls->surface_scale;
}

static float
MTL_PostEntityGlow(int fullbright_or_glow,int weapon,const mtl_post_emission_controls_t *controls)
{
	return controls && controls->enabled && fullbright_or_glow && !weapon?
		.35f*controls->fullbright_scale:0;
}

/* Ghoul's additive base after a hardware specular-map pass is not an FX
 * source. Do not infer sourcehood from additive blend or final brightness.
 * A real source may be below ghoul_min; retain its producer weight unchanged
 * in the ABI so a runtime threshold change does not require a model reload. */
static mtl_emission_t
MTL_PostGhoulEmission(int blend,float material_source,int specular_pass,float entity_glow,
	const mtl_post_emission_controls_t *controls)
{
	mtl_emission_t out={{0,0,0,0}};
	if (!controls || !controls->enabled) return out;
	float glow=0;
	if (!specular_pass) {
		if (material_source>=controls->ghoul_min) glow=material_source<1?material_source:1;
		if (entity_glow>glow) glow=entity_glow;
	}
	if (specular_pass || (blend==2 && glow<=0)) {
		out.value[3]=2; // additive specular is neutral; opaque specular occludes
		return out;
	}
	return MTL_PostEmissionForBlend(blend,glow,controls);
}

/* Current GPL CreateChain: use the physical view, not the full window. Both
 * dimensions must remain at least4. Recalculate the count when radius changes. */
static int
MTL_PostBloomLayout(int view_width,int view_height,float radius,int widths[7],int heights[7])
{
	int count=0,w=view_width/2,h=view_height/2;
	float desired=4+(radius>0?radius:0)+.5f;
	int want=desired>=7?7:desired<=2?2:(int)desired;
	for(int i=0;i<7;i++){widths[i]=heights[i]=0;}
	for(int i=0;i<want&&w>=4&&h>=4;i++,w/=2,h/=2){widths[i]=w;heights[i]=h;count++;}
	return count;
}

/* Applied to light after the color table, before the LDR render target. */
static float MTL_PostOverbright(int enabled,float scale,int nightvision)
{
	if(!enabled||nightvision)return 1;
	return scale<1?1:scale>4?4:scale;
}

/* Native 0..1 depth (Metal) eye distance for soft particles. mappedZ is the
 * native 0..1 depth after undoing the view's depth range. GL3 uses -1..1
 * NDC; Metal uses 0..1, so no *2-1 conversion is applied here. */
static float MTL_PostEyeDistance(float z,float C,float D,float depthMin,float depthMax)
{
	if(depthMin==depthMax)return INFINITY;
	float mapped=(z-depthMin)/(depthMax-depthMin);
	if(!isfinite(mapped))return INFINITY;
	return D/(mapped+C);
}

/* Soft particle fade mode: 0 disabled/ineligible, 1 alpha (normal blend),
 * 2 colour (additive/darken blends when additive control enabled). */
static int MTL_PostSoftMode(int blend,int billboard,int depthtest,int soft_enabled,int soft_add)
{
	if(!soft_enabled||!billboard||!depthtest)return 0;
	if(blend==1)return 1;
	if((blend==2||blend==3)&&soft_add)return 2;
	return 0;
}

typedef struct {
	float projection[4]; /* {C, D, depthMin, depthMax} */
	float view[4];       /* {1/windowW, 1/windowH, max(dist,1), mode} */
} mtl_soft_uniform_t;

static void MTL_PostSoftUniforms(int mode,float C,float D,float depthMin,float depthMax,
	int windowW,int windowH,float fadeDist,mtl_soft_uniform_t *out)
{
	if(!out)return;
	out->projection[0]=C;out->projection[1]=D;out->projection[2]=depthMin;out->projection[3]=depthMax;
	out->view[0]=windowW>0?1.0f/(float)windowW:0.0f;
	out->view[1]=windowH>0?1.0f/(float)windowH:0.0f;
	out->view[2]=fadeDist>1?fadeDist:1.0f;
	out->view[3]=(float)mode;
}

/* Distance fade: clamp((sceneEyeDist - particleEyeDist) / fadeDist, 0, 1). */
static float MTL_PostSoftFade(float sceneEyeDist,float particleEyeDist,float fadeDist)
{
	if(fadeDist<=0)fadeDist=1;
	float fade=(sceneEyeDist-particleEyeDist)/fadeDist;
	if(fade<0)fade=0;
	if(fade>1)fade=1;
	return fade;
}
#endif
