// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 inline alpha exceptions and GPL gl3_warp.c stored UVs.
// Include after mtl_liquid_geometry.h. These faces intentionally receive no
// time warp, waves or env pass; their one center light is supplied by caller.
static void MTL_LiquidInlineVertices(const mtl_liquid_poly_t *poly,const float *matrix,
 const float vecs[2][4],int width,int height,const float light[3],mtl_liquid_vertex_t out[64])
{
 int ring=poly->count-2;float total[2]={0,0};
 for(int i=0;i<poly->count;i++){
  memset(&out[i],0,sizeof(out[i]));MTL_LiquidTransform(matrix,poly->pos[i],out[i].pos,1);
  memcpy(out[i].color,light,12);out[i].color[3]=1;
 }
 for(int i=1;i<=ring;i++)for(int axis=0;axis<2;axis++){
  float coordinate=MTL_LiquidDot(poly->pos[i],vecs[axis]);
  if(width>0&&height>0)coordinate*=64.0f/(axis?height:width);
  out[i].uv[axis]=coordinate;total[axis]+=coordinate;
 }
 out[0].uv[0]=total[0]/ring;out[0].uv[1]=total[1]/ring;
 memcpy(out[poly->count-1].uv,out[1].uv,sizeof(out[1].uv));
}
