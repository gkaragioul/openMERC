// SPDX-License-Identifier: GPL-2.0-or-later
// Production sky clipping: a ceiling crossing cube-face boundaries must expose sides.
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
typedef float vec3_t[3];
typedef bool qboolean;
#define VectorClear(v) memset((v),0,sizeof(vec3_t))
#define VectorAdd(a,b,c) do { for(int _i=0;_i<3;_i++) (c)[_i]=(a)[_i]+(b)[_i]; } while(0)
#define VectorCopy(a,b) memcpy((b),(a),sizeof(vec3_t))
#define DotProduct(a,b) ((a)[0]*(b)[0]+(a)[1]*(b)[1]+(a)[2]*(b)[2])
#define ERR_DROP 1
static void Com_Error(int unused,const char *fmt,...) { (void)unused;fprintf(stderr,"%s\n",fmt);exit(2); }
#include "sky_clip_production.h"
int main(void)
{
 vec3_t ring[64]={{-1000,-1000,100},{1000,-1000,100},{1000,1000,100},{-1000,1000,100}};
 for(int i=0;i<6;i++) for(int a=0;a<2;a++){mtl_skymins[a][i]=9999;mtl_skymaxs[a][i]=-9999;}
 MTL_ClipSkyPolygon(4,ring[0],0);
 int failures=0;
 for(int i=0;i<5;i++) {
  if(!(mtl_skymins[0][i]<mtl_skymaxs[0][i] && mtl_skymins[1][i]<mtl_skymaxs[1][i])) {
   fprintf(stderr,"FAIL: ceiling must expose cube face %d\n",i);failures++;
  }
  for(int a=0;a<2;a++) if(mtl_skymins[a][i]<-1.001f || mtl_skymaxs[a][i]>1.001f) {
   fprintf(stderr,"FAIL: face %d axis%d bounds outside cube %.5f %.5f\n",i,a,mtl_skymins[a][i],mtl_skymaxs[a][i]);failures++;
  }
 }
 if(failures)return 1;
 puts("PASS: production sky ceiling clips to five cube faces with bounded coordinates");return 0;
}
