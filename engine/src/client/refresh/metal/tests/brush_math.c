// SPDX-License-Identifier: GPL-2.0-or-later
// Literal SPEC-411 rotation/culling and SPEC-412 brush sorting vectors.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define DEG2RAD(x) ((x)*0.017453292519943295f)
typedef float vec3_t[3];
#include "../mtl_brush_math.h"
#include "brush_matrix_production.h"
static void close_value(float a,float b) {assert(fabsf(a-b)<1e-4f);}
int main(void)
{
	assert(MTL_BrushRange(2,3,5));assert(MTL_BrushRange(5,0,5));
	assert(!MTL_BrushRange(2,4,5));assert(!MTL_BrushRange(-1,1,5));
	assert(!MTL_BrushRange(1,INT_MAX,5));assert(!MTL_BrushRange(INT_MAX,1,INT_MAX));
	assert(MTL_BrushInlineIndex("*1",3)==1);assert(MTL_BrushInlineIndex("*2",3)==2);
	assert(MTL_BrushInlineIndex("*256",257)==256);assert(MTL_BrushInlineIndex("*0",3)<0);
	assert(MTL_BrushInlineIndex("*257",300)<0);assert(MTL_BrushInlineIndex("*99999999999999999",300)<0);
	assert(MTL_BrushInlineIndex("*2junk",3)<0);assert(MTL_BrushInlineIndex("*3",3)<0);
	float origin[3]={10,20,30},angles[3]={30,0,0},p[3]={2,0,0},m[16],out[3],local[3];
	MTL_EntityMatrix(origin,angles,m);MTL_BrushXform(m,p,out,1);
	close_value(out[0],11.7320508f);close_value(out[1],20);close_value(out[2],31);
	MTL_BrushLocalEye(m,out,local);for(int k=0;k<3;k++) close_value(local[k],p[k]);
	angles[0]=0;angles[1]=90;MTL_EntityMatrix(origin,angles,m);MTL_BrushXform(m,p,out,0);
	close_value(out[0],0);close_value(out[1],2);close_value(out[2],0);
	angles[0]=25;angles[1]=-33;angles[2]=17;MTL_EntityMatrix(origin,angles,m);
	p[0]=-3;p[1]=4;p[2]=7;MTL_BrushXform(m,p,out,1);MTL_BrushLocalEye(m,out,local);
	for(int k=0;k<3;k++) close_value(local[k],p[k]);
	float mins[3]={-2,-4,-6},maxs[3]={3,5,7},a[3]={0},bmin[3],bmax[3];
	MTL_BrushBounds(mins,maxs,10,origin,a,bmin,bmax);close_value(bmin[0],8);close_value(bmax[2],37);
	a[2]=1;MTL_BrushBounds(mins,maxs,10,origin,a,bmin,bmax);
	close_value(bmin[0],0);close_value(bmin[2],20);close_value(bmax[1],30);
	float fmin[3]={-640,384,-128},fmax[3]={-432,388,0},zero[3]={0},eye[3]={-536,184,-70};
	close_value(MTL_BrushCenterKey(fmin,fmax,zero,eye),40840);
	float normal[3]={1,0,0},point[3]={0},front[3]={0.02f,0,0},back[3]={-1,0,0};
	assert(MTL_BrushFront(front,point,normal));assert(!MTL_BrushFront(back,point,normal));
	front[0]=0.01f;assert(!MTL_BrushFront(front,point,normal));
	puts("PASS: brush range/index, production matrix, inverse eye, culling bounds, center key and backface epsilon");
	return 0;
}
