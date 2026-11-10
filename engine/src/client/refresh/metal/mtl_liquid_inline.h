// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 inline alpha, SPEC-411 section 8.
// Include after mtl_liquid.h. Caller preserves face order and samples the
// entity's bounding-box center exactly once for all inline alpha faces.
#include "mtl_liquid_inline_geometry.h"

static int MTL_DrawSoFLiquidInlineAlpha(const mtl_model_t *model,
 const mtl_surface_t *surface,const mtl_image_t *image,const float mvp[16],
 const float *matrix,const float light[3])
{
 if(!mtl_encoder_open||!image||!image->tex||!mtl_liquid_pipelines[0][1])return 0;
 mtl_liquid_poly_t *polys=MTL_LiquidSurfacePolys(model,surface);if(!polys)return 0;
 size_t count=0;for(mtl_liquid_poly_t *p=polys;p;p=p->next)count+=(size_t)(p->count-2)*3;
 mtl_liquid_vertex_t *vertices=calloc(count,sizeof(*vertices));
 if(!vertices){MTL_LiquidFree(polys);return 0;}
 /* GPL stored subdivision coordinates use the original texinfo image's
  * dimensions at load time, even when the draw selects another frame. */
 const mtl_image_t *coordinate_image=(const mtl_image_t *)surface->texinfo->image;
 int width=coordinate_image?coordinate_image->width:0,height=coordinate_image?coordinate_image->height:0;
 size_t index=0;
 for(mtl_liquid_poly_t *p=polys;p;p=p->next){
  mtl_liquid_vertex_t fan[64];
  MTL_LiquidInlineVertices(p,matrix,surface->texinfo->vecs,width,height,light,fan);
  for(int i=1;i<p->count-1;i++){
   vertices[index++]=fan[0];vertices[index++]=fan[i];vertices[index++]=fan[i+1];
  }
 }
 id<MTLBuffer> buffer=[mtl_device newBufferWithBytes:vertices length:count*sizeof(*vertices)
  options:MTLResourceStorageModeShared];
 free(vertices);MTL_LiquidFree(polys);if(!buffer)return 0;
 [mtl_enc setRenderPipelineState:MTL_BuildLiquidPipeline(0,1)];
 [mtl_enc setDepthStencilState:mtl_depth_readonly];
 [mtl_enc setCullMode:MTLCullModeNone];
 [mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
 [mtl_enc setVertexBuffer:buffer offset:0 atIndex:0];
 [mtl_enc setVertexBytes:mvp length:16*sizeof(float) atIndex:1];
 [mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)image->tex atIndex:0];
 [mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];
 [mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count];
 return 1;
}
