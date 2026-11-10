// SPDX-License-Identifier: GPL-2.0-or-later
#include <math.h>
#include <stdio.h>
#include "../mtl_menu_geometry.h"
static int mtl_menu_active;
static float mtl_menu_mvp[16],mtl_ghoul_mvp[16];
#include "menu_selector.h"
static int failures;
static void check(int truth,const char *label) {if(!truth){fprintf(stderr,"FAIL: %s\n",label);failures++;}}
static float depth(const float *m,float z) {return (m[10]*z+m[14])/(m[11]*z+m[15]);}
int main(void)
{
 float p[16];MTL_MenuProjection(1920,1080,1,0,4,65535,p);
 check(p[12]==-1 && p[13]==1 && fabsf(p[0]*960)<1.00001f,"orthographic screen origin and width");
 check(fabsf(p[0]*1920+p[12]-1)<1e-6f && fabsf(p[5]*1080+p[13]+1)<1e-6f,"screen far corners");
 check(fabsf(depth(p,-9999))<1e-6f && fabsf(depth(p,9999)-1)<1e-6f,"negative orthographic z nearer");
 MTL_MenuProjection(1920,1080,1.5f,0,4,65535,p);
 check(fabsf(p[0]*1280+p[12]-1)<1e-6f && fabsf(p[5]*720+p[13]+1)<1e-6f,"fractional menu virtual coordinates");
 MTL_MenuProjection(1920,1080,1,1,4,65535,p);
 check(fabsf(depth(p,-4))<1e-6f && fabsf(depth(p,-65535)-1)<1e-6f,"perspective near/far clip depth");
 check(fabsf(p[5]/p[0]-1.3333f)<1e-6f && fabsf(p[5]-3.2964708286950746f)<1e-6f,"menu fixed fovy and aspect");
 MTL_MenuProjection(1920,1080,1,1,0,65535,p);
 check(fabsf(depth(p,-0.1f))<1e-6f,"perspective minimum near clamp");
 mtl_menu_active=0;check(MTL_GhoulProjection()==mtl_ghoul_mvp,"normal models use world projection");
 mtl_menu_active=1;check(MTL_GhoulProjection()==mtl_menu_mvp,"menu models use explicit projection before any world frame");
 mtl_menu_active=0;check(MTL_GhoulProjection()==mtl_ghoul_mvp,"menu leave restores world projection");
 if(failures)return 1;puts("PASS: production native menu projection/depth/scale/consumer selection");return 0;
}
