// SPDX-License-Identifier: GPL-2.0-or-later
// Production draw-boundary counter checks, with real native vertex buffers.
// Implements: SPEC-AMEND-006 I4c.4; SPEC-412 warning overlay brush-face count.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../../../../common/header/common.h"
#include "../../ref_shared.h"
#include "../../../../ghoul/ghoul_host.h"
#include "../mtl_post_math.h"
#include "../mtl_brush_math.h"
#include "../mtl_lightmap_math.h"
#define MTL_MAX_DLIGHTS 32
#define MTL_MAX_ALPHA_SURFACES 4096
#define DEG2RAD(x) ((x)*0.017453292519943295f)
#include "brush_polygon_types.h"
#if BRUSH_POLYGONS_OLD
static int mtl_brush_polygons;
#else
#include "../mtl_brush_polygons.h"
#endif
static id<MTLDevice> mtl_device;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLTexture> mtl_lighttable;
static id<MTLDepthStencilState> mtl_depth_world,mtl_depth_readonly;
static id<MTLSamplerState> mtl_samp_world,mtl_samp_lm,mtl_samp_clamp,mtl_samp_repeat;
static mtl_model_t *mtl_worldmodel;
static mtl_surface_t *mtl_alpha_surfaces[MTL_MAX_ALPHA_SURFACES],*mtl_detail_surfaces[1024];
static int mtl_alpha_count,mtl_detail_count,mtl_pdlight_active_count,mtl_monolightmap_mode;
static int mtl_encoder_open=1,mtl_framecount=1;
static refdef_t mtl_refdef;
static cplane_t mtl_frustum[4];
static cvar_t zero={0},one={.value=1},farclip={.value=4096},detail={0};
static cvar_t *mtl_detail_cvar=&detail,*mtl_fullbright_cvar=&zero,*mtl_pdlight_cvar=&zero,*mtl_pdlight_scale_cvar=&one,*mtl_pdlight_normal_cvar=&zero,*mtl_pdlight_soft_cvar=&zero,*mtl_gl_dynamic_cvar=&one,*mtl_cull_cvar=&zero,*mtl_drawflat_cvar=&zero,*mtl_nocull_cvar=&zero,*mtl_farclip_cvar=&farclip;
static float mtl_modulate_latched=1;
static int submissions,liquid_draws,liquid_success=1,lightmap_success=1,turb_success=1,cull;
static int checks,failures;
static void check(int yes,const char *name){checks++;if(!yes){failures++;fprintf(stderr,"FAIL %s (counter%d submissions%d liquids%d)\n",name,mtl_brush_polygons,submissions,liquid_draws);}}
static float MTL_GameTime(void){return 0;}
static float MTL_Overbright(void){return 1;}
static mtl_post_emission_controls_t MTL_PostEmissionControls(void){return (mtl_post_emission_controls_t){0};}
static id<MTLRenderPipelineState> MTL_BuildWorldPipeline(void){return nil;}
static id<MTLRenderPipelineState> MTL_BuildAliasPipeline(int blend,int fragment){(void)blend;(void)fragment;return nil;}
static id<MTLRenderPipelineState> MTL_BuildTurbPipeline(int alpha){(void)alpha;return turb_success?(id<MTLRenderPipelineState>)[NSObject new]:nil;}
static void MTL_PostBindEmission(mtl_emission_t emission,NSUInteger index){(void)emission;(void)index;}
static void MTL_AddSkySurface(mtl_surface_t *s){(void)s;}
static void MTL_SoFLightPoint(const vec3_t p,vec3_t c){(void)p;VectorSet(c,1,1,1);}
static void MTL_SoFLightPointDir(const vec3_t p,vec3_t c,int direction){(void)p;(void)direction;VectorSet(c,1,1,1);}
static float MTL_SoFLiquidSortKey(const mtl_model_t *m,const mtl_surface_t *s,const vec3_t eye,float best){(void)m;(void)s;(void)eye;return best;}
static id<MTLTexture> MTL_LightmapMakeDynamic(struct mtl_lightmap_s *l,unsigned bits,const dlight_t *d,int n,int dynamic,int pdl){(void)l;(void)bits;(void)d;(void)n;(void)dynamic;(void)pdl;return nil;}
static int MTL_LightmapBind(struct mtl_lightmap_s *l,const lightstyle_t *styles,int dynamic,float modulate,int mono,id<MTLTexture> tex){(void)l;(void)styles;(void)dynamic;(void)modulate;(void)mono;(void)tex;return lightmap_success;}
static int MTL_DrawSoFLiquid(const mtl_model_t *m,const mtl_surface_t *s,const mtl_image_t *i,const float *vp,const float *matrix,const float *normal,int alpha,int material_cull,int flat){(void)m;(void)s;(void)i;(void)vp;(void)matrix;(void)normal;(void)alpha;(void)material_cull;(void)flat;liquid_draws++;return liquid_success;}
static int MTL_DrawSoFLiquidInlineAlpha(const mtl_model_t *m,const mtl_surface_t *s,const mtl_image_t *i,const float *vp,const float *matrix,const float *light){(void)m;(void)s;(void)i;(void)vp;(void)matrix;(void)light;liquid_draws++;return liquid_success;}
static void MTL_LiquidEntityMatrix(const vec3_t origin,const vec3_t angles,float out[16]){(void)angles;memset(out,0,16*sizeof(float));for(int i=0;i<4;i++)out[5*i]=1;memcpy(out+12,origin,3*sizeof(float));}
static void MTL_DrawDetailPass(mtl_model_t *m,const float *vp){(void)m;(void)vp;}
void R_MarkLights(dlight_t *light,int bit,mnode_t *node,int frame,marksurfacelights_t mark){(void)light;(void)bit;(void)node;(void)frame;(void)mark;}
qboolean R_CullBox(vec3_t mins,vec3_t maxs,cplane_t *frustum){(void)mins;(void)maxs;(void)frustum;return cull;}
void AngleVectors(const vec3_t a,vec3_t f,vec3_t r,vec3_t u){(void)a;VectorSet(f,1,0,0);VectorSet(r,0,-1,0);VectorSet(u,0,0,1);}
@interface PolygonEncoder : NSObject
@end
@implementation PolygonEncoder
-(void)setRenderPipelineState:(id)p{(void)p;}
-(void)setDepthStencilState:(id)p{(void)p;}
-(void)setCullMode:(MTLCullMode)c{(void)c;}
-(void)setFrontFacingWinding:(MTLWinding)w{(void)w;}
-(void)setDepthBias:(float)a slopeScale:(float)b clamp:(float)c{(void)a;(void)b;(void)c;}
-(void)setVertexBuffer:(id)b offset:(NSUInteger)o atIndex:(NSUInteger)i{(void)b;(void)o;(void)i;}
-(void)setVertexBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i{(void)b;(void)n;(void)i;}
-(void)setFragmentBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i{(void)b;(void)n;(void)i;}
-(void)setFragmentTexture:(id)t atIndex:(NSUInteger)i{(void)t;(void)i;}
-(void)setFragmentSamplerState:(id)s atIndex:(NSUInteger)i{(void)s;(void)i;}
-(void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n{(void)t;(void)s;if(n>=3)submissions++;}
@end
static mtl_image_t *MTL_AnimatedWorldImage(const mtexinfo_t *,int);
#include "brush_polygon_functions.h"
static void reset(void){mtl_brush_polygons=submissions=liquid_draws=mtl_alpha_count=mtl_detail_count=0;}
int main(void){@autoreleasepool{
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 77;mtl_enc=(id<MTLRenderCommandEncoder>)[PolygonEncoder new];
 NSObject *dummy=[NSObject new];mtl_image_t image={0};image.tex=(__bridge void *)dummy;image.width=image.height=64;
 mtexinfo_t tex[4]={0};mtl_surface_t surfaces[4]={0};mtl_world_vertex_t vertices[24]={0};
 for(int i=0;i<4;i++){tex[i].image=(struct image_s *)&image;tex[i].vecs[0][0]=tex[i].vecs[1][1]=1;surfaces[i].texinfo=&tex[i];surfaces[i].normal[2]=1;surfaces[i].num_vertex=6;surfaces[i].first_vertex=6*i;surfaces[i].lighting=(struct mtl_lightmap_s *)1;}
 id<MTLBuffer> buffer=[mtl_device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared];
 mtl_model_t world={0};world.surfaces=surfaces;world.numsurfaces=world.nummodelsurfaces=4;world.vbuf=(__bridge void *)buffer;world.vbuf_vertices=24;world.bspversion=BSPVERSION_SOF;world.owner=&world;world.type=mod_brush;mtl_worldmodel=&world;mtl_refdef.vieworg[2]=10;float vp[16]={0};
 reset();MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==1&&submissions==1,"opaque world counts one face for two triangles");
 reset();tex[0].flags=SURF_DRAWSKY;surfaces[0].skyring_n=3;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==0&&submissions==0,"sky bounds are not brush polygons");tex[0].flags=0;
 reset();image.tex=NULL;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==0,"missing world texture is not a submitted polygon");image.tex=(__bridge void *)dummy;
 reset();image.declared_m32_flags=0x800;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==0,"hidden declared-alpha world candidate is not a polygon");image.declared_m32_flags=0;
 reset();surfaces[0].lighting=NULL;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==0,"unrenderable missing-lightmap candidate is not a polygon");surfaces[0].lighting=(struct mtl_lightmap_s *)1;
 reset();lightmap_success=0;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==0&&submissions==0,"failed lightmap binding does not advance actual draw count");lightmap_success=1;
 reset();tex[0].flags=0x800;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==0&&mtl_alpha_count==1,"queued world alpha waits for its actual draw");MTL_DrawAlphaSurface(&surfaces[0],vp);check(mtl_brush_polygons==1&&submissions==1,"direct world alpha counts one face");
 reset();tex[0].flags=8;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==1&&liquid_draws==1,"opaque world liquid counts once across its material passes");
 reset();tex[0].flags=0x808;MTL_DrawSurface(&world,0,vp);MTL_DrawAlphaSurface(&surfaces[0],vp);check(mtl_brush_polygons==1&&liquid_draws==1,"queued/direct world liquid alpha is counted only once");
 reset();liquid_success=0;MTL_DrawAlphaSurface(&surfaces[0],vp);check(mtl_brush_polygons==0,"failed liquid adapter does not advance count");liquid_success=1;
 reset();tex[0].flags=SURF_DRAWTURB;world.bspversion=38;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==1&&submissions==1,"generic turbulent surface counts actual submission");
 reset();turb_success=0;MTL_DrawSurface(&world,0,vp);check(mtl_brush_polygons==0&&submissions==0,"failed turbulent pipeline does not count");turb_success=1;world.bspversion=BSPVERSION_SOF;tex[0].flags=0;
 reset();image.detail=&image;detail.value=1;MTL_DrawSurface(&world,0,vp);MTL_DrawDetailPass(&world,vp);check(mtl_brush_polygons==1&&mtl_detail_count==1,"detail material never double-counts the primary face");image.detail=NULL;detail.value=0;
 mtl_model_t model=world;model.owner=&world;tex[0].flags=0;tex[1].flags=8;tex[2].flags=0x800;tex[3].flags=0x808;
 entity_t ent={0};ent.model=(struct model_s *)&model;
 reset();MTL_DrawBrushModel(&ent,vp);check(mtl_brush_polygons==4&&submissions==2&&liquid_draws==2,"inline opaque/liquid/alpha/liquidalpha count four actual faces");
 reset();cull=1;MTL_DrawBrushModel(&ent,vp);check(mtl_brush_polygons==0,"culled inline model contributes no polygons");cull=0;
 reset();mtl_encoder_open=0;MTL_DrawBrushModel(&ent,vp);check(mtl_brush_polygons==0,"closed-encoder model contributes no polygons");mtl_encoder_open=1;
 reset();tex[0].flags=0x10000;MTL_DrawBrushModel(&ent,vp);check(mtl_brush_polygons==3,"hidden inline face is omitted from warning count");tex[0].flags=SURF_DRAWSKY;
 reset();MTL_DrawBrushModel(&ent,vp);check(mtl_brush_polygons==3,"inline sky is omitted from warning count");tex[0].flags=0;
 reset();surfaces[0].normal[2]=-1;MTL_DrawBrushModel(&ent,vp);check(mtl_brush_polygons==3,"back-facing inline face is omitted from warning count");surfaces[0].normal[2]=1;
 reset();MTL_DrawSurface(&world,0,vp);MTL_DrawBrushModel(&ent,vp);MTL_DrawAlphaSurface(&surfaces[2],vp);check(mtl_brush_polygons==6,"warning count accumulates world plus inline plus sorted alpha");
 reset();check(mtl_brush_polygons==0,"per-view reset does not inherit preceding world polygons");
 printf("Actual brush polygon orchestration: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}}
