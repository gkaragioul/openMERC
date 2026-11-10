// SPDX-License-Identifier: GPL-2.0-or-later
// Native synchronous readback and resource retirement. Included by mtl_main.m
// after globals, before model ownership functions. The host supplies a forward
// declaration of MTL_HUDApplyClip and retains mtl_last_drawable at EndFrame.
// Every frame's initial color/depth attachments must use Store, and the
// CAMetalLayer must have framebufferOnly=NO for the requested blit readback.
// Implements: SPEC-002 slot 0xd4, SPEC-412 section 12.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "mtl_targets.h"

#define OM_METAL_READBACK 1

/* End/drain only the submitted portion of the current frame. A prepared Load
 * encoder resumes the same color/depth attachments. It neither presents nor
 * changes the frame's semaphore ownership: EndFrame remains the sole owner.
 * Preparing continuation first leaves the original encoder usable if resource
 * allocation fails. All command buffers use the same queue, in commit order. */
static BOOL
MTL_ReadbackDrain(id<MTLTexture> source, id<MTLBuffer> buffer, NSUInteger rowbytes)
{
	if (!mtl_queue) return NO;
	BOOL resume=mtl_encoder_open;
	id<MTLCommandBuffer> work=resume?mtl_cb:[mtl_queue commandBuffer];
	if (!work || work.status>=MTLCommandBufferStatusCommitted) return NO;
	id<MTLCommandBuffer> continuation=nil;
	id<MTLRenderCommandEncoder> encoder=nil;
	id<MTLTexture> color=nil;
	BOOL tracked=resume && MTL_TargetTracked();
	mtl_frame_targets_t targets=mtl_current_targets;
	if (resume) {
		/* A fence can retain an unresolved MSAA target even when no color
		 * readback was requested; only thumbnails require a resolve texture. */
		color=tracked?targets.color[0]:MTL_TargetReadableColor();
		if (!color || !mtl_enc) return NO;
		continuation=[mtl_queue commandBuffer];
		if (!continuation) return NO;
		if (tracked) {
			encoder=MTL_TargetCreateEncoder(continuation,&targets,MTLLoadActionLoad,MTLLoadActionLoad);
		} else {
			/* Compatibility for callers that have not adopted tracked targets
			 * yet. New world/post passes must always use MTL_TargetOpen. */
			MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
			pass.colorAttachments[0].texture=color;
			pass.colorAttachments[0].loadAction=MTLLoadActionLoad;
			pass.colorAttachments[0].storeAction=MTLStoreActionStore;
			if (mtl_depth) {
				pass.depthAttachment.texture=mtl_depth;
				pass.depthAttachment.loadAction=MTLLoadActionLoad;
				pass.depthAttachment.storeAction=MTLStoreActionStore;
			}
			encoder=[continuation renderCommandEncoderWithDescriptor:pass];
		}
		if (!encoder) return NO;
		MTL_TargetEnd();
	}
	BOOL copied=YES;
	if (buffer) {
		id<MTLBlitCommandEncoder> blit=[work blitCommandEncoder];
		copied=blit!=nil;
		if (blit) {
			[blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
				sourceSize:MTLSizeMake(source.width,source.height,1) toBuffer:buffer destinationOffset:0
				destinationBytesPerRow:rowbytes destinationBytesPerImage:rowbytes*source.height];
			[blit endEncoding];
		}
	}
	[work commit];
	[work waitUntilCompleted];
	BOOL success=copied && work.status==MTLCommandBufferStatusCompleted && !work.error;
	if (resume) {
		if (tracked) MTL_TargetAdopt(continuation,encoder,&targets);
		else {
			mtl_cb=continuation;
			mtl_enc=encoder;
			mtl_encoder_open=true;
			MTL_HUDApplyClip((int)color.width,(int)color.height);
		}
	}
	return success;
}

/* Registration/unload may release resources already referenced by the current
 * encoder. A failed fence cannot safely allow retirement to continue. Idle
 * calls submit an empty queue barrier, without creating a presentation frame. */
static void
MTL_ModelFence(void)
{
	if (!mtl_queue) return; /* no renderer queue exists during early startup */
	if (!MTL_ReadbackDrain(nil,nil,0)) {
		fprintf(stderr,"ref_metal: could not complete model resource fence\n");
		abort();
	}
}

/* Slot 0xd4: RGBA, opaque alpha, bottom row first; exact GL3 16.16 point
 * increments. No pixels are copied until explicitly requested. The retained
 * last drawable supports save/menu captures outside an active render frame. */
static void
MTL_SoF_ReadThumbnail(unsigned char *out, int width, int height)
{
	if (!out || width<=0 || height<=0 || !mtl_device || !mtl_queue) return;
	if ((size_t)width>SIZE_MAX/4/(size_t)height) return;
	id<MTLTexture> source=MTL_TargetReadableColor();
	if (!source || !source.width || !source.height || source.framebufferOnly) return;
	MTLPixelFormat format=source.pixelFormat;
	BOOL bgra=format==MTLPixelFormatBGRA8Unorm || format==MTLPixelFormatBGRA8Unorm_sRGB;
	BOOL rgba=format==MTLPixelFormatRGBA8Unorm || format==MTLPixelFormatRGBA8Unorm_sRGB;
	if (!bgra && !rgba) return;
	if (source.width>(NSUIntegerMax-255)/4) return;
	NSUInteger rowbytes=(source.width*4+255)&~(NSUInteger)255;
	if (source.height>NSUIntegerMax/rowbytes) return;
	id<MTLBuffer> buffer=[mtl_device newBufferWithLength:rowbytes*source.height options:MTLResourceStorageModeShared];
	if (!buffer || !MTL_ReadbackDrain(source,buffer,rowbytes)) return;
	const unsigned char *pixels=(const unsigned char *)buffer.contents;
	if (!pixels) return;
	uint64_t sx=((uint64_t)source.width<<16)/(unsigned)width;
	uint64_t sy=((uint64_t)source.height<<16)/(unsigned)height;
	for (int y=0; y<height; y++) {
		NSUInteger srcy=source.height-1-(NSUInteger)(((uint64_t)y*sy)>>16);
		const unsigned char *row=pixels+srcy*rowbytes;
		for (int x=0; x<width; x++) {
			const unsigned char *p=row+(((uint64_t)x*sx)>>16)*4;
			unsigned char *d=out+((size_t)y*width+x)*4;
			d[0]=p[bgra?2:0]; d[1]=p[1]; d[2]=p[bgra?0:2]; d[3]=255;
		}
	}
}
