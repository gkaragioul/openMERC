// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-413 native projection; current GPL gl3_post depth consumers.
#ifndef OM_METAL_FRAMEPOST_MATH_H
#define OM_METAL_FRAMEPOST_MATH_H
#include <math.h>
#include <string.h>
static void MTL_FramePostMultiply(const float a[16],const float b[16],float out[16])
{
 float result[16];
 for(int c=0;c<4;c++)for(int r=0;r<4;r++){
  float value=0;for(int k=0;k<4;k++)value+=a[k*4+r]*b[c*4+k];result[c*4+r]=value;
 }
 memcpy(out,result,sizeof(result));
}
static int MTL_FramePostInverse(const float in[16],float out[16])
{
 double a[4][8];
 for(int r=0;r<4;r++)for(int c=0;c<8;c++){
  if(c<4&&!isfinite(in[c*4+r]))return 0;
  a[r][c]=c<4?in[c*4+r]:(c-4==r);
 }
 for(int c=0;c<4;c++){
  int pivot=c;for(int r=c+1;r<4;r++)if(fabs(a[r][c])>fabs(a[pivot][c]))pivot=r;
  if(a[pivot][c]==0)return 0;
  if(pivot!=c)for(int k=0;k<8;k++){double x=a[c][k];a[c][k]=a[pivot][k];a[pivot][k]=x;}
  double scale=a[c][c];for(int k=0;k<8;k++)a[c][k]/=scale;
  for(int r=0;r<4;r++)if(r!=c){double v=a[r][c];for(int k=0;k<8;k++)a[r][k]-=v*a[c][k];}
 }
 float result[16];for(int r=0;r<4;r++)for(int c=0;c<4;c++){
  result[c*4+r]=(float)a[r][c+4];if(!isfinite(result[c*4+r]))return 0;
 }
 memcpy(out,result,sizeof(result));return 1;
}
static float MTL_FramePostEyeDistance(float z,float C,float D,float depth_min,float depth_max)
{
 if(depth_min==depth_max)return INFINITY;
 float mapped=(z-depth_min)/(depth_max-depth_min);
 return D/(mapped+C);
}
#endif
