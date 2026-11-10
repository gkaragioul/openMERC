// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-002 native renderer language compatibility.
// The renderer is GNU Objective-C11; GPU harnesses additionally use C++17.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdio.h>
#include <stdlib.h>
static id<MTLDevice> mtl_device;
static CAMetalLayer *mtl_layer;
static id<MTLCommandBuffer> mtl_cb;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<CAMetalDrawable> mtl_drawable,mtl_last_drawable;
static int mtl_encoder_open;
typedef struct {float value;} cvar_t;
static struct {cvar_t *(*Cvar_Get)(const char*,const char*,int);} ri;
static cvar_t *mtl_fullbright_cvar;
static struct {int rdflags;} mtl_refdef;
static void *mtl_worldmodel;
#define CVAR_ARCHIVE 1
#define RDF_NOWORLDMODEL 2
#define RDF_IRGOGGLES 4
static void MTL_Fatal(const char *s,const char *e){(void)s;(void)e;abort();}
#include "../mtl_targets.h"
#include "../mtl_emission_state.h"
#include "../mtl_post.h"
#include "../mtl_post_overlay.h"
