// SPDX-License-Identifier: GPL-2.0-or-later
// Exercise extracted production registration/ownership functions, not a reimplementation.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#define MAX_QPATH 64
#define MAX_MD2SKINS 32
#define ERR_DROP 1
#define mod_brush 1
#define mod_alias 2
#define IDBSPHEADER 123
#define IDALIASHEADER 456
#define IDSPRITEHEADER 789
#define LittleLong(x) (x)
#define Q_strlcpy(d,s,n) snprintf(d,n,"%s",s)
#define Q_stricmp strcmp
#define Com_sprintf snprintf
typedef unsigned char byte;
#include "../mtl_brush_math.h"
#include "../mtl_lightmap_math.h"
typedef struct { float value; const char *string; } cvar_t;
typedef struct mtl_image_s { void *tex; struct mtl_image_s *detail; } mtl_image_t;
typedef struct { void *lightmap,*lighting; } mtl_surface_t;
typedef struct mtl_model_s {
 char name[MAX_QPATH]; int type,numsubmodels,firstsurface,nummodelsurfaces,numsurfaces;
 struct mtl_model_s *submodels,*owner; int registration_sequence;
 void *hunk,*vbuf,*leafs,*marksurfaces,*aliashdr;
 mtl_surface_t *surfaces; mtl_image_t **owned_images,*skins[MAX_MD2SKINS];
 int num_owned_images;
} mtl_model_t;
static mtl_model_t *mtl_worldmodel,**mtl_models;
static int mtl_nummodels,mtl_registration_sequence,mtl_last_cluster;
static int mtl_alpha_count,mtl_detail_count;
static mtl_image_t placeholder,*mtl_notexture=&placeholder;
static int failures,loads,drops,frees,resources,fences;
static int post_region_count=7;
static void MTL_PostSetFogRegionCount(int count) {post_region_count=count;}
static cvar_t flushmap;
static cvar_t *mtl_monolightmap_cvar;
static int mtl_monolightmap_mode;
static void Com_Error(int code,const char *fmt,...) {(void)code;(void)fmt;drops++;}
static void Com_Printf(const char *fmt,...) {(void)fmt;}
static void MTL_ModelFence(void) {fences++;}
static void MTL_ClearLightCache(void) {}
static void Hunk_Free(void *ptr) {if(ptr){frees++;free(ptr);}}
static void CFRelease(void *ptr) {if(ptr){resources++;free(ptr);}}
/* GPU plane ownership is checked by the real Metal resource suite; this C
 * fixture observes the model registry's one-time retirement boundary. */
static void MTL_LightmapFree(void *ptr) {CFRelease(ptr);}
/* Region allocation/free is exercised with the exact production functions in
 * fog_registration.c; this registry fixture supplies no fog resource. */
static void MTL_FogFree(mtl_model_t *mod) {(void)mod;}
static cvar_t *Cvar_Get(const char *a,const char *b,int c) {(void)a;(void)b;(void)c;return &flushmap;}
static int FS_LoadFile(const char *name,void **out) {
 (void)name; if(out){int *v=malloc(sizeof(int));*v=IDBSPHEADER;*out=v;}return sizeof(int);
}
static void FS_FreeFile(void *ptr) {free(ptr);}
static struct {int (*FS_LoadFile)(const char *,void **);void (*FS_FreeFile)(void *);cvar_t *(*Cvar_Get)(const char *,const char *,int);} ri={FS_LoadFile,FS_FreeFile,Cvar_Get};
static struct model_s *MTL_LoadBrushModel(const char *name) {
 loads++;mtl_model_t *m=calloc(1,sizeof(*m));snprintf(m->name,sizeof(m->name),"%s",name);
 m->owner=m;m->type=mod_brush;m->numsubmodels=3;m->submodels=calloc(3,sizeof(*m));
 m->hunk=malloc(8);m->numsurfaces=2;m->surfaces=calloc(2,sizeof(*m->surfaces));
 m->surfaces[0].lighting=m->surfaces[0].lightmap=malloc(1);m->vbuf=malloc(1);m->leafs=malloc(1);m->marksurfaces=malloc(1);
 for(int i=0;i<3;i++){m->submodels[i]=*m;m->submodels[i].owner=m;}
 return (struct model_s *)m;
}
static mtl_model_t *MTL_LoadAliasModel(const char *name) {(void)name;return NULL;}
#include "brush_registration_production.h"
static void check(int pass,const char *label) {if(!pass){fprintf(stderr,"FAIL: %s\n",label);failures++;}}
int main(void) {
 mtl_worldmodel=(mtl_model_t *)MTL_RegisterModel("maps/a.bsp");
 check(mtl_worldmodel!=NULL,"world loads");
 check((mtl_model_t *)MTL_RegisterModel("*1")==&mtl_worldmodel->submodels[1],"inline 1 distinct descriptor");
 check((mtl_model_t *)MTL_RegisterModel("*2")==&mtl_worldmodel->submodels[2],"inline 2 distinct descriptor");
 int olddrops=drops;check(MTL_RegisterModel("*0")==NULL && drops==olddrops+1,"inline 0 rejected");
 olddrops=drops;check(MTL_RegisterModel("*3")==NULL && drops==olddrops+1,"out of range rejected");
 olddrops=drops;check(MTL_RegisterModel("*1junk")==NULL && drops==olddrops+1,"malformed inline rejected");
 mtl_model_t *old=mtl_worldmodel;
 check((mtl_model_t *)MTL_RegisterModel("maps/a.bsp")==old && loads==1,"name cache returns stable owner");
 cvar_t mono={0,"A"};mtl_monolightmap_cvar=&mono;
 mtl_monolightmap_mode=3; /* retained world's previously built C mode */
 MTL_BeginRegistration("a");check(mtl_worldmodel==old && loads==1,"same map retained");
 check(mtl_monolightmap_mode==3,"same-map retained lightmaps preserve their latched mono mode");
 MTL_EndRegistration();
 MTL_BeginRegistration("b");
 check(mtl_worldmodel && !strcmp(mtl_worldmodel->name,"maps/b.bsp") && loads==2,"new map replaces world");
 check(mtl_monolightmap_mode==4,"new map latches current mono selection");
 check(frees==1 && resources==2 && fences==1,"old owner resources and hunk disposed once behind fence");
#ifdef OM_BRUSH_OWNERSHIP
 mtl_model_t *view=&mtl_worldmodel->submodels[1];int oldfrees=frees;
 MTL_FreeModel(view);check(frees==oldfrees,"inline descriptor cannot free shared owner");
 mtl_image_t *im=calloc(1,sizeof(*im)),*detail=calloc(1,sizeof(*detail));
 im->tex=malloc(1);detail->tex=malloc(1);im->detail=detail;
 MTL_TrackModelImage(mtl_worldmodel,im);MTL_TrackModelImage(mtl_worldmodel,im);
 MTL_TrackModelImage(mtl_worldmodel,mtl_notexture);
 check(mtl_worldmodel->num_owned_images==2,"recursive images deduplicated; shared placeholder excluded");
 MTL_FreeModels();check(mtl_nummodels==0 && !mtl_models && !mtl_worldmodel,"shutdown clears model handles");
 check(post_region_count==0,"shutdown clears post fog-region count");
 check(frees==2 && resources==6 && fences==2,"each owned resource freed exactly once");
 MTL_FreeModels();check(frees==2 && resources==6,"repeated cleanup is harmless");
#endif
 if(failures)return 1;
 puts("PASS: production inline handles, validation, cache, map replacement and ownership");return 0;
}
