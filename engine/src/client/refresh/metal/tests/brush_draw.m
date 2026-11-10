// SPDX-License-Identifier: GPL-2.0-or-later
// Production inline orchestration with real Metal buffers and observed draw boundaries.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../../../../common/header/common.h"
#include "../../ref_shared.h"
#include "../mtl_brush_math.h"
#include "../mtl_post_math.h"
#include "../../../../ghoul/ghoul_host.h"
#include <assert.h>
#define DEG2RAD(x) ((x)*0.017453292519943295f)
#include "brush_draw_types.h"
static id<MTLDevice> mtl_device;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLRenderPipelineState> mtl_pipe_world,mtl_pipe_fx_alpha;
static id<MTLRenderPipelineState> MTL_BuildWorldPipeline(void) {return mtl_pipe_world;}
static id<MTLRenderPipelineState> MTL_BuildAliasPipeline(int blend,int fragment)
{assert(blend==OM_GHOUL_NATIVE_BLEND_ALPHA && fragment==2);return mtl_pipe_fx_alpha;}
static void MTL_PostBindEmission(mtl_emission_t emission,NSUInteger index)
{assert(index==3);for(int k=0;k<4;k++)assert(emission.value[k]==0);}
static id<MTLDepthStencilState> mtl_depth_world,mtl_depth_readonly;
static id<MTLSamplerState> mtl_samp_world,mtl_samp_lm;
static int mtl_encoder_open=1,mtl_framecount=1,mtl_pdlight_active_count=1,mtl_detail_count;
static cvar_t nocull={0};static cvar_t *mtl_nocull_cvar=&nocull;
static cvar_t material_cull={.value=1},drawflat={0};
static cvar_t *mtl_cull_cvar=&material_cull,*mtl_drawflat_cvar=&drawflat;
static cplane_t mtl_frustum[4];
static refdef_t mtl_refdef;
static char events[32];static int nevents,lights,cull;
static mtl_image_t *animated;
static const mtl_model_t *liquid_model;
static int expected_detail=2;
static void close_value(float a,float b) {assert(fabsf(a-b)<1e-4f);}
static float MTL_GameTime(void) {return 2;}
static void MTL_SoFLightPoint(const vec3_t p,vec3_t color)
{
	close_value(p[0],30);close_value(p[1],21);close_value(p[2],30);
	lights++;VectorSet(color,.2f,.3f,.4f);
}
qboolean R_CullBox(vec3_t mins,vec3_t maxs,cplane_t *frustum)
{
	(void)frustum;close_value(mins[0],-30);close_value(maxs[2],70);return cull;
}
static void MTL_DrawSurface(mtl_model_t *model,int index,const float mvp[16])
{
	(void)mvp;assert(model->surfaces[index].texinfo->image==(struct image_s *)animated);
	assert(model->surfaces[index].dlightbits==1);assert(index==0 || index==2);
	const mtl_world_vertex_t *v=[(__bridge id<MTLBuffer>)model->vbuf contents];
	close_value(v[model->surfaces[index].first_vertex].pos[0],10);
	close_value(v[model->surfaces[index].first_vertex].pos[1],20+index*10);
	close_value(model->surfaces[index].texinfo->vecs[0][0],0);
	close_value(model->surfaces[index].texinfo->vecs[0][1],1);
	events[nevents++]='0'+index;mtl_detail_count++;
}
static void MTL_DrawDetailPass(mtl_model_t *model,const float mvp[16])
{
	(void)model;(void)mvp;assert(mtl_detail_count==expected_detail);events[nevents++]='D';
}
static int MTL_DrawSoFLiquid(const mtl_model_t *model,const mtl_surface_t *surface,
 const mtl_image_t *image,const float mvp[16],const float *matrix,
 const float normal[3],int translucent,int material_culling,int flat)
{
 (void)mvp;assert(model==liquid_model && image==animated && !translucent && material_culling && !flat);
 assert(surface==&model->surfaces[0] || surface==&model->surfaces[2]);
 close_value(matrix[12],10);close_value(matrix[13],20);close_value(matrix[14],30);
 close_value(normal[2],1);events[nevents++]='L';return 1;
}
static int MTL_DrawSoFLiquidInlineAlpha(const mtl_model_t *model,const mtl_surface_t *surface,
 const mtl_image_t *image,const float mvp[16],const float *matrix,const float light[3])
{
 (void)mvp;assert(model==liquid_model && image==animated);
 assert(surface==&model->surfaces[1] || surface==&model->surfaces[3]);
 close_value(matrix[12],10);close_value(matrix[13],20);close_value(light[0],.2f);
 events[nevents++]='I';return 1;
}
@interface BrushEncoder : NSObject {id<MTLBuffer> _buffer;}
@end
@implementation BrushEncoder
- (void)setRenderPipelineState:(id)p {(void)p;}
- (void)setDepthStencilState:(id)p {(void)p;}
- (void)setCullMode:(MTLCullMode)c {(void)c;}
- (void)setFrontFacingWinding:(MTLWinding)w {(void)w;}
- (void)setDepthBias:(float)a slopeScale:(float)b clamp:(float)c {(void)a;(void)b;(void)c;}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {(void)o;if(i==0)_buffer=b;}
- (void)setVertexBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i {(void)b;(void)n;(void)i;}
- (void)setFragmentBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i {(void)b;(void)n;(void)i;}
- (void)setFragmentTexture:(id)t atIndex:(NSUInteger)i {(void)t;(void)i;}
- (void)setFragmentSamplerState:(id)s atIndex:(NSUInteger)i {(void)s;(void)i;}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n
{
	(void)t;(void)s;assert(n==3);const mtl_alias_vertex_t *v=[_buffer contents];
	close_value(v[0].pos[0],10);close_value(v[0].color[0],.2f);close_value(v[2].color[2],.4f);
	events[nevents++]=(char)('0'+(int)lroundf((v[0].pos[1]-20)/10));
}
@end
#include "brush_draw_functions.h"
#include "../mtl_brush.h"
int main(void)
{
 @autoreleasepool {
	mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 2;
	BrushEncoder *encoder=[BrushEncoder new];mtl_enc=(id<MTLRenderCommandEncoder>)encoder;
	mtl_image_t base={0},alt={0};animated=&alt;alt.tex=(void *)1;
	mtexinfo_t textures[2]={0};textures[0].image=(struct image_s *)&base;textures[0].next=&textures[1];textures[0].numframes=2;
	textures[1].image=(struct image_s *)&alt;textures[1].next=&textures[0];textures[1].numframes=2;
	textures[0].vecs[0][0]=1;textures[0].vecs[1][1]=1;
	mtl_surface_t surfaces[4]={0};mtl_world_vertex_t vertices[12]={0};
	for(int i=0;i<4;i++){
		surfaces[i].first_vertex=i*3;surfaces[i].num_vertex=3;surfaces[i].texinfo=&textures[0];surfaces[i].normal[2]=1;
		for(int j=0;j<3;j++){vertices[3*i+j].pos[0]=10*i+(j==1);vertices[3*i+j].pos[1]=(j==2);}
	}
	mtexinfo_t alpha=textures[0];alpha.flags=0x800;surfaces[1].texinfo=surfaces[3].texinfo=&alpha;
	id<MTLBuffer> buffer=[mtl_device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared];
	cplane_t plane={0};plane.normal[2]=1;mnode_t node={0};mleaf_t leaf={0};leaf.contents=CONTENTS_SOLID;
	node.contents=CONTENTS_NODE;node.plane=&plane;node.numsurfaces=4;node.children[0]=node.children[1]=(mnode_t *)&leaf;
	mtl_model_t model={0};model.owner=&model;model.type=mod_brush;model.surfaces=surfaces;model.numsurfaces=model.nummodelsurfaces=4;
	model.vbuf=(__bridge void *)buffer;model.vbuf_vertices=12;model.radius=40;model.nodes=&node;
	VectorSet(model.maxs,40,2,0);
	dlight_t light={0};light.origin[2]=100;light.intensity=200;mtl_refdef.dlights=&light;mtl_refdef.num_dlights=1;
	VectorSet(mtl_refdef.vieworg,10,20,130);
	entity_t entity={0};entity.model=(struct model_s *)&model;entity.frame=1;
	VectorSet(entity.origin,10,20,30);entity.angles[1]=90;float vp[16]={0};
	MTL_DrawBrushModel(&entity,vp);
	assert(nevents==5 && !memcmp(events,"0213D",5));assert(lights==1 && mtl_detail_count==0);
	assert(!memcmp(vertices,[buffer contents],sizeof(vertices)));close_value(surfaces[0].normal[2],1);
	float key=MTL_BrushSortKey(&entity);close_value(key,10401);
	cull=1;MTL_DrawBrushModel(&entity,vp);assert(nevents==5);
	mtl_encoder_open=0;MTL_DrawBrushModel(&entity,vp);assert(nevents==5);
	mtl_encoder_open=1;cull=0;nevents=lights=0;expected_detail=0;
	textures[0].flags=8;liquid_model=&model;
	for(int i=0;i<4;i++)surfaces[i].liquid_plane_normal[2]=1;
	MTL_DrawBrushModel(&entity,vp);
	assert(nevents==5 && !memcmp(events,"LL13D",5) && lights==1);
	nevents=lights=0;alpha.flags=0x808;
	MTL_DrawBrushModel(&entity,vp);
	assert(nevents==5 && !memcmp(events,"LLIID",5) && lights==1);
	puts("PASS: production brush transform, immutable source, opaque/face-order-alpha/detail, one center-light, BSP mask and culling");
	return 0;
 }
}
