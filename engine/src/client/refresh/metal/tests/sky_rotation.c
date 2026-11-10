// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 game-clock sky rotation, against the GPL GL3 matrix.
#include <math.h>
#include <stdio.h>
#include <string.h>
#define HANDMADE_MATH_IMPLEMENTATION
#define HANDMADE_MATH_NO_SSE
#include "HandmadeMath.h"
typedef float vec3_t[3];
#define DEG2RAD(x) ((x)*(3.14159265358979323846f/180.0f))
#include "sky_rotation_production.h"

int main(void)
{
    const float axes[][3]={{0,0,1},{0,2,0},{2,-3,4},{0,0,0}};
    const float rates[]={0,90,-15,37.5f};
    const float times[]={0,1,3.25f,19.5f};
    const float points[][3]={{37800,12345,-37800},{1,0,0},{0,-37800,37800}};
    const vec3_t eye={-536,184,-70};
    int failed=0,checks=0;
    for (unsigned a=0;a<4;a++) for (unsigned r=0;r<4;r++)
    for (unsigned t=0;t<4;t++) for (unsigned p=0;p<3;p++) {
        hmm_mat4 m=HMM_Translate(HMM_Vec3(eye[0],eye[1],eye[2]));
        if(rates[r]!=0) m=HMM_MultiplyMat4(m,HMM_Rotate(times[t]*rates[r],
            HMM_Vec3(axes[a][0],axes[a][1],axes[a][2])));
        float out[3]; MTL_SkyPosition(points[p],eye,rates[r],axes[a],times[t],out);
        for (int row=0;row<3;row++) {
            float expected=m.Elements[3][row];
            for(int c=0;c<3;c++) expected+=m.Elements[c][row]*points[p][c];
            checks++;
            if(!isfinite(out[row])||fabsf(out[row]-expected)>.025f) {
                if(failed<8)fprintf(stderr,"FAIL axis%u rate%.2f time%.2f point%u/%d: %.5f expected %.5f\n",
                    a,rates[r],times[t],p,row,out[row],expected);
                failed++;
            }
        }
    }
    printf("sky rotation: %d checks, %d failed\n",checks,failed);
    return failed?1:0;
}
