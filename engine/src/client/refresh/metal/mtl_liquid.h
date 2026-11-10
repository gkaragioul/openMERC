// SPDX-License-Identifier: GPL-2.0-or-later
// Native SoF liquid adapter. Implements: SPEC-410, SPEC-411 section 8,
// SPEC-413 section 1 and SPEC-AMEND-006 I4c.1.
// Include after renderer/model types, game-clock and point-light declarations.
#include "mtl_liquid_geometry.h"
#include "mtl_liquid_shader.h"

static float mtl_liquid_table[256];
static int mtl_liquid_starts;
static id<MTLRenderPipelineState> mtl_liquid_pipelines[2][2];

/* Use AngleVectors exactly as the GPL liquid/inline-alpha paths do. The
 * general renderer matrix is algebraically equivalent but computes several
 * coefficient products in a different float order. Table index boundaries
 * must see the same world-space arithmetic as the liquid reference. */
static void MTL_LiquidEntityMatrix(const float origin[3],const float angles[3],float out[16])
{
 float a[3]={-angles[0],angles[1],-angles[2]},forward[3],right[3],up[3];
 AngleVectors(a,forward,right,up);memset(out,0,16*sizeof(float));
 for(int k=0;k<3;k++){out[k]=forward[k];out[4+k]=-right[k];out[8+k]=up[k];out[12+k]=origin[k];}
 out[15]=1;
}

/* One call per renderer start, not per map or registration. Shutdown keeps
 * the start count, matching the reference module's restart halving. */
static void MTL_LiquidInit(void)
{
 MTL_LiquidTableInit(mtl_liquid_table,&mtl_liquid_starts);
 for(int pass=0;pass<2;pass++)for(int alpha=0;alpha<2;alpha++)
  mtl_liquid_pipelines[pass][alpha]=MTL_BuildLiquidPipeline(pass,alpha);
}

static void MTL_LiquidShutdown(void)
{
 for(int pass=0;pass<2;pass++)for(int alpha=0;alpha<2;alpha++)
  mtl_liquid_pipelines[pass][alpha]=nil;
}

static void MTL_LiquidLight(void *context,const float point[3],float color[3])
{
 (void)context;MTL_SoFLightPointDir(point,color,255);
}

static mtl_liquid_poly_t *MTL_LiquidSurfacePolys(const mtl_model_t *model,
 const mtl_surface_t *surface)
{
 if(!model||!model->vbuf||!surface||!surface->texinfo||
  !(surface->texinfo->flags&8)||surface->first_vertex<0||surface->num_vertex<3||
  surface->first_vertex>model->vbuf_vertices||
  surface->num_vertex>model->vbuf_vertices-surface->first_vertex)return NULL;
 const mtl_world_vertex_t *source=(const mtl_world_vertex_t *)
  [(__bridge id<MTLBuffer>)model->vbuf contents]+surface->first_vertex;
 float ring[60][3];int n=MTL_LiquidReadRing(source,sizeof(*source),surface->num_vertex,ring);
 mtl_liquid_poly_t *polys=NULL;
 if(!n||!MTL_LiquidSubdivide(n,ring,&polys))return NULL;
 return polys;
}

/* World alpha only: inline alpha retains the entity centre key. All pieces
 * are authoritative per SPEC-410/412; the GPL chain/next discrepancy is
 * pinned separately by the numeric test. No light queries while sorting. */
static float MTL_SoFLiquidSortKey(const mtl_model_t *world,const mtl_surface_t *surface,
 const float eye[3],float far_squared)
{
 mtl_liquid_poly_t *polys=MTL_LiquidSurfacePolys(world,surface);
 float key=MTL_LiquidSortKey(polys,eye,far_squared);MTL_LiquidFree(polys);return key;
}

/* image is the already-selected animated BASE image. matrix and texinfo must
 * describe the original model, before brush transient worldspace conversion.
 * stored_normal is the original unflipped BSP plane normal. World uses NULL
 * matrix. Inline 0x800 faces intentionally use the separate centre-lit path. */
static int MTL_DrawSoFLiquid(const mtl_model_t *model,const mtl_surface_t *surface,
 const mtl_image_t *image,const float mvp[16],const float *matrix,
 const float stored_normal[3],int translucent,int culling,int drawflat)
{
 if(!mtl_encoder_open||!image||!image->tex||!stored_normal)return 0;
 translucent=translucent!=0;
 if(!mtl_liquid_pipelines[0][translucent])return 0;
 mtl_liquid_poly_t *polys=MTL_LiquidSurfacePolys(model,surface);
 if(!polys)return 0;
 size_t ntri=0;
 for(mtl_liquid_poly_t *p=polys;p;p=p->next)ntri+=(size_t)(p->count-2)*3;
 mtl_liquid_vertex_t *vertices=calloc(ntri,sizeof(*vertices));
 if(!vertices){MTL_LiquidFree(polys);return 0;}
 mtl_liquid_params_t params={0};
 params.clock=MTL_GameTime();params.flags=surface->texinfo->flags;
 params.table=mtl_liquid_table;params.matrix=matrix;
 memcpy(params.vecs,surface->texinfo->vecs,sizeof(params.vecs));
 MTL_LiquidTransform(matrix,stored_normal,params.normal,0);
 memcpy(params.eye,mtl_refdef.vieworg,sizeof(params.eye));
 AngleVectors(mtl_refdef.viewangles,params.forward,params.right,params.up);
 int environment=!drawflat&&image->detail&&image->detail->kind==8;
 for(int pass=0;pass<(environment?2:1);pass++){
  size_t index=0;
  for(mtl_liquid_poly_t *p=polys;p;p=p->next){
   mtl_liquid_vertex_t fan[64];
   for(int i=0;i<p->count;i++)
    MTL_LiquidEvaluate(&params,p->pos[i],pass,MTL_LiquidLight,NULL,&fan[i]);
   for(int i=1;i<p->count-1;i++){
    vertices[index++]=fan[0];vertices[index++]=fan[i];vertices[index++]=fan[i+1];
   }
  }
  id<MTLBuffer> buffer=[mtl_device newBufferWithBytes:vertices
   length:ntri*sizeof(*vertices) options:MTLResourceStorageModeShared];
  if(!buffer){free(vertices);MTL_LiquidFree(polys);return 0;}
  /* Metal retains this immutable stream until submitted commands complete.
   * There is no map/image ownership or persistent mesh allocation here. */
  [mtl_enc setRenderPipelineState:MTL_BuildLiquidPipeline(pass,translucent)];
  mtl_post_emission_controls_t emission_controls=MTL_PostEmissionControls();
  MTL_PostBindEmission(MTL_PostEmissionForBlend(pass&&translucent?5:0,0,&emission_controls),3);
  [mtl_enc setDepthStencilState:translucent?mtl_depth_readonly:mtl_depth_world];
  [mtl_enc setCullMode:!translucent&&culling?MTLCullModeBack:MTLCullModeNone];
  [mtl_enc setFrontFacingWinding:MTLWindingClockwise];
  [mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
  [mtl_enc setVertexBuffer:buffer offset:0 atIndex:0];
  [mtl_enc setVertexBytes:mvp length:16*sizeof(float) atIndex:1];
  [mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)image->tex atIndex:0];
  [mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];
  [mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:ntri];
 }
 free(vertices);MTL_LiquidFree(polys);return 1;
}
