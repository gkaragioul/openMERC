// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-412 sections 8/9. Pure native effect geometry/colour producer.
#ifndef OM_METAL_FX_GEOMETRY_H
#define OM_METAL_FX_GEOMETRY_H
#include <math.h>
#include <string.h>
#include "../../../common/header/sof/refapi.h"

typedef struct { float position[3], uv[2]; } mtl_fx_vertex_t;
static inline void MTL_FXCross(const float a[3],const float b[3],float out[3])
{
	out[0]=a[1]*b[2]-a[2]*b[1]; out[1]=a[2]*b[0]-a[0]*b[2]; out[2]=a[0]*b[1]-a[1]*b[0];
}
static inline int MTL_FXNormalize(float v[3])
{
	float length=sqrtf(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);
	if (!(length>1e-10f) || !isfinite(length)) return 0;
	for(int k=0;k<3;k++) v[k]/=length;
	return 1;
}
static inline int MTL_FXGeometry(const sofalphaquad_t *q,const float eye[3],
	const float right[3],const float up[3],int batched,mtl_fx_vertex_t out[4])
{
	static const float st[4][2]={{0,0},{0,1},{1,1},{1,0}};
	if(q->flags & SOF_AQ_BILLBOARD) {
		if(batched) {
			for(int k=0;k<3;k++) {
				out[0].position[k]=q->origin[k];
				out[1].position[k]=q->origin[k]+q->v0c[0]*up[k];
				out[2].position[k]=q->origin[k]+q->v0c[1]*right[k];
			}
			out[0].uv[0]=out[0].uv[1]=0;
			out[1].uv[0]=0; out[1].uv[1]=1.25f;
			out[2].uv[0]=1.25f; out[2].uv[1]=0;
			return 3;
		}
		float A[3],B[3];
		if(q->flags & SOF_AQ_ORIENTED) {
			int axis=0;
			if(fabsf(q->normal[1])<fabsf(q->normal[axis])) axis=1;
			if(fabsf(q->normal[2])<fabsf(q->normal[axis])) axis=2;
			for(int k=0;k<3;k++) B[k]=(k==axis?1.0f:0.0f)-q->normal[axis]*q->normal[k];
			if(!MTL_FXNormalize(B)) return 0;
			MTL_FXCross(q->normal,B,A);
		} else { memcpy(A,up,sizeof(A)); memcpy(B,right,sizeof(B)); }
		static const float sign[4][2]={{-1,-1},{1,-1},{1,1},{-1,1}};
		for(int i=0;i<4;i++) {
			float a=sign[i][0]*q->v0c[0], b=sign[i][1]*q->v0c[1];
			for(int k=0;k<3;k++) out[i].position[k]=q->origin[k]+
				(a*q->f18+b*q->f1c)*A[k]+(b*q->f18-a*q->f1c)*B[k];
			memcpy(out[i].uv,st[i],sizeof(out[i].uv));
		}
		return 4;
	}
	if(q->flags & SOF_AQ_BEAM) {
		float e[3],d[3],side[3];
		for(int k=0;k<3;k++) { e[k]=q->origin[k]-eye[k]; d[k]=q->v0c[k]-q->origin[k]; }
		MTL_FXCross(e,d,side);
		if(!MTL_FXNormalize(side)) return 0;
		for(int k=0;k<3;k++) {
			out[0].position[k]=q->origin[k]+q->f18*side[k];
			out[1].position[k]=q->origin[k]-q->f18*side[k];
			out[2].position[k]=q->v0c[k]-q->f18*side[k];
			out[3].position[k]=q->v0c[k]+q->f18*side[k];
		}
		for(int i=0;i<4;i++) memcpy(out[i].uv,st[i],sizeof(out[i].uv));
		return 4;
	}
	return 0;
}
static inline void MTL_FXColor(const sofalphaquad_t *q,const float light[3],int lit,float out[4])
{
	if(q->flags & (SOF_AQ_ADDITIVE|SOF_AQ_DARKEN)) {
		for(int k=0;k<3;k++) out[k]=q->color[k]*(lit?light[k]:1)*q->color[3]/(255.0f*255.0f);
		out[3]=1;
	} else {
		for(int k=0;k<3;k++) out[k]=lit?(((int)(q->color[k]*light[k]))&255)/255.0f:q->color[k]/255.0f;
		out[3]=q->color[3]/255.0f;
	}
}
#endif
