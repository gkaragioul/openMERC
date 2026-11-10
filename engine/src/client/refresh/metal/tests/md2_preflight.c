// SPDX-License-Identifier: GPL-2.0-or-later
// Actual shared GPL loader baseline versus native raw-byte preflight.
#include "../../../../common/header/common.h"
#include "../../ref_shared.h"
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <limits.h>
#define MTL_ALIAS_STRIDE 48
static void *hunk;
static int loader_calls,skin_calls,hunk_bytes;
void *Hunk_Begin(int bytes){hunk_bytes=bytes;return hunk=calloc(1,(size_t)bytes);}
void *Hunk_Alloc(int bytes){assert(bytes<=hunk_bytes);return hunk;}
short LittleShort(short n){return n;}int LittleLong(int n){return n;}float LittleFloat(float n){return n;}
void Com_Printf(const char *s,...){(void)s;}
#include "md2_parser_production.h"
#include "md2_loader_production.h"
static struct image_s *skin(const char *name,imagetype_t type)
{assert(type==it_skin);assert(strlen(name)<MAX_SKINNAME);skin_calls++;return NULL;}
static void *attempt(const void *data,size_t bytes)
{
#if MD2_PREFLIGHT
 if(!MTL_MD2DataValid(data,bytes))return NULL;
#endif
 vec3_t mins,maxs;struct image_s *skins[MAX_MD2SKINS]={0};modtype_t type;
 loader_calls++;return Mod_LoadMD2("fixture.md2",data,(int)bytes,mins,maxs,skins,skin,&type);
}
int main(void)
{
 dmdl_t *truncated=calloc(1,sizeof(*truncated));
 truncated->ident=IDALIASHEADER;truncated->version=ALIAS_VERSION;truncated->ofs_end=sizeof(*truncated);
 truncated->num_xyz=3;truncated->num_st=truncated->num_tris=truncated->num_frames=truncated->num_glcmds=1;
 truncated->framesize=offsetof(daliasframe_t,verts)+3*sizeof(dtrivertx_t);
 truncated->ofs_st=truncated->ofs_tris=truncated->ofs_frames=truncated->ofs_glcmds=sizeof(*truncated);
 assert(!attempt(truncated,sizeof(*truncated)));free(truncated);
#if MD2_PREFLIGHT
 assert(loader_calls==0);assert(!MTL_MD2DataValid(NULL,0));
 size_t bytes=sizeof(dmdl_t)+64+12+12+52+44;
 byte *raw=calloc(1,bytes+1);dmdl_t *h=(dmdl_t *)raw;
 h->ident=IDALIASHEADER;h->version=ALIAS_VERSION;h->ofs_end=(int)bytes;
 h->num_xyz=h->num_st=3;h->num_skins=h->num_tris=h->num_frames=1;h->num_glcmds=11;h->framesize=52;
 h->ofs_skins=sizeof(*h);h->ofs_st=h->ofs_skins+64;h->ofs_tris=h->ofs_st+12;h->ofs_frames=h->ofs_tris+12;h->ofs_glcmds=h->ofs_frames+52;
 int *cmd=(int *)(raw+h->ofs_glcmds);cmd[0]=3;cmd[3]=0;cmd[6]=1;cmd[9]=2;
 memset(raw+h->ofs_skins,'x',63);raw[h->ofs_skins+63]=0;
 assert(MTL_MD2DataValid(raw,bytes)); // maximum legal63-byte skin name
 assert(attempt(raw,bytes));assert(loader_calls==1&&skin_calls==1);free(hunk);hunk=NULL;
 raw[h->ofs_skins+63]='x';assert(!MTL_MD2DataValid(raw,bytes)); // no NUL in field
 assert(!attempt(raw,bytes)&&loader_calls==1&&skin_calls==1);
 raw[h->ofs_skins]=0;assert(MTL_MD2DataValid(raw,bytes)); // existing empty-name fallback
 assert(attempt(raw,bytes));assert(loader_calls==2&&skin_calls==2);free(hunk);hunk=NULL;
 memmove(raw+1,raw,bytes);assert(MTL_MD2DataValid(raw+1,bytes)); // unaligned raw byte span
 assert(!MTL_MD2DataValid(raw+1,bytes-1));free(raw);
 puts("PASS: actual shared-loader preflight rejects truncated spans before loader, accepts63-byte/empty skin names, rejects unterminated names and handles unaligned raw bytes");
#endif
 free(hunk);return 0;
}
