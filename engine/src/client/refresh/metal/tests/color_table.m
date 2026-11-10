// SPDX-License-Identifier: GPL-2.0-or-later
// Real color-correction export must refresh the GPU lookup without mutating in-flight data.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
typedef unsigned char byte;
static byte mtl_colortable[256],ghoul_table[256];
static id<MTLDevice> mtl_device;
static id<MTLTexture> mtl_lighttable;
static void *mtl_ghoul_system=(void *)1;
static void OMGhoul_SetGamma(void *unused,const byte *table) {(void)unused;memcpy(ghoul_table,table,256);}
static void MTL_Fatal(const char *where,const char *message) {fprintf(stderr,"%s: %s\n",where,message);abort();}
#include "color_table_production.h"
int main(void)
{
 @autoreleasepool {
 MTL_SoF_SetColorCorrection(0,.5f,.5f,1); // Early, before device creation.
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 2;
 MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:256 height:1 mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
 mtl_lighttable=[mtl_device newTextureWithDescriptor:d];
 [mtl_lighttable replaceRegion:MTLRegionMake2D(0,0,256,1) mipmapLevel:0 withBytes:mtl_colortable bytesPerRow:256];
 id<MTLTexture> in_flight=mtl_lighttable;byte original[256];memcpy(original,mtl_colortable,256);
 MTL_SoF_SetColorCorrection(.2f,.4f,.65f,.9f);
 byte gpu[256];[mtl_lighttable getBytes:gpu bytesPerRow:256 fromRegion:MTLRegionMake2D(0,0,256,1) mipmapLevel:0];
 int failures=0;
 if(memcmp(gpu,mtl_colortable,256)){fprintf(stderr,"FAIL: GPU world lookup does not match changed correction\n");failures++;}
 if(memcmp(ghoul_table,mtl_colortable,256)){fprintf(stderr,"FAIL: Ghoul lookup differs\n");failures++;}
 [in_flight getBytes:gpu bytesPerRow:256 fromRegion:MTLRegionMake2D(0,0,256,1) mipmapLevel:0];
 if(memcmp(gpu,original,256)){fprintf(stderr,"FAIL: changed correction mutates in-flight lookup\n");failures++;}
 if(mtl_lighttable==in_flight){fprintf(stderr,"FAIL: changed correction must publish a new immutable GPU lookup\n");failures++;}
 if(failures)return 1;
 puts("PASS: correction refreshes GPU and Ghoul, preserves in-flight lookup and tolerates pre-device call");return 0;
 }
}
