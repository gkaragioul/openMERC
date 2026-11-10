// SPDX-License-Identifier: GPL-2.0-or-later
// Independent numeric vectors for SPEC-412 billboard/beam and colour rules.
#include <assert.h>
#include <stdio.h>
#include "../mtl_fx_geometry.h"

static void close_value(float actual, float expected) { assert(fabsf(actual-expected) < 1e-5f); }
int main(void)
{
	const float eye[3]={0,0,0}, right[3]={0,-1,0}, up[3]={0,0,1};
	sofalphaquad_t q={0}; mtl_fx_vertex_t v[4];
	q.flags=SOF_AQ_BILLBOARD; q.origin[0]=10; q.v0c[0]=2; q.v0c[1]=3; q.f18=1;
	assert(MTL_FXGeometry(&q,eye,right,up,0,v)==4);
	const float expected[4][3]={{10,3,-2},{10,3,2},{10,-3,2},{10,-3,-2}};
	for(int i=0;i<4;i++) for(int k=0;k<3;k++) close_value(v[i].position[k],expected[i][k]);
	close_value(v[0].uv[0],0); close_value(v[0].uv[1],0);
	close_value(v[1].uv[0],0); close_value(v[1].uv[1],1);
	close_value(v[2].uv[0],1); close_value(v[2].uv[1],1);
	q.f18=0; q.f1c=1;
	assert(MTL_FXGeometry(&q,eye,right,up,0,v)==4);
	close_value(v[0].position[1],-2); close_value(v[0].position[2],-3);
	q.flags|=SOF_AQ_ORIENTED; q.normal[0]=1; q.f18=1; q.f1c=0;
	assert(MTL_FXGeometry(&q,eye,right,up,0,v)==4);
	close_value(v[0].position[1],-3); close_value(v[0].position[2],-2);
	/* Batched chains ignore orientation/rotation and use one 1.25-UV triangle. */
	assert(MTL_FXGeometry(&q,eye,right,up,1,v)==3);
	close_value(v[0].position[0],10); close_value(v[0].position[1],0);
	close_value(v[1].position[2],2); close_value(v[2].position[1],-3);
	close_value(v[1].uv[1],1.25f); close_value(v[2].uv[0],1.25f);
	q.flags=SOF_AQ_BEAM; q.origin[1]=-3; q.v0c[0]=10; q.v0c[1]=3; q.v0c[2]=0; q.f18=2;
	assert(MTL_FXGeometry(&q,eye,right,up,0,v)==4);
	close_value(v[0].position[1],-3); close_value(v[0].position[2],2);
	close_value(v[2].position[1],3); close_value(v[2].position[2],-2);
	memcpy(q.v0c,q.origin,sizeof(q.origin));
	assert(MTL_FXGeometry(&q,eye,right,up,0,v)==0);
	q.flags=0; assert(MTL_FXGeometry(&q,eye,right,up,0,v)==0);
	q.color[0]=128; q.color[1]=255; q.color[2]=64; q.color[3]=128;
	const float light[3]={2,2,2}; float c[4];
	MTL_FXColor(&q,light,0,c); close_value(c[0],128/255.0f); close_value(c[3],128/255.0f);
	MTL_FXColor(&q,light,1,c); close_value(c[0],0); close_value(c[1],254/255.0f);
	q.flags=SOF_AQ_ADDITIVE; MTL_FXColor(&q,light,0,c);
	close_value(c[0],128*128/(255.0f*255.0f)); close_value(c[3],1);
	q.flags=SOF_AQ_DARKEN; MTL_FXColor(&q,light,1,c);
	close_value(c[0],2*128*128/(255.0f*255.0f)); close_value(c[3],1);
	puts("PASS: native FX billboard/rotation/orientation/beam/batch and colour vectors");
	return 0;
}
