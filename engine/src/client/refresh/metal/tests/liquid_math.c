// SPDX-License-Identifier: GPL-2.0-or-later
// Numeric parity with actual GPL GL3 subdivision and liquid draw functions.
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#define DEG2RAD(x) ((x)*0.017453292519943295f)
typedef float vec3_t[3];typedef int qboolean;
#define true 1
#define false 0
#define VectorCopy(a,b) memcpy(b,a,sizeof(vec3_t))
#define VectorClear(a) memset(a,0,sizeof(vec3_t))
#define DotProduct(a,b) ((a)[0]*(b)[0]+(a)[1]*(b)[1]+(a)[2]*(b)[2])
#define VectorScale(a,s,b) do{for(int z=0;z<3;z++)(b)[z]=(a)[z]*(s);}while(0)
#define VectorAdd(a,b,c) do{for(int z=0;z<3;z++)(c)[z]=(a)[z]+(b)[z];}while(0)
#define VectorSubtract(a,b,c) do{for(int z=0;z<3;z++)(c)[z]=(a)[z]-(b)[z];}while(0)
#define VectorMA(a,s,b,c) do{for(int z=0;z<3;z++)(c)[z]=(a)[z]+(s)*(b)[z];}while(0)
static void VectorNormalize(float *p){float n=sqrtf(DotProduct(p,p));if(n)VectorScale(p,1/n,p);}
static void AngleVectors(const float *a,float *f,float *r,float *u) {
 float p=a[0]*(float)(M_PI/180),y=a[1]*(float)(M_PI/180),b=a[2]*(float)(M_PI/180);
 float sp=sinf(p),cp=cosf(p),sy=sinf(y),cy=cosf(y),sr=sinf(b),cr=cosf(b);
 f[0]=cp*cy;f[1]=cp*sy;f[2]=-sp;
 r[0]=-sr*sp*cy+cr*sy;r[1]=-sr*sp*sy-cr*cy;r[2]=-sr*cp;
 u[0]=cr*sp*cy+sr*sy;u[1]=cr*sp*sy-sr*cy;u[2]=cr*cp;
}
#define ERR_DROP 1
static void Com_Error(int code,const char *s,int n){(void)code;fprintf(stderr,s,n);abort();}
static void *allocations[8192];static int numalloc;
static void *Hunk_Alloc(size_t n){assert(numalloc<8192);return allocations[numalloc++]=calloc(1,n);}
typedef struct {float pos[3],texCoord[2],normal[3];int lightFlags;} gl3_3D_vtx_t;
typedef struct glpoly_s {struct glpoly_s *next;int numverts;gl3_3D_vtx_t vertices[4];} glpoly_t;
typedef struct gl3image_s {int width,height,texnum,softype;struct gl3image_s *detail;} gl3image_t;
typedef struct {float vecs[2][4];int flags;gl3image_t *image;} mtexinfo_t;
typedef struct {float normal[3];} plane_t;
typedef struct {plane_t *plane;mtexinfo_t *texinfo;glpoly_t *polys;} msurface_t;
struct model_s {int dummy;};static struct model_s world;static struct model_s *gl3_worldmodel=&world;
typedef struct {struct model_s *model;float angles[3],origin[3];int frame;} entity_t;
typedef struct {int texnum,texmode,alphatest,culling,blend,depthwrite;} gl3fxstate_t;
typedef struct {float pos[3],st[2],rgba[4];} gl3fxvtx_t;
static struct {float vieworg[3],viewangles[3];} r_newrefdef;
static struct {float value;} cull={1};static void *r_cull_unused;
#define r_cull (&cull)
#define SOFSURF_WAVES 0x2000
#define SOFIMG_ENV 8
#define GL_TRIANGLE_FAN 6
static float clock_value;static float GL3_GameTime(void){return clock_value;}
static gl3image_t *GL3_SoF_TextureAnimation(const mtexinfo_t *t,int frame){(void)frame;return t->image;}
static void GL3_FX_DefaultState(gl3fxstate_t *s){memset(s,0,sizeof(*s));}
static void GL3_Fog_SetHardwareFxState(int region,gl3fxstate_t *s){(void)region;(void)s;}
static gl3fxstate_t state,states[2];static int npass;
static void GL3_FX_SetState(gl3fxstate_t *s){state=*s;states[npass++]=*s;}
static gl3fxvtx_t reference[32768];static int ref_count,ref_counts[8192],ref_polys;
static float queries[32768][3];static int nquery;
static void GL3_FX_Add(gl3fxvtx_t *v,int n,int mode){assert(mode==6);assert(ref_count+n<32768);memcpy(reference+ref_count,v,n*sizeof(*v));ref_count+=n;ref_counts[ref_polys++]=n;}
static void GL3_FX_Flush(void){}
static void sample_light(const float p[3],float c[3]){c[0]=.2f+p[0]*.0001f;c[1]=.3f+p[1]*.0001f;c[2]=.4f+p[2]*.0001f;}
static void GL3_SoF_LightPoint(const float p[3],float c[3],int direction){assert(direction==255);assert(nquery<32768);memcpy(queries[nquery++],p,12);sample_light(p,c);}
#include "liquid_reference.h"
#include "../mtl_liquid_geometry.h"
#include "../mtl_liquid_inline_geometry.h"
static int actualquery,checks;
static void light_cb(void *context,const float p[3],float c[3]) {
 (void)context;assert(actualquery<nquery);
 for(int k=0;k<3;k++)assert(fabsf(p[k]-queries[actualquery][k])<.0002f);
 actualquery++;sample_light(p,c);
}
static void eq(float a,float b){checks++;if(fabsf(a-b)>.0002f){fprintf(stderr,"FAIL numeric: %.9g != %.9g\n",a,b);abort();}}
static void run(const float (*ring)[3],int n,int flags,int sphere,int model,float clock)
{
 gl3image_t env={.softype=8},image={.width=128,.height=256,.texnum=7,.detail=sphere?&env:NULL};
 mtexinfo_t tex={.vecs={{.7f,.2f,.1f,123},{-.1f,.8f,.2f,-91}},.flags=flags,.image=&image};
 plane_t plane={{0,0,-1}};msurface_t surface={.plane=&plane,.texinfo=&tex};
 float wrapped[64][3];memcpy(wrapped,ring,(size_t)n*12);R_SubdividePolygon(n,wrapped[0],&surface);
 mtl_liquid_poly_t *polys=NULL;assert(MTL_LiquidSubdivide(n,ring,&polys));
 glpoly_t *g=surface.polys;int pc=0;
 for(mtl_liquid_poly_t *p=polys;p;p=p->next){assert(g&&p->count==g->numverts);for(int j=0;j<p->count;j++)for(int k=0;k<3;k++)eq(p->pos[j][k],g->vertices[j].pos[k]);g=g->next;pc++;}
 assert(!g&&pc>0);
 entity_t entity={.model=model?(struct model_s*)1:gl3_worldmodel,.angles={25,72,-17},.origin={67,-23,41}};
 clock_value=clock;r_newrefdef.vieworg[0]=-576;r_newrefdef.vieworg[1]=128;r_newrefdef.vieworg[2]=-400;
 r_newrefdef.viewangles[0]=45;r_newrefdef.viewangles[1]=90;r_newrefdef.viewangles[2]=0;
 ref_count=ref_polys=nquery=npass=0;GL3_Liquid_Draw(&surface,&entity,flags&0x800,-1);
 mtl_liquid_params_t params={.clock=clock,.flags=flags,.table=turbtable};
 memcpy(params.vecs,tex.vecs,sizeof(tex.vecs));memcpy(params.normal,plane.normal,12);memcpy(params.eye,r_newrefdef.vieworg,12);
 AngleVectors(r_newrefdef.viewangles,params.forward,params.right,params.up);
 float matrix[16];if(model){MTL_LiquidEntityMatrix(entity.origin,entity.angles,matrix);params.matrix=matrix;}
 if(model)MTL_LiquidTransform(matrix,params.normal,params.normal,0);
 g=surface.polys;
 for(mtl_liquid_poly_t *p=polys;p;p=p->next){
  mtl_liquid_vertex_t iv[64];float centerlight[3]={.2f,.3f,.4f};
  MTL_LiquidInlineVertices(p,params.matrix,tex.vecs,image.width,image.height,centerlight,iv);
  for(int j=0;j<p->count;j++){
   for(int k=0;k<2;k++)eq(iv[j].uv[k],g->vertices[j].texCoord[k]);
   eq(iv[j].color[0],.2f);eq(iv[j].color[3],1);
  }
  g=g->next;
 }
 actualquery=0;int index=0,polyindex=0;
 for(int pass=0;pass<(sphere?2:1);pass++)for(mtl_liquid_poly_t *p=polys;p;p=p->next){
  assert(ref_counts[polyindex++]==p->count);
  for(int j=0;j<p->count;j++){
   mtl_liquid_vertex_t v;MTL_LiquidEvaluate(&params,p->pos[j],pass,light_cb,NULL,&v);
   gl3fxvtx_t *r=&reference[index++];for(int k=0;k<3;k++)eq(v.pos[k],r->pos[k]);for(int k=0;k<2;k++)eq(v.uv[k],r->st[k]);for(int k=0;k<4;k++)eq(v.color[k],r->rgba[k]);
  }
 }
 assert(index==ref_count&&actualquery==nquery&&polyindex==ref_polys);
 assert(states[0].depthwrite==!(flags&0x800));if(sphere)assert(states[1].blend==((flags&0x800)?5:0)&&!states[1].alphatest);
 MTL_LiquidFree(polys);while(numalloc)free(allocations[--numalloc]);
}
int main(void)
{
 float rounding[16]={0},large[3]={-100000000,1,1},transformed[3];
 rounding[0]=rounding[4]=rounding[8]=1;rounding[12]=100000000;
 MTL_LiquidTransform(rounding,large,transformed,1);eq(transformed[0],2);
 (void)r_cull_unused;float table[256];int starts=0;MTL_LiquidTableInit(table,&starts);GL3_Liquid_Init();
 for(int i=0;i<256;i++)eq(table[i],turbtable[i]);eq(table[64],4);eq(table[192],-4);
 eq(MTL_LiquidTurb(table,-.01f),table[0]);eq(MTL_LiquidTurb(table,-.1f),table[252]);
 const float kos2[][3]={{-640,0,-476},{-640,48,-476},{-640,336,-476},{-640,368,-476},{-640,512,-476},{-512,512,-476},{-512,336,-476},{-512,0,-476}};
 const float edge[][3]={{-7,-7,0},{71,-7,0},{71,71,0},{-7,71,0}};
 const float triangle[][3]={{-136,-130,-17},{141,-107,23},{-12,163,50}};
 for(int restart=0;restart<2;restart++){
  for(int waves=0;waves<2;waves++)for(int alpha=0;alpha<2;alpha++)for(int sphere=0;sphere<2;sphere++)for(int model=0;model<2;model++)for(int tick=-1;tick<=2;tick++){
   int flags=8|0x40|0x30|(waves?0x2000:0)|(alpha?0x800:0);
   run(kos2,8,flags,sphere,model,tick*1.237f);run(edge,4,flags,sphere,model,tick*.293f);run(triangle,3,flags,sphere,model,tick*.73f);
  }
  MTL_LiquidTableInit(table,&starts);GL3_Liquid_Init();for(int i=0;i<256;i++)eq(table[i],turbtable[i]);
 }
 float stream[18][8]={};for(int i=0;i<6;i++){memcpy(stream[3*i],kos2[0],12);memcpy(stream[3*i+1],kos2[i+1],12);memcpy(stream[3*i+2],kos2[i+2],12);}
 float recovered[60][3];assert(MTL_LiquidReadRing(stream,sizeof(stream[0]),18,recovered)==8);for(int i=0;i<8;i++)for(int k=0;k<3;k++)eq(recovered[i][k],kos2[i][k]);
 assert(!MTL_LiquidReadRing(stream,sizeof(stream[0]),17,recovered));assert(!MTL_LiquidReadRing(stream,4,18,recovered));
 mtl_liquid_poly_t *p=(void*)1;assert(!MTL_LiquidSubdivide(61,kos2,&p)&&p==NULL);assert(!MTL_LiquidSubdivide(2,kos2,&p));
 const float square[][3]={{0,0,0},{128,0,0},{128,128,0},{0,128,0}};
 assert(MTL_LiquidSubdivide(4,square,&p));float eye[3]={96,96,10};
 float im[16]={1,0,0,0,0,1,0,0,0,0,1,0,10,20,30,1};
 float vecs[2][4]={{.7f,.2f,.1f,123},{-.1f,.8f,.2f,-91}},lc[3]={.2f,.3f,.4f};
 mtl_liquid_vertex_t iv[64];MTL_LiquidInlineVertices(p,im,vecs,128,256,lc,iv);
 float cs=0,ct=0;for(int i=1;i<p->count-1;i++){
  float s=DotProduct(p->pos[i],vecs[0])*.5f,t=DotProduct(p->pos[i],vecs[1])*.25f;cs+=s;ct+=t;
  eq(iv[i].uv[0],s);eq(iv[i].uv[1],t);eq(iv[i].pos[0],p->pos[i][0]+10);eq(iv[i].pos[2],30);eq(iv[i].color[0],.2f);eq(iv[i].color[3],1);
 }
 eq(iv[0].uv[0],cs/(p->count-2));eq(iv[0].uv[1],ct/(p->count-2));
 eq(iv[p->count-1].uv[0],iv[1].uv[0]);
 eq(MTL_LiquidSortKey(p,eye,10000),100);
 /* Current GPL sort's p->chain visits just the head: preserve the known
  * discrepancy as a comparator, not as production's authoritative rule. */
 mtl_liquid_poly_t *rest=p->next;p->next=NULL;eq(MTL_LiquidSortKey(p,eye,10000),2148);p->next=rest;
 eq(MTL_LiquidSortKey(p,eye,50),50);MTL_LiquidFree(p);
 float invalid[3][3]={{NAN,0,0},{1,0,0},{0,1,0}};assert(!MTL_LiquidSubdivide(3,invalid,&p));
 printf("PASS: %d GL3 numeric comparisons; subdivision/order, stock ring, transforms, raw UV/no flow, light queries, waves/env, two restarts and malformed inputs\n",checks);
 return 0;
}
