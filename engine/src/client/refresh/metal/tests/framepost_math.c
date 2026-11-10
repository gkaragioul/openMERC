// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-413 native projection and SPEC-AMEND-016 depth consumers.
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../mtl_framepost_math.h"
int main(void)
{
 const float n=.1f,f=65535;
 float p[16]={1.2f,0,0,0,0,1.7f,0,0,0,0,f/(n-f),-1,0,0,f*n/(n-f),0};
 float v[16]={0,1,0,0,-1,0,0,0,0,0,1,0,7,-12,-3,1},pv[16],inv[16],unit[16];
 MTL_FramePostMultiply(p,v,pv);assert(MTL_FramePostInverse(pv,inv));MTL_FramePostMultiply(pv,inv,unit);
 for(int c=0;c<4;c++)for(int r=0;r<4;r++)assert(fabsf(unit[c*4+r]-(c==r))<.0001f);
 for(int reverse=0;reverse<2;reverse++)for(int i=0;i<3;i++){
  float d=i==0?n:i==1?12:f,ndc=-p[10]+p[14]/d;
  float z=reverse?1-ndc:ndc;
  float got=MTL_FramePostEyeDistance(z,p[10],p[14],reverse?1:0,reverse?0:1);
  assert(fabsf(got-d)<fmaxf(.0001f,d*.04f));
 }
 /* Reconstruct world points with the actual inversePV helper. Expected world
  * positions come from this known rigid view, independently of inverse code. */
 for(int i=0;i<3;i++){
  const double distance=i==0?n:i==1?12:f;
  const double eye_x=distance*.17,eye_y=distance*-.11;
  const double ndc[4]={p[0]*eye_x/distance,p[5]*eye_y/distance,-p[10]+p[14]/distance,1};
  double world[4]={0};for(int r=0;r<4;r++)for(int c=0;c<4;c++)world[r]+=inv[c*4+r]*ndc[c];
  /* view maps world (X,Y,Z) to (-Y+7,X-12,Z-3). */
  const double expected[3]={eye_y+12,7-eye_x,3-distance};
  for(int k=0;k<3;k++)assert(fabs(world[k]/world[3]-expected[k])<fmax(.0001,distance*.04));
 }
 /* At the far sentinel, float projection/depth quantization cannot recover
  * a requested65535 exactly. Pin the encoded native C,D formula itself. */
 for(int i=0;i<3;i++){
  float z=i*.5f;double expected=(double)p[14]/((double)z+p[10]);
  double actual=MTL_FramePostEyeDistance(z,p[10],p[14],0,1);
  assert(fabs(actual-expected)<fabs(expected)*1e-6);
 }
 float singular[16]={0};assert(!MTL_FramePostInverse(singular,inv));
 p[0]=NAN;assert(!MTL_FramePostInverse(p,inv));
 assert(!isfinite(MTL_FramePostEyeDistance(.5f,-1,-.1f,1,1)));
 puts("PASS: actual native PV inverse, near/mid/far eye distance, reversed range, world reconstruction, singular/nonfinite rejection");return 0;
}
