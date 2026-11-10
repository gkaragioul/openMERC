// SPDX-License-Identifier: GPL-2.0-or-later
// Actual native descriptor predicate against read-only stock map metadata.
#include "../../../../common/header/common.h"
#include "../../../../common/header/files.h"
#include "../mtl_brush_math.h"
#include "brush_descriptors_production.h"
#include "brush_descriptor_records.h"
int main(void)
{
 int failures=0;
 for(unsigned n=0;n<sizeof(records)/sizeof(records[0]);n++) {
  dmodel_t d={0};d.headnode=records[n][1];d.firstface=records[n][2];d.numfaces=records[n][3];
  if(!MTL_TestDescriptor(&d,records[n][0],face_count,node_count,leaf_count)) {
   fprintf(stderr,"FAIL stock tsr1 model%d head%d faces%d+%d\n",records[n][0],d.headnode,d.firstface,d.numfaces);failures++;
  }
 }
 dmodel_t d={0};d.firstface=face_count;d.headnode=-1;
 if(MTL_TestDescriptor(&d,0,face_count,node_count,leaf_count)){fprintf(stderr,"FAIL world root must be a node\n");failures++;}
 d.headnode=INT_MIN;
 if(MTL_TestDescriptor(&d,1,face_count,node_count,leaf_count)){fprintf(stderr,"FAIL INT_MIN leaf reference\n");failures++;}
 d.headnode=-leaf_count-1;
 if(MTL_TestDescriptor(&d,1,face_count,node_count,leaf_count)){fprintf(stderr,"FAIL out-of-range leaf\n");failures++;}
 d.headnode=-1;d.firstface=0;d.numfaces=1;
 if(MTL_TestDescriptor(&d,1,face_count,node_count,leaf_count)){fprintf(stderr,"FAIL drawable brush needs a node\n");failures++;}
 d.headnode=node_count;d.numfaces=0;
 if(MTL_TestDescriptor(&d,1,face_count,node_count,leaf_count)){fprintf(stderr,"FAIL out-of-range node\n");failures++;}
 d.headnode=0;d.firstface=INT_MAX;d.numfaces=INT_MAX;
 if(MTL_TestDescriptor(&d,1,face_count,node_count,leaf_count)){fprintf(stderr,"FAIL face range overflow\n");failures++;}
 if(failures)return 1;
 puts("PASS: actual native validation accepts stock empty leaf-rooted inline models and rejects invalid ranges");return 0;
}
