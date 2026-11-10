// SPDX-License-Identifier: GPL-2.0-or-later
// Native Metal effect pass. Implements: SPEC-002, SPEC-412 sections 8–10.
#include "mtl_fx_geometry.h"

typedef struct { char name[MAX_QPATH]; mtl_image_t *image; } mtl_fx_image_t;
static mtl_fx_image_t mtl_fx_images[SOF_MAX_IMAGES];
static int mtl_fx_numimages;

static mtl_image_t *MTL_FXImage(const char *name)
{
	if (!name || !*name) return mtl_notexture;
	for (int i=0;i<mtl_fx_numimages;i++)
		if (!strcmp(name,mtl_fx_images[i].name)) return mtl_fx_images[i].image;
	if (strlen(name)>=MAX_QPATH || mtl_fx_numimages==SOF_MAX_IMAGES) return mtl_notexture;
	char path[MAX_QPATH];
	Com_sprintf(path,sizeof(path),"%s%s",name,*COM_FileExtension(name)?"":".m32");
	mtl_image_t *image=(mtl_image_t *)MTL_FindImage(path,it_sprite);
	mtl_fx_image_t *entry=&mtl_fx_images[mtl_fx_numimages++];
	Q_strlcpy(entry->name,name,sizeof(entry->name));
	entry->image=image?image:mtl_notexture;
	return entry->image;
}
static void *MTL_FXRegisterSprite(char *name) { return MTL_FXImage(name); }
static void MTL_FXLightPoint(float *point,float *colour,int direction)
{
	MTL_SoFLightPointDir(point,colour,direction);
}
static void MTL_FXShutdown(void)
{
	for (int i=0;i<mtl_fx_numimages;i++) {
		mtl_image_t *image=mtl_fx_images[i].image;
		if (image && image!=mtl_notexture) { if(image->tex) CFRelease(image->tex); free(image); }
	}
	memset(mtl_fx_images,0,sizeof(mtl_fx_images)); mtl_fx_numimages=0;
}
static int MTL_FXBlend(unsigned flags)
{
	return (flags&SOF_AQ_DARKEN)?3:((flags&SOF_AQ_ADDITIVE)?2:1);
}
static mtl_image_t *MTL_FXQuadImage(sofalphaquad_t *q)
{
	if (!q->image) q->image=MTL_FXImage(q->texname);
	return (mtl_image_t *)q->image;
}

/* SPEC-412: the quad that decides the fog (a chain's first quad); its region is cached in the quad */
static sofalphaquad_t *mtl_fx_fog_source;
static int MTL_FXFogRegion(sofalphaquad_t *q)
{
	if(q->fogcache<0){int region=MTL_FogRegionOfPoint(q->origin);q->fogcache=region>=0?region+1:0;}
	return q->fogcache-1;
}
static void MTL_FXDrawGeometry(const sofalphaquad_t *q,mtl_image_t *image,const float colour[4],
	int blend,int batched,int nodepth,int decal,const float mvp[16],const float right[3],const float up[3])
{
	mtl_fx_vertex_t corners[4];
	int count=MTL_FXGeometry(q,mtl_refdef.vieworg,right,up,batched,corners);
	if (!count || !image || !image->tex || !mtl_encoder_open) return;
	static const int indices[6]={0,1,2,0,2,3};
	int vertices=count==3?3:6;
	mtl_alias_vertex_t v[6]={0};
	for (int i=0;i<vertices;i++) {
		const mtl_fx_vertex_t *p=&corners[indices[i]];
		memcpy(v[i].pos,p->position,sizeof(v[i].pos)); memcpy(v[i].uv,p->uv,sizeof(v[i].uv));
		memcpy(v[i].color,colour,sizeof(v[i].color));
	}
	float cutoff=blend==1?0.05f:-1.0f;
	[mtl_enc setRenderPipelineState:MTL_BuildAliasPipeline(blend==3?MTL_BLEND_DARKEN:blend,2)];
	mtl_post_emission_controls_t emission_controls=MTL_PostEmissionControls();
	MTL_PostBindEmission(MTL_PostEmissionForBlend(blend,0,&emission_controls),3);
	[mtl_enc setDepthStencilState:nodepth?mtl_depth_2d:mtl_depth_readonly];
	[mtl_enc setCullMode:MTLCullModeNone];
	[mtl_enc setDepthBias:decal?mtl_offset_units_cvar->value:0 slopeScale:decal?mtl_offset_factor_cvar->value:0 clamp:0];
	[mtl_enc setVertexBytes:v length:(NSUInteger)vertices*MTL_ALIAS_STRIDE atIndex:0];
	[mtl_enc setVertexBytes:mvp length:16*sizeof(float) atIndex:1];
	[mtl_enc setFragmentBytes:&cutoff length:sizeof(cutoff) atIndex:2];
	[mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)image->tex atIndex:0];
	[mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];
	/* Soft particles: bind opaque depth and uniforms when post is active. */
	{
		id<MTLTexture> softDepth = MTL_PostOpaqueDepth();
		if (softDepth) {
			[mtl_enc setFragmentTexture:softDepth atIndex:1];
			[mtl_enc setFragmentSamplerState:mtl_framepost_nearest atIndex:1];
			float softP[4] = { mtl_post.projection[10], mtl_post.projection[14],
				mtl_post.depth_min, mtl_post.depth_max };
			/* RLabs (2026-11-05): the GL reference's rule (GL3_Post_SoftMode): only depth-tested camera-facing
			 * puffs fade where they meet the world - alpha-blended ones by alpha (mode 1), additive and darken
			 * ones by colour (mode 2, r_om_softparticles_add). Floor marks (SOF_AQ_DECAL) and oriented quads lie
			 * on a surface by design; fading them made every scorch and blood mark invisible in Metal. */
			int soft = 0;
			if (mtl_framepost_soft && mtl_framepost_soft->value != 0 && !nodepth &&
				(q->flags & SOF_AQ_BILLBOARD) && !(q->flags & (SOF_AQ_ORIENTED | SOF_AQ_DECAL))) {
				if (blend == 1) soft = 1;
				else if ((blend == 2 || blend == 3) &&
					ri.Cvar_Get("r_om_softparticles_add", "1", CVAR_ARCHIVE)->value) soft = 2;
			}
			float dist = ri.Cvar_Get("r_om_softparticles_dist", "12", CVAR_ARCHIVE)->value;
			float softV[4] = { 1.0f / (float)mtl_post.width, 1.0f / (float)mtl_post.height,
				soft ? (dist < 1.0f ? 1.0f : dist) : 0.0f, (float)soft };
			[mtl_enc setFragmentBytes:softP length:sizeof(softP) atIndex:4];
			[mtl_enc setFragmentBytes:softV length:sizeof(softV) atIndex:5];
		} else {
			/* Bind dummy values when no depth snapshot available. */
			float softP[4] = { 0, 0, 0, 1 };
			float softV[4] = { 1.0f, 1.0f, 0, 0 };
			[mtl_enc setFragmentBytes:softP length:sizeof(softP) atIndex:4];
			[mtl_enc setFragmentBytes:softV length:sizeof(softV) atIndex:5];
		}
	}
	if(mtl_fx_fog_source&&mtl_fogdraw.world)MTL_FogBindEffect(MTL_FXFogRegion(mtl_fx_fog_source),blend,mtl_fx_fog_source->origin);
	else MTL_FogBindNone();
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices];
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
}
static void MTL_FXDrawQuad(sofalphaquad_t *q,const float mvp[16],const float right[3],const float up[3])
{
	float light[3]={1,1,1},colour[4];
	if(q->flags&SOF_AQ_LIT) MTL_SoFLightPointDir(q->origin,light,q->lightdir);
	MTL_FXColor(q,light,(q->flags&SOF_AQ_LIT)!=0,colour);
	mtl_fx_fog_source=q;
	MTL_FXDrawGeometry(q,MTL_FXQuadImage(q),colour,MTL_FXBlend(q->flags),0,0,
		(q->flags&SOF_AQ_DECAL)!=0,mvp,right,up);
}
static void MTL_FXDrop(sofalphaquad_t *q)
{
	q->flags|=SOF_AQ_HIDDEN; q->v0c[0]=q->v0c[1]=q->f18=0;
}
static void MTL_FXDrawChain(sofquadchain_t *chain,float total,const float mvp[16],const float right[3],const float up[3])
{
	sofalphaquad_t *first=chain->first;
	if(!first) return;
	if(!mtl_nocull_cvar->value && R_CullBox(chain->mins,chain->maxs,mtl_frustum)) return;
	/* Bound list traversal to the engine's declared count, including LOD walks. */
	int count=Q_max(0,Q_min(chain->count,32768)),drop=0;
	float fill=ri.Cvar_Get("gl_effectfill","100",0)->value;
	if(total>fill && total>0) {
		drop=Q_max(0,Q_min((int)((1-fill/total)*count),count));
		if(count==1) {
			if((float)rand()/((float)RAND_MAX+1.0f)<1-fill/total) { first->flags|=SOF_AQ_HIDDEN; return; }
			drop=0;
		} else {
			for(int pass=0;pass<2 && drop>0;pass++) {
				sofalphaquad_t *q=first;
				for(int i=0;q && i<count && drop>0;i++,q=q->next)
					if((i&1)==pass && !(q->flags&(SOF_AQ_DRAWN|SOF_AQ_HIDDEN))) { MTL_FXDrop(q); drop--; }
			}
		}
	}
	float light[3]={1,1,1};
	if(first->flags&SOF_AQ_LIT) {
		float p[3]={(chain->mins[0]+chain->maxs[0])*0.5f,(chain->mins[1]+chain->maxs[1])*0.5f,chain->maxs[2]};
		MTL_SoFLightPointDir(p,light,first->lightdir);
	}
	mtl_image_t *image=MTL_FXQuadImage(first);
	int blend=MTL_FXBlend(first->flags), batched=(first->flags&SOF_AQ_BATCHED)!=0,prevdrawn=0;
	mtl_fx_fog_source=first;
	sofalphaquad_t *q=first;
	for(int i=0;q && i<count;i++,q=q->next) {
		if(drop>0 && prevdrawn && !(q->flags&SOF_AQ_DRAWN)) { MTL_FXDrop(q); drop--; prevdrawn=0; continue; }
		float colour[4];
		const sofalphaquad_t *source=batched?first:q;
		MTL_FXColor(source,light,(source->flags&SOF_AQ_LIT)!=0,colour);
		sofalphaquad_t geometry=*q;
		geometry.flags &= ~(SOF_AQ_BILLBOARD|SOF_AQ_BEAM);
		geometry.flags |= (first->flags&SOF_AQ_BILLBOARD)?SOF_AQ_BILLBOARD:SOF_AQ_BEAM;
		MTL_FXDrawGeometry(&geometry,image,colour,blend,batched,(first->flags&SOF_AQ_NODEPTH)!=0,0,mvp,right,up);
		q->flags|=SOF_AQ_DRAWN; prevdrawn=1;
	}
}

typedef struct { float key; int kind; void *object; } mtl_scene_item_t;
static int MTL_FXCompare(const void *a,const void *b)
{
	float x=((const mtl_scene_item_t *)a)->key,y=((const mtl_scene_item_t *)b)->key;
	return x<y?1:(x>y?-1:0);
}
static float MTL_FXDistance(const float point[3])
{
	float d[3]; VectorSubtract(point,mtl_refdef.vieworg,d); return DotProduct(d,d);
}
static int MTL_FXLeafVisible(const sofalphaquad_t *q)
{
	if(q->leaf<0 || !mtl_worldmodel) return 1;
	if(q->leaf>=mtl_worldmodel->numleafs) return 0;
	mleaf_t *leaf=&mtl_worldmodel->leafs[q->leaf];
	if(leaf->visframe!=mtl_visframecount) return 0;
	return mtl_nocull_cvar->value || !R_CullBox(leaf->minmaxs,leaf->minmaxs+3,mtl_frustum);
}
static void MTL_DrawScene(const float mvp[16],const float view[16],const float right[3],const float up[3])
{
	mtl_scene_item_t items[SOF_MAX_ENTITIES+SOF_MAX_ALPHAQUADS+SOF_MAX_QUADCHAINS+MTL_MAX_ALPHA_SURFACES];
	int count=0; float total=0;
	if(mtl_sof_frame) {
		int n=mtl_sof_frame->alphaquads?Q_min(mtl_sof_frame->num_alphaquads,SOF_MAX_ALPHAQUADS):0;
		for(int i=0;i<n;i++) {
			sofalphaquad_t *q=mtl_sof_frame->alphaquads[i];
			if(!q || !MTL_FXLeafVisible(q)) continue;
			if(q->flags&SOF_AQ_IMMEDIATE) MTL_FXDrawQuad(q,mvp,right,up);
			else items[count++]=(mtl_scene_item_t){MTL_FXDistance(q->origin),1,q};
		}
		n=mtl_sof_frame->quadchains?Q_min(mtl_sof_frame->num_quadchains,SOF_MAX_QUADCHAINS):0;
		for(int i=0;i<n;i++) {
			sofquadchain_t *chain=mtl_sof_frame->quadchains[i];
			if(!chain || !chain->first) continue;
			float key=0;
			if(chain->first->flags&SOF_AQ_NODEPTH) key=mtl_nearclip_cvar->value*mtl_nearclip_cvar->value;
			else for(int k=0;k<3;k++) {
				float a=chain->mins[k]-mtl_refdef.vieworg[k],b=chain->maxs[k]-mtl_refdef.vieworg[k];
				float d=fabsf(a)<fabsf(b)?a:b; key+=d*d;
			}
			if(key>0) chain->weight/=sqrtf(key);
			total+=chain->weight;
			items[count++]=(mtl_scene_item_t){key,2,chain};
		}
	}
	for(int i=0;i<mtl_alpha_count;i++)
		items[count++]=(mtl_scene_item_t){MTL_AlphaSortKey(mtl_alpha_surfaces[i]),3,mtl_alpha_surfaces[i]};
	if(mtl_refdef.entities && ri.Cvar_Get("r_drawentities","1",0)->value) {
		for(int i=0;i<Q_min(mtl_refdef.num_entities,SOF_MAX_ENTITIES);i++) {
			entity_t *e=&mtl_refdef.entities[i];
			float key=(e->flags&RF_WEAPONMODEL)?0:MTL_FXDistance(e->origin);
			if (!(e->flags&(RF_WEAPONMODEL|SOF_RF_GHOUL)) && e->model &&
				((mtl_model_t *)e->model)->type==mod_brush) key=MTL_BrushSortKey(e);
			items[count++]=(mtl_scene_item_t){key,0,e};
		}
	}
	qsort(items,count,sizeof(items[0]),MTL_FXCompare);
	for(int i=0;i<count;i++) {
		if(items[i].kind==0) MTL_DrawEntity((entity_t *)items[i].object,mvp,view);
		else if(items[i].kind==1) MTL_FXDrawQuad((sofalphaquad_t *)items[i].object,mvp,right,up);
		else if(items[i].kind==2) MTL_FXDrawChain((sofquadchain_t *)items[i].object,total,mvp,right,up);
		else MTL_DrawAlphaSurface((mtl_surface_t *)items[i].object,mvp);
	}
}
