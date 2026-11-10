// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 actual production load/free region ownership hooks.
// Shared geometry loaders are bounded fixture inputs; the complete native
// MTL_LoadBrushModel and MTL_FreeModel bodies are extracted without alteration.
#include "../../../../common/header/common.h"
#include "../../../../common/header/files.h"
#include "../../ref_shared.h"
#include "../mtl_brush_math.h"
#include "../mtl_fog_math.h"
#include <limits.h>
#include <stdarg.h>
typedef struct mtl_image_s {void *tex;struct mtl_image_s *detail;} mtl_image_t;
#include "fog_registration_types.h"
static mtl_model_t *mtl_worldmodel;
#include "../mtl_fog.h"
static byte image[2048];static int loads,errors;
static mvertex_t vertices[3]={{{0,0,0}},{{10,0,0}},{{0,20,30}}};
static medge_t edges[3]={{.v={0,1}},{.v={1,2}},{.v={2,0}}};static int surfedges[3]={0,1,2};
static cplane_t plane;static mnode_t node;static mtexinfo_t texinfo;
static mtl_image_t *mtl_notexture;static void *mtl_ghoul_system;
void Com_Error(int code,const char *fmt,...) {(void)code;fprintf(stderr,"unexpected production error: %s\n",fmt);abort();}
void Com_Printf(const char *fmt,...) {(void)fmt;}
int LittleLong(int v) {return v;}
float LittleFloat(float v) {return v;}
int Q_strlcpy(char *out,const char *in,int n) {return snprintf(out,(size_t)n,"%s",in);}
void Com_sprintf(char *out,int n,const char *fmt,...) {va_list args;va_start(args,fmt);vsnprintf(out,(size_t)n,fmt,args);va_end(args);}
void *Hunk_Begin(int bytes) {(void)bytes;return malloc(1);}
int Hunk_End(void) {return 1;}
void Hunk_Free(void *p) {free(p);}
static void CFRelease(void *p) {free(p);}
static void MTL_LightmapFree(void *p) {free(p);}
static int loadfile(const char *name,void **out) {(void)name;*out=malloc(sizeof(image));memcpy(*out,image,sizeof(image));loads++;return sizeof(image);}
refimport_t ri={.FS_LoadFile=loadfile,.FS_FreeFile=free};
void Mod_LoadVertexes(const char *n,mvertex_t **out,int *count,const byte *b,const lump_t *l,int e) {(void)n;(void)b;(void)l;(void)e;*out=vertices;*count=3;}
void Mod_LoadEdges(const char *n,medge_t **out,int *count,const byte *b,const lump_t *l,int e) {(void)n;(void)b;(void)l;(void)e;*out=edges;*count=3;}
void Mod_LoadSurfedges(const char *n,int **out,int *count,const byte *b,const lump_t *l,int e) {(void)n;(void)b;(void)l;(void)e;*out=surfedges;*count=3;}
void Mod_LoadTexinfo(const char *n,mtexinfo_t **out,int *count,const byte *b,const lump_t *l,findimage_t f,struct image_s *im,int e) {(void)n;(void)b;(void)l;(void)f;(void)im;(void)e;*out=&texinfo;*count=0;}
void Mod_LoadLighting(byte **out,const byte *b,const lump_t *l) {(void)b;(void)l;*out=NULL;}
void Mod_LoadVisibility(dvis_t **out,const byte *b,const lump_t *l) {(void)b;(void)l;*out=NULL;}
void Mod_LoadPlanes(const char *n,cplane_t **out,int *count,const byte *b,const lump_t *l,int e) {(void)n;(void)b;(void)l;(void)e;plane.normal[2]=1;*out=&plane;*count=1;}
void Mod_LoadNodes(const char *n,cplane_t *p,int np,mleaf_t *lf,int nl,mnode_t **out,int *count,const byte *b,const lump_t *l) {(void)n;(void)p;(void)np;(void)lf;(void)nl;(void)b;(void)l;*out=&node;*count=1;}
mleaf_t *Mod_PointInLeaf(const vec3_t p,mnode_t *n) {(void)p;(void)n;return mtl_worldmodel?mtl_worldmodel->leafs:NULL;}
float Mod_RadiusFromBounds(const vec3_t mins,const vec3_t maxs) {(void)mins;(void)maxs;return 1;}
static struct image_s *MTL_FindImage(const char *n,imagetype_t t) {(void)n;(void)t;return NULL;}
static void MTL_TrackModelImage(mtl_model_t *m,mtl_image_t *i) {(void)m;(void)i;}
static void MTL_LoadLeafs(mtl_model_t *m,const byte *b,const lump_t *l,int v) {(void)b;(void)v;m->numleafs=l->filelen/32;m->leafs=calloc(m->numleafs,sizeof(*m->leafs));}
static void MTL_LoadWorldSurfaces(mtl_model_t *m,const byte *b,const lump_t *l,int v) {
 (void)b;(void)v;m->numsurfaces=l->filelen/44;m->surfaces=calloc(m->numsurfaces,sizeof(*m->surfaces));
 for(int i=0;i<m->numsurfaces;i++){m->surfaces[i].flags=0x10000;m->surfaces[i].bsp_plane=&plane;}
}
static void MTL_LinkMarksurfaces(mtl_model_t *m,const byte *b,const lump_t *l) {(void)m;(void)b;(void)l;}
static void MTL_SoF_WorldLights(const byte *b,int n) {(void)b;(void)n;}
static void OMGhoul_BeginWorldLights(void *p) {(void)p;}
static void OMGhoul_FinishWorldLights(void *p) {(void)p;}
#include "fog_registration_functions.h"
int main(void) {
 dheader46_t *h=(dheader46_t *)image;h->version=BSPVERSION_SOF;
 h->lumps[LUMP_FACES]=(lump_t){184,44};h->lumps[LUMP_FACEPOLYS]=(lump_t){228,8};h->lumps[LUMP_VOLUMES]=(lump_t){236,76};
 h->lumps[LUMP_LEAFS]=(lump_t){312,32};h->lumps[LUMP_MODELS]=(lump_t){344,sizeof(dmodel_t)};h->lumps[LUMP_NODES]=(lump_t){392,sizeof(dnode_t)};
 dface46_t *face=(dface46_t *)(image+184);face->volume=0;face->numpolys=1;
 int pair[2]={0,3};memcpy(image+228,pair,sizeof(pair));float opacity=.5f;memcpy(image+240,&opacity,4);
 dmodel_t *dm=(dmodel_t *)(image+344);dm->numfaces=1;
 mtl_worldmodel=(mtl_model_t *)MTL_LoadBrushModel("maps/fog-fixture.bsp");int failed=0;
 if(!mtl_worldmodel||!mtl_worldmodel->fog||mtl_worldmodel->fog->numregions!=1){fprintf(stderr,"FAIL: actual MTL_LoadBrushModel discards SoF fog regions\n");failed++;}
 if(mtl_worldmodel&&mtl_worldmodel->submodels[0].fog){fprintf(stderr,"FAIL: inline descriptor owns fog allocation\n");failed++;}
 if(mtl_worldmodel){MTL_FreeModel(mtl_worldmodel);mtl_worldmodel=NULL;}
 if(errors){fprintf(stderr,"FAIL: %d production load errors\n",errors);failed++;}
 if(!failed)printf("PASS: actual production load/free preserves root-owned fog, %d load\n",loads);return failed?1:0;
}
