// SPDX-License-Identifier: GPL-2.0-or-later
// Label export geometry with hand-derived SPEC-412 placement and color oracles.
#include "../../../../common/header/common.h"
#include "../../ref_shared.h"
#include "../../../../common/header/sof/refapi.h"
#include <assert.h>
static refdef_t mtl_refdef;
static int text_calls,pic_calls,tx,ty,px,py,pw,ph;
static unsigned text_color;
static byte pic_color[4];
static int MTL_HUDFontHeight(const om_fontref_t *f){assert(!strcmp(f->chars,"small"));return 10;}
static int MTL_HUDFontWidth(char *t,const om_fontref_t *f){(void)t;(void)f;return 40;}
static void MTL_HUDFontString(int x,int y,char *t,unsigned c,const om_fontref_t *f,int keep){(void)t;(void)f;assert(keep==0);text_calls++;tx=x;ty=y;text_color=c;}
static void MTL_HUDGetPicSize(int *w,int *h,char *n){(void)n;*w=32;*h=16;}
static void MTL_HUDUnpack(unsigned c,byte out[4]){for(int i=0;i<4;i++)out[i]=(c>>(i*8))&255;}
static void MTL_HUDStretch(int x,int y,int w,int h,const byte *c,char *n,int rotation){(void)n;assert(rotation==0);pic_calls++;px=x;py=y;pw=w;ph=h;memcpy(pic_color,c,4);}
#include "world_labels_production.h"
static int failures;
static void check(int truth,const char *s){if(!truth){fprintf(stderr,"FAIL: %s\n",s);failures++;}}
int main(void)
{
 mtl_refdef.width=200;mtl_refdef.height=100;mtl_refdef.fov_x=mtl_refdef.fov_y=90;
 float point[3]={100,0,0};char text[]="Name",pic[]="icon";
 MTL_HUDWorldLabel(point,text,pic,0x44332211);
 check(text_calls==1 && tx==75 && ty==37 && text_color==0xffffffffu,"near label text position and opaque white");
 const byte expected[4]={0x11,0x22,0x33,0x44};
 check(pic_calls==1 && px==83 && py==17 && pw==24 && ph==12 && !memcmp(pic_color,expected,4),"near icon scaled placement and tint");
 text_calls=pic_calls=0;point[0]=512;
 MTL_HUDWorldLabel(point,text,pic,0x44332211);
 check(text_calls==1 && tx==76 && ty==41,"far text scale clamps at256");
 check(pic_calls==1 && px==90 && py==26 && pw==12 && ph==6,"far icon scale clamps at256");
 text_calls=pic_calls=0;point[0]=100;point[1]=-50;point[2]=25;
 MTL_HUDWorldLabel(point,text,NULL,0);
 check(text_calls==1 && tx==127 && ty==23 && pic_calls==0,"off-center text uses camera basis and truncation");
 text_calls=pic_calls=0;point[0]=-1;
 MTL_HUDWorldLabel(point,text,pic,0);MTL_HUDWorldLabel(NULL,text,pic,0);
 check(text_calls==0 && pic_calls==0,"behind/null origin skipped");
 point[0]=100;mtl_refdef.fov_x=0;MTL_HUDWorldLabel(point,text,pic,0);
 check(text_calls==0 && pic_calls==0,"invalid fov skipped");
 if(failures)return 1;puts("PASS: native label export near/far/off-center positions, text/icon colors and rejection");return 0;
}
