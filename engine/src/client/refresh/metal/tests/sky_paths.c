// SPDX-License-Identifier: GPL-2.0-or-later
// Production SetSky + R_FindPic tested against names present in the user's PAK.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <assert.h>
#define MAX_QPATH 64
#define Q_stricmp strcasecmp
#define VectorCopy(a,b) memcpy((b),(a),sizeof(vec3_t))
typedef float vec3_t[3];
typedef enum {it_pic,it_sky} imagetype_t;
typedef struct image_s mtl_image_t;
struct image_s {int index;struct image_s *detail;void *tex;};
typedef struct image_s *(*findimage_t)(const char *,imagetype_t);
typedef struct {float value;} cvar_t;
static cvar_t skymip,*mtl_skymip_cvar=&skymip;
static float mtl_skyrotate,mtl_sky_min,mtl_sky_max;
static vec3_t mtl_skyaxis;
static mtl_image_t *mtl_skyimages[6],images[3]={{.index=0},{.index=1},{.index=2}};
static int failures,wrongtype;
static int image_frees,texture_releases,fences;
#define YES 1
#define NO 0
static struct {int no_sky;} mtl_post;
static void MTL_ModelFence(void){fences++;}
static void CFRelease(void *texture){if(texture)texture_releases++;}
static void SkyFree(void *image){for(int i=0;i<3;i++)if(image==&images[i]){image_frees++;return;}abort();}
#define ERR_DROP 1
static void Com_Error(int unused,const char *message){(void)unused;fprintf(stderr,"%s\n",message);abort();}
#include "sky_asset_names.h"
static const char *current_text;
static const char *COM_FileExtension(const char *s) {const char *p=strrchr(s,'.');return p?p+1:"";}
static void Q_strlcpy(char *dst,const char *src,size_t size) {snprintf(dst,size,"%s",src);}
static void Com_sprintf(char *dst,size_t size,const char *fmt,...)
{
	va_list args;va_start(args,fmt);vsnprintf(dst,size,fmt,args);va_end(args);
}
static struct image_s *MTL_FindImage(const char *path,imagetype_t type)
{
	for(int i=0;i<3;i++) if(!strcmp(path,actual_sky_names[i])) {
		if(type!=it_sky)wrongtype++;
		return &images[i];
	}
	return NULL;
}
static int FS_LoadFile(const char *path,void **out)
{
	assert(!strcmp(path,"pics/sky/bos.txt"));
	size_t size=strlen(current_text);*out=malloc(size+1);memcpy(*out,current_text,size+1);return (int)size;
}
static struct {int (*FS_LoadFile)(const char *,void **);void (*FS_FreeFile)(void *);} ri={FS_LoadFile,free};
#include "sky_pic_production.h"
static mtl_image_t *MTL_FindPic(const char *name) {return R_FindPic(name,MTL_FindImage);}
#define free SkyFree
#include "sky_set_production.h"
#undef free
static void check(int pass,const char *label) {if(!pass){fprintf(stderr,"FAIL: %s\n",label);failures++;}}
int main(void)
{
	vec3_t axis={0,0,1};current_text=actual_sky_text;
	for(int i=0;i<3;i++)images[i].tex=(void *)(size_t)(i+1);
	images[0].detail=&images[1];images[1].detail=&images[0];images[2].detail=&images[1];
	MTL_SoF_SetSky("bos",0,axis);
	const int expected[5]={0,1,0,1,2};
	for(int i=0;i<5;i++)check(mtl_skyimages[i]==&images[expected[i]],"existing kos2 root-relative extensionless sky image loads");
	check(mtl_skyimages[5]==NULL,"none bottom stays absent");
	check(wrongtype==0,"sky images use sky upload type");
	check(mtl_skyrotate==0 && mtl_skyaxis[2]==1,"rotation/axis retained");
	check(mtl_post.no_sky==NO,"a sky with pictures is not a level without sky");
	current_text="textures/sky/bos_side2.m32\r\nNONE\r\ntextures/sky/bos_up\r\ntextures/sky/absent\r\nnone\r\nnone\r\n";
	MTL_SoF_SetSky("bos",3,axis);
	check(image_frees==3 && texture_releases==3 && fences==1,"replacing sky fences and retires each unique image/texture once");
	for(int i=0;i<3;i++)images[i].detail=NULL;
	check(mtl_skyimages[0]==&images[0],"explicit extension preserved");
	check(mtl_skyimages[1]==NULL && mtl_skyimages[3]==NULL,"none and missing image remain absent");
	check(mtl_skyimages[2]==&images[2],"mixed explicit/extensionless lines retain face slots");
	check(mtl_skyimages[4]==NULL && mtl_skyimages[5]==NULL,"new registration clears old slots");
	check(wrongtype==0,"explicit image also uses sky upload type");
	check(mtl_sky_min==1.0f/256 && mtl_sky_max==255.0f/256,"rotation texel inset preserved");
	current_text="none\nnone\nnone\nnone\nnone\nnone\n";
	MTL_SoF_SetSky("bos",0,axis);
	check(image_frees==5 && texture_releases==5 && fences==2,"clearing sky retires remaining images before pointers are lost");
	check(mtl_post.no_sky==YES,"all six faces none: the level has no sky (its picture is cleared every frame)");
	if(failures)return 1;
	puts("PASS: production sky lookup resolves stock root-relative names, extensions, sky type, none/missing and face slots");return 0;
}
