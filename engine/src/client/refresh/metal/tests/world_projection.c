// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-413 near-plane degree ladder and native [0,1] clip depth.
#include <math.h>
#include <stdio.h>
#include <string.h>
#define DEG2RAD(x) ((x)*(3.14159265358979323846f/180.0f))
#define RAD2DEG(x) ((x)*(180.0f/3.14159265358979323846f))
typedef struct {float value;} cvar_t;
static cvar_t near_value={1},far_value={65535};
static cvar_t *mtl_nearclip_cvar=&near_value,*mtl_farclip_cvar=&far_value;
#include "world_projection_production.h"
int main(void)
{
 const float cases[][2]={{1,1},{60,1},{90,1},{120,1},{90,16.0f/9}};
 int failures=0;
 for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
  double y=2*atan(tan(cases[i][0]*3.14159265358979323846/360)/cases[i][1])*180/3.14159265358979323846;
  double expected=y<5?3.9:y<75?1+(75-y)/70*2.9:1;
  float p[16];MTL_ProjMatrix(cases[i][0],cases[i][1],p);
  double near=(double)p[14]/p[10];
  if(fabs(near-expected)>1e-5){fprintf(stderr,"FAIL fov%.1f/aspect%.5f near%.7f expected%.7f\n",cases[i][0],cases[i][1],near,expected);failures++;}
  double nz=(-p[10]*near+p[14])/near;
  double fz=(-p[10]*65535.0+p[14])/65535.0;
  if(fabs(nz)>1e-6 || fabs(fz-1)>1e-6){fprintf(stderr,"FAIL native clip depth near/far\n");failures++;}
 }
 near_value.value=0;far_value.value=0;
 float p[16];MTL_ProjMatrix(90,1,p);
 if(fabs(p[14]/p[10]-.1f)>1e-6){fprintf(stderr,"FAIL near clamp uses degrees before far guard\n");failures++;}
 if(failures)return 1;
 puts("PASS: world projection degree ladder, near/far guards and native clip endpoints");return 0;
}
