// SPDX-License-Identifier: GPL-2.0-or-later
// Actual native loader integration plus actual shared GPL MD2 file loader.
#define main SharedPreflightMain
#include "md2_preflight.c"
#undef main
typedef struct {
 char name[MAX_QPATH];void *aliashdr;size_t aliashdr_bytes;
 vec3_t mins,maxs;struct image_s *skins[MAX_MD2SKINS];modtype_t type;int numframes;float radius;
} mtl_model_t;
static const void *file_source;static int file_length,file_frees,hunk_ends;
static int load_file(const char *name,void **out){(void)name;*out=malloc((size_t)file_length);memcpy(*out,file_source,(size_t)file_length);return file_length;}
static void free_file(void *p){file_frees++;free(p);}
refimport_t ri={.FS_LoadFile=load_file,.FS_FreeFile=free_file};
int Hunk_End(void){hunk_ends++;return hunk_bytes;}
int Q_strlcpy(char *out,const char *s,int n){return snprintf(out,(size_t)n,"%s",s);}
static struct image_s *MTL_FindImage(const char *s,imagetype_t t){return skin(s,t);}
void *Mod_LoadSP2(const char *n,const void *p,int size,struct image_s **images,findimage_t fn,modtype_t *t)
{(void)n;(void)p;(void)size;(void)images;(void)fn;(void)t;abort();}
float Mod_RadiusFromBounds(const vec3_t a,const vec3_t b){(void)a;(void)b;return 1;}
#include "md2_native_production.h"
int main(void)
{
 file_source="IDP";file_length=3;assert(!MTL_LoadAliasModel("short.md2"));assert(file_frees==1&&hunk_ends==0);
 dmdl_t bad={0};bad.ident=IDALIASHEADER;bad.version=ALIAS_VERSION;bad.ofs_end=sizeof(bad);
 bad.num_xyz=bad.num_st=bad.num_tris=bad.num_frames=bad.num_glcmds=1;bad.framesize=44;
 bad.ofs_st=bad.ofs_tris=bad.ofs_frames=bad.ofs_glcmds=sizeof(bad);
 file_source=&bad;file_length=sizeof(bad);assert(!MTL_LoadAliasModel("bad.md2"));assert(file_frees==2&&hunk_ends==0);
 const int bytes=sizeof(dmdl_t)+12+12+52+44;byte *raw=calloc(1,bytes);dmdl_t *h=(dmdl_t *)raw;
 h->ident=IDALIASHEADER;h->version=ALIAS_VERSION;h->ofs_end=bytes;h->num_xyz=h->num_st=3;
 h->num_tris=h->num_frames=1;h->num_glcmds=11;h->framesize=52;
 h->ofs_skins=h->ofs_st=sizeof(*h);h->ofs_tris=h->ofs_st+12;h->ofs_frames=h->ofs_tris+12;h->ofs_glcmds=h->ofs_frames+52;
 int *cmd=(int *)(raw+h->ofs_glcmds);cmd[0]=3;cmd[3]=0;cmd[6]=1;cmd[9]=2;
 file_source=raw;file_length=bytes;mtl_model_t *model=MTL_LoadAliasModel("valid.md2");
 assert(model&&model->aliashdr&&model->aliashdr_bytes==(size_t)bytes&&model->numframes==1);
 assert(file_frees==3&&hunk_ends==1);free(model);free(hunk);hunk=NULL;free(raw);
 puts("PASS: actual native loader rejects short magic/truncated MD2 before hunk, frees source and preserves valid loaded size/frame metadata");return 0;
}
