// SPDX-License-Identifier: GPL-2.0-or-later
// Native Metal SoF HUD primitives. Included by mtl_main.m after the frame path.
// Implements: SPEC-002 2D/font slots, SPEC-412 sections 3/4/5/6, SPEC-132.

#include <math.h>
#include <stdint.h>

#define MTL_HUD_MENU_FOUNDATION 1

typedef struct { char name[MAX_QPATH]; mtl_image_t *image; } mtl_hud_image_t;
static mtl_hud_image_t mtl_hud_images[512];
static int mtl_hud_numimages;
static float mtl_hud_scale = 1;
static BOOL mtl_hud_blend;
static BOOL mtl_hud_raw_linear=YES;
static void MTL_HUDSetRawLinear(BOOL linear) { mtl_hud_raw_linear=linear; }
static void MTL_SoF_HUDResetState(void) { mtl_hud_blend=NO; }
/* The engine-facing cvar hook avoids coupling this drawing code to cvar_t.
 * Feed gl_scissor_broken at BeginFrame/Set2D. Changing it does not itself
 * alter the existing clip: SPEC-412 makes the five operations no-ops. */
static BOOL mtl_hud_scissor_broken;
static BOOL mtl_hud_clipenabled;
static int mtl_hud_clipx, mtl_hud_clipy, mtl_hud_clipw, mtl_hud_cliph;
static int mtl_hud_clip_targetw, mtl_hud_clip_targeth;
/* Physical endpoints are captured when a clip operation executes. A later
 * scale change must not move the already active hardware rectangle. */
static double mtl_hud_scissor[4];
static void MTL_HUDSetScissorBroken(float value) { mtl_hud_scissor_broken=value!=0; }

/* Reapply on every newly created encoder (including readback continuation).
 * Metal's origin is top-left, unlike glScissor: no y inversion here. */
static void
MTL_HUDApplyClip(int width, int height)
{
	mtl_hud_clip_targetw = width;
	mtl_hud_clip_targeth = height;
	if (!mtl_encoder_open || width <= 0 || height <= 0) return;
	double x0=0, y0=0, x1=width, y1=height;
	if (mtl_hud_clipenabled) {
		x0=fmin(width,fmax(0,mtl_hud_scissor[0]));
		y0=fmin(height,fmax(0,mtl_hud_scissor[1]));
		x1=fmin(width,fmax(x0,mtl_hud_scissor[2]));
		y1=fmin(height,fmax(y0,mtl_hud_scissor[3]));
	}
	MTLScissorRect rect = {(NSUInteger)x0,(NSUInteger)y0,
		(NSUInteger)(x1-x0),(NSUInteger)(y1-y0)};
	[mtl_enc setScissorRect:rect];
#ifdef OM_METAL_TARGETS
	MTL_TargetRecordScissor(rect);
#endif
}
static void
MTL_HUDUpdateClip(void)
{
	MTL_HUDApplyClip(mtl_hud_clip_targetw>0?mtl_hud_clip_targetw:(int)mtl_ui_w,
		mtl_hud_clip_targeth>0?mtl_hud_clip_targeth:(int)mtl_ui_h);
}
static void
MTL_HUDScissor(double left, double right, double top, double bottom)
{
	mtl_hud_scissor[0]=floor(left*mtl_hud_scale+0.5);
	mtl_hud_scissor[1]=floor(top*mtl_hud_scale+0.5);
	mtl_hud_scissor[2]=floor(right*mtl_hud_scale+0.5);
	mtl_hud_scissor[3]=floor(bottom*mtl_hud_scale+0.5);
}
static void
MTL_HUDSetClipRect(int x, int y, int w, int h)
{
	if (mtl_hud_scissor_broken || w<0 || h<0) return;
	mtl_hud_clipx=x; mtl_hud_clipy=y; mtl_hud_clipw=w; mtl_hud_cliph=h;
	MTL_HUDScissor(x,(double)x+w,y,(double)y+h);
	mtl_hud_clipenabled=YES;
	MTL_HUDUpdateClip();
}
static void
MTL_HUDResetClipRect(void)
{
	if (mtl_hud_scissor_broken) return;
	mtl_hud_clipx=mtl_hud_clipy=0;
	mtl_hud_clipw=(int)mtl_ui_w; mtl_hud_cliph=(int)mtl_ui_h;
	mtl_hud_clipenabled=NO;
	MTL_HUDScissor(0,mtl_hud_clipw,0,mtl_hud_cliph);
	MTL_HUDUpdateClip();
}
static void
MTL_HUDClipRightTo(int x)
{
	if (mtl_hud_scissor_broken || x<mtl_hud_clipx) return;
	MTL_HUDScissor(mtl_hud_clipx,x,mtl_hud_clipy,(double)mtl_hud_clipy+mtl_hud_cliph);
	MTL_HUDUpdateClip();
}
static void
MTL_HUDClipLeftFrom(int x)
{
	if (mtl_hud_scissor_broken || x<mtl_hud_clipx) return;
	MTL_HUDScissor(x,(double)mtl_hud_clipx+mtl_hud_clipw,mtl_hud_clipy,(double)mtl_hud_clipy+mtl_hud_cliph);
	MTL_HUDUpdateClip();
}
static void
MTL_HUDReapplyClipRect(void)
{
	if (mtl_hud_scissor_broken) return;
	MTL_HUDScissor(mtl_hud_clipx,(double)mtl_hud_clipx+mtl_hud_clipw,
		mtl_hud_clipy,(double)mtl_hud_clipy+mtl_hud_cliph);
	MTL_HUDUpdateClip();
}
static byte mtl_hud_fontcolor[4] = {255,255,255,255};
static const byte mtl_hud_textcolors[32][4] = {
	{0,0,0,0}, {255,255,255,255}, {255,0,0,255}, {0,255,0,255},
	{255,255,0,255}, {0,0,255,255}, {255,0,255,255}, {0,255,255,255},
	{0,0,0,255}, {127,127,127,127}, {0,0,0,0}, {127,0,0,127},
	{0,127,0,127}, {0,0,0,0}, {127,127,0,127}, {0,0,127,127},
	{86,77,40,127}, {76,94,54,127}, {55,111,101,127}, {0,85,114,255},
	{84,100,126,255}, {30,42,99,191}, {102,9,123,255}, {112,94,97,255},
	{152,0,83,255}, {150,0,24,255}, {112,45,7,255}, {84,73,42,255},
	{97,169,151,255}, {203,143,57,255}, {207,131,22,255}, {255,128,32,255}
};

typedef struct { float st[4]; int width, height, baseline; } mtl_hud_glyph_t;
typedef struct {
	const char *name, *file;
	int end, lineheight, ascent, count;
	qboolean loaded;
	mtl_image_t *page;
	mtl_hud_glyph_t glyphs[224];
} mtl_hud_font_t;
static mtl_hud_font_t mtl_hud_fonts[4] = {
	{"small", "pics/menus/fonts/font1", 256, 10, 8},
	{"medium", "pics/menus/fonts/font4", 256, 12, 10},
	{"title", "pics/menus/fonts/font2", 256, 18, 14},
	{"interface", "pics/menus/fonts/inttext", 64, 32, 24}
};

/* Disk and dynamic images share canonical names, including the optional
 * .m32 suffix. This also makes font-page invalidation work through aliases. */
static qboolean
MTL_HUDImageName(const char *name, char path[MAX_QPATH])
{
	if (!name || !*name) return false;
	const char *base=(*name=='/' || *name=='\\')?name+1:name;
	/* RLabs: ghoul/ textures too (the original main menu's metal plates, play-test 2026-11-05) */
	const char *prefix=(!strncmp(base,"pics/",5) || !strncmp(base,"ghoul/",6))?"":"pics/";
	const char *suffix=*COM_FileExtension(base)?"":".m32";
	if (!*base || strlen(prefix)+strlen(base)+strlen(suffix)>=MAX_QPATH) return false;
	Com_sprintf(path,MAX_QPATH,"%s%s%s",prefix,base,suffix);
	return true;
}
static int
MTL_HUDImageIndex(const char *path)
{
	for (int i=0; i<mtl_hud_numimages; i++)
		if (!strcmp(path,mtl_hud_images[i].name)) return i;
	return -1;
}
static void
MTL_HUDInvalidateFont(const char *path, mtl_image_t *old)
{
	for (int i=0; i<4; i++) {
		char fontpath[MAX_QPATH];
		MTL_HUDImageName(mtl_hud_fonts[i].file,fontpath);
		if (!strcmp(path,fontpath) || (old && mtl_hud_fonts[i].page==old)) {
			mtl_hud_fonts[i].page=NULL;
			mtl_hud_fonts[i].loaded=false;
		}
	}
}
static void
MTL_HUDFreeImage(mtl_image_t *image)
{
	if (!image) return;
	if (image->tex) CFRelease(image->tex);
	free(image);
}

static mtl_image_t *
MTL_HUDPic(const char *name)
{
	char path[MAX_QPATH];
	if (!MTL_HUDImageName(name,path)) return NULL;
	/* Preserve an exact registered key before trying its disk-path alias. */
	int existing=MTL_HUDImageIndex(name);
	if (existing<0) existing=MTL_HUDImageIndex(path);
	if (existing>=0) return mtl_hud_images[existing].image;
	if (mtl_hud_numimages==512) return NULL;
	mtl_image_t *image = (mtl_image_t *)MTL_FindImage(path, it_pic);
	mtl_hud_image_t *entry = &mtl_hud_images[mtl_hud_numimages++];
	Q_strlcpy(entry->name, path, sizeof(entry->name));
	entry->image = image;
	if (!image) Com_Printf("ref_metal: can't find HUD pic: %s\n", name);
	return image;
}

static void
MTL_HUDUnregisterPic(char *name)
{
	char path[MAX_QPATH];
	if (!MTL_HUDImageName(name,path)) return;
	int i=MTL_HUDImageIndex(path);
	if (i<0) return;
	MTL_HUDInvalidateFont(path,mtl_hud_images[i].image);
	MTL_HUDFreeImage(mtl_hud_images[i].image);
	memmove(&mtl_hud_images[i],&mtl_hud_images[i+1],
		(size_t)(mtl_hud_numimages-i-1)*sizeof(mtl_hud_images[0]));
	memset(&mtl_hud_images[--mtl_hud_numimages],0,sizeof(mtl_hud_images[0]));
}

/* New uploads are installed only once their texture succeeds: a malformed
 * upload or allocation failure preserves the previous usable image. Raw
 * SPEC-002 images store RGB; OpenMerc alpha atlases retain all four bytes. */
static int
MTL_HUDUpload(const char *name, int w, int h, const byte *rgba, BOOL alpha)
{
	char path[MAX_QPATH];
	if (!MTL_HUDImageName(name,path) || !rgba || w<=0 || h<=0 || w>65535 || h>65535) return 0;
	int i=MTL_HUDImageIndex(path);
	if (i<0 && mtl_hud_numimages==512) return 0;
	if ((size_t)w>SIZE_MAX/4/(size_t)h) return 0;
	size_t size=(size_t)w*h*4;
	byte *rgb=NULL;
	if (!alpha) {
		rgb=(byte *)malloc(size);
		if (!rgb) return 0;
		memcpy(rgb,rgba,size);
		for (size_t p=3; p<size; p+=4) rgb[p]=255;
	}
	MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:(NSUInteger)w height:(NSUInteger)h mipmapped:NO];
	td.storageMode=MTLStorageModeShared;
	id<MTLTexture> tex=[mtl_device newTextureWithDescriptor:td];
	if (!tex) { free(rgb); return 0; }
	[tex replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:rgb?rgb:rgba bytesPerRow:(NSUInteger)w*4];
	free(rgb);
	mtl_image_t *image=(mtl_image_t *)calloc(1,sizeof(*image));
	if (!image) return 0;
	Q_strlcpy(image->name,path,sizeof(image->name));
	image->width=w; image->height=h; image->type=it_pic; image->sh=image->th=1;
	image->has_alpha=alpha;
	image->raw_image=!alpha;
	image->tex=(void *)CFBridgingRetain(tex);
	if (i<0) {
		i=mtl_hud_numimages++;
		Q_strlcpy(mtl_hud_images[i].name,path,sizeof(mtl_hud_images[i].name));
	}
	MTL_HUDInvalidateFont(path,mtl_hud_images[i].image);
	MTL_HUDFreeImage(mtl_hud_images[i].image);
	mtl_hud_images[i].image=image;
	return 1;
}
static void MTL_HUDSetRawImage(char *name, int w, int h, byte *rgba)
{
	MTL_HUDUpload(name,w,h,rgba,NO);
}
Q2_DLL_EXPORTED int OM_SetAlphaImage(const char *name, int w, int h, const byte *rgba)
{
	char path[MAX_QPATH];
	if (!MTL_HUDImageName(name,path)) return 0;
	if (rgba) MTL_HUDUpload(name,w,h,rgba,YES);
	int i=MTL_HUDImageIndex(path);
	return i>=0 && mtl_hud_images[i].image!=NULL;
}

static void
MTL_HUDCorners(mtl_image_t *image, const float xy[4][2],
	const float st[4][2], const byte *rgba)
{
	static const byte white[4] = {255,255,255,255};
	if (!rgba) rgba = white;
	float c[4];
	for (int i = 0; i < 4; i++) c[i] = rgba[i] / 255.0f;
	const int corners[6] = {0,1,2,0,2,3};
	mtl_vertex_t v[6];
	for (int i = 0; i < 6; i++) {
		int k = corners[i];
		v[i] = (mtl_vertex_t){xy[k][0]*mtl_hud_scale, xy[k][1]*mtl_hud_scale,
			st[k][0], st[k][1], c[0],c[1],c[2],c[3]};
	}
	BOOL linear=image && image->raw_image ? mtl_hud_raw_linear : mtl_hud_scale!=floorf(mtl_hud_scale);
	MTL_SubmitQuad(v, image ? (__bridge id<MTLTexture>)image->tex : mtl_white, NO, YES, mtl_hud_blend, linear);
}

static void
MTL_HUDQuad(mtl_image_t *image, float x, float y, float w, float h,
	const float st[4][2], const byte *rgba)
{
	const float xy[4][2]={{x,y},{x+w,y},{x+w,y+h},{x,y+h}};
	MTL_HUDCorners(image,xy,st,rgba);
}

static void
MTL_HUDRect(mtl_image_t *image, float x, float y, float w, float h,
	float s0, float t0, float s1, float t1, const byte *rgba)
{
	const float st[4][2] = {{s0,t0},{s1,t0},{s1,t1},{s0,t1}};
	MTL_HUDQuad(image,x,y,w,h,st,rgba);
}

static void MTL_HUDUnpack(unsigned rgba, byte c[4])
{
	for (int i = 0; i < 4; i++) c[i] = (rgba >> (8*i)) & 255;
}
static void *MTL_HUDRegisterPic(char *name) { return MTL_HUDPic(name); }
static void MTL_HUDGetPicSize(int *w, int *h, char *name)
{
	mtl_image_t *image = MTL_HUDPic(name);
	*w = image ? image->width : -1; *h = image ? image->height : -1;
}
static void MTL_HUDPicScaled(int x, int y, float sx, float sy, const byte *rgba, char *name)
{
	mtl_image_t *image = MTL_HUDPic(name);
	if (image) {
		mtl_hud_blend=YES;
		MTL_HUDRect(image,x,y,(int)(image->width*sx),(int)(image->height*sy),0,0,1,1,rgba);
		mtl_hud_blend=NO;
	}
}
static void MTL_HUDDrawPic(int x, int y, char *name, unsigned rgba)
{
	mtl_image_t *image=MTL_HUDPic(name); if(!image) return;
	byte c[4]; MTL_HUDUnpack(rgba,c); mtl_hud_blend=YES;
	MTL_HUDRect(image,x,y,image->width,image->height,0,0,1,1,c);
}
static void MTL_HUDPicPart(int x, int y, int l, int t, int r, int b, const byte *rgba, char *name)
{
	mtl_image_t *image = MTL_HUDPic(name);
	if (image && image->width > 0 && image->height > 0) {
		mtl_hud_blend=YES;
		MTL_HUDRect(image,x,y,abs(r-l),abs(b-t),(float)l/image->width,(float)t/image->height,
			(float)r/image->width,(float)b/image->height,rgba);
		mtl_hud_blend=NO;
	}
}
static void MTL_HUDStretch(int x, int y, int w, int h, const byte *rgba, char *name, int rotation)
{
	static const float rotations[8][4][2] = {
		{{0,0},{1,0},{1,1},{0,1}}, {{1,0},{1,1},{0,1},{0,0}},
		{{1,1},{0,1},{0,0},{1,0}}, {{0,1},{0,0},{1,0},{1,1}},
		{{0,0},{1,0},{1,1},{0,1}}, {{1,0},{0,0},{0,1},{1,1}},
		{{0,1},{1,1},{1,0},{0,0}}, {{1,1},{0,1},{0,0},{1,0}}
	};
	mtl_image_t *image = MTL_HUDPic(name);
	if (image) { mtl_hud_blend=YES; MTL_HUDQuad(image,x,y,w,h,rotations[rotation&7],rgba); mtl_hud_blend=NO; }
}
static void MTL_HUDFill(int x, int y, int w, int h, const byte *rgba)
{
	mtl_hud_blend=YES;
	MTL_HUDRect(NULL,x,y,w,h,0,0,1,1,rgba);
	mtl_hud_blend=NO;
}
static void
MTL_HUDLine(float x1, float y1, float x2, float y2, float width, const byte *rgba)
{
	float dx=x2-x1, dy=y2-y1, len=sqrtf(dx*dx+dy*dy), half=width*0.5f;
	if (len>0) { dx/=len; dy/=len; } else { dx=1; dy=0; }
	float nx=-dy, ny=dx;
	const float xy[4][2]={
		{x1-half*dx+half*nx,y1-half*dy+half*ny},
		{x2+half*dx+half*nx,y2+half*dy+half*ny},
		{x2+half*dx-half*nx,y2+half*dy-half*ny},
		{x1-half*dx-half*nx,y1-half*dy-half*ny}};
	const float st[4][2]={{0,0},{1,0},{1,1},{0,1}};
	mtl_hud_blend=YES;
	MTL_HUDCorners(NULL,xy,st,rgba);
	mtl_hud_blend=NO;
}
static void
MTL_HUDBevelBox(int x, int y, int w, int h, const byte *rgba)
{
	static const byte white[4]={255,255,255,255};
	if (!rgba) rgba=white;
	byte dark[4],light[4];
	for (int i=0; i<3; i++) {
		int d=(int)(rgba[i]*0.7f), l=(int)(rgba[i]*1.3f);
		dark[i]=(byte)(d>255?255:d); light[i]=(byte)(l>255?255:l);
	}
	dark[3]=light[3]=rgba[3];
	MTL_HUDFill(x,y,w,h,rgba);
	MTL_HUDLine(x+w,y+h,x+w,y,1,dark);
	MTL_HUDLine(x+w,y+h,x,y+h,1,dark);
	MTL_HUDLine(x,y,x+w,y,1,light);
	MTL_HUDLine(x,y,x,y+h,1,light);
}
static void MTL_HUDFade(const byte *rgba)
{
	mtl_hud_blend=YES;
	MTL_HUDRect(NULL,0,0,mtl_ui_w/mtl_hud_scale,mtl_ui_h/mtl_hud_scale,0,0,1,1,rgba);
	mtl_hud_blend=NO;
}
static void MTL_HUDChar(int x, int y, int ch, const byte *rgba)
{
	ch &= 255;
	if (ch == 32 || y <= -8 || !draw_chars) return;
	float s = (ch&15)/16.0f, t = (ch>>4)/16.0f;
	MTL_HUDRect(draw_chars,x,y,8,8,s,t,s+0.0625f,t+0.0625f,rgba);
}
static void MTL_HUDCharFloat(float x, float y, float scale, const byte *rgba, int ch)
{
	(void)scale; ch &= 255;
	mtl_hud_blend=YES;
	if (ch != 32 && y > -8 && draw_chars) {
		float s = (ch&15)/16.0f, t = (ch>>4)/16.0f;
		MTL_HUDRect(draw_chars,x,y,8,8,s,t,s+0.0625f,t+0.0625f,rgba);
	}
	mtl_hud_blend=NO;
}
static void MTL_HUDString(int x, int y, char *s, unsigned rgba, int maxlen)
{
	byte c[4]; MTL_HUDUnpack(rgba,c);
	for (; s && *s && maxlen != 0; s++, x+=8) {
		MTL_HUDChar(x,y,(byte)*s,c); if (maxlen > 0) maxlen--;
	}
}
static void MTL_HUDConsoleColor(int x, int y, char *s, int maxlen, const byte *rgba)
{
	byte c[4] = {255,255,255,255}; if (rgba) memcpy(c,rgba,4);
	int drawn = 0;
	for (; s && *s && drawn < maxlen; s++) {
		byte ch = (byte)*s;
		if (ch < 32) memcpy(c,mtl_hud_textcolors[ch],4);
		else { MTL_HUDChar(x,y,ch,c); x+=8; drawn++; }
	}
}
static void MTL_HUDConsole(int x, int y, char *s, int maxlen)
{
	MTL_HUDConsoleColor(x,y,s,maxlen,NULL);
}

static mtl_hud_font_t *MTL_HUDFont(const om_fontref_t *ref)
{
	if (!ref || !ref->chars) return NULL;
	for (int i = 0; i < 4; i++) {
		mtl_hud_font_t *f = &mtl_hud_fonts[i];
		if (strcmp(ref->chars,f->name)) continue;
		if (!f->loaded) {
			char path[MAX_QPATH]; byte *data = NULL;
			Com_sprintf(path,sizeof(path),"%s.fnt",f->file);
			int len = ri.FS_LoadFile(path,(void **)&data);
			if (!data || len < 28) {
				if (data) ri.FS_FreeFile(data);
				Com_Error(ERR_FATAL,"Unable to find : %s",path); return NULL;
			}
			f->count = Q_min(len/28,224);
			for (int g = 0; g < f->count; g++) {
				/* File records have a fixed 28-byte stride, independent of host padding. */
				const byte *record = data+28*g;
				for (int k = 0; k < 4; k++) {
					float v; memcpy(&v,record+4*k,4); f->glyphs[g].st[k] = LittleFloat(v);
				}
				int v[3]; memcpy(v,record+16,12);
				f->glyphs[g].width=LittleLong(v[0]); f->glyphs[g].height=LittleLong(v[1]);
				f->glyphs[g].baseline=LittleLong(v[2]);
			}
			ri.FS_FreeFile(data);
			f->page = MTL_HUDPic(f->file);
			if (!f->page) f->page = mtl_notexture;
			f->loaded = true;
		}
		return f;
	}
	return NULL;
}
static const mtl_hud_glyph_t *MTL_HUDGlyph(const mtl_hud_font_t *f, int ch)
{
	if (ch < 32 || ch >= f->end || ch-32 >= f->count) return NULL;
	const mtl_hud_glyph_t *g = &f->glyphs[ch-32];
	return g->width || '.'-32 >= f->count ? g : &f->glyphs['.'-32];
}
static void MTL_HUDFontString(int x, int y, char *text, unsigned rgba, const om_fontref_t *ref, int keep)
{
	mtl_hud_font_t *f = MTL_HUDFont(ref);
	if (!f || !text) return;
	mtl_hud_blend=YES;
	if (!(keep&255)) MTL_HUDUnpack(rgba,mtl_hud_fontcolor);
	int pen = x, baseline = y+f->ascent;
	for (const byte *s = (const byte *)text; *s; s++) {
		if (*s == 10) { baseline+=f->lineheight; pen=x; continue; }
		if (*s == 13) continue;
		if (*s < 32) { memcpy(mtl_hud_fontcolor,mtl_hud_textcolors[*s],4); continue; }
		if (*s == 32) { pen+=f->lineheight/2; continue; }
		const mtl_hud_glyph_t *g = MTL_HUDGlyph(f,*s);
		if (!g) continue;
		if (g->width > 0 && g->height > 0)
			MTL_HUDRect(f->page,pen,baseline-g->baseline,g->width,g->height,
				g->st[0],g->st[1],g->st[2],g->st[3],mtl_hud_fontcolor);
		pen+=g->width;
	}
}
static int MTL_HUDFontWidth(char *text, const om_fontref_t *ref)
{
	mtl_hud_font_t *f = MTL_HUDFont(ref); int w = 0;
	for (const byte *s = (const byte *)text; f && s && *s; s++) {
		if (*s == 32) w+=f->lineheight/2;
		else { const mtl_hud_glyph_t *g=MTL_HUDGlyph(f,*s); if (g) w+=g->width; }
	}
	return w;
}
static int MTL_HUDFontHeight(const om_fontref_t *ref)
{
	mtl_hud_font_t *f = MTL_HUDFont(ref); return f ? f->lineheight : 0;
}
Q2_DLL_EXPORTED void OM_Set2DScale(float scale) { mtl_hud_scale = scale > 0 ? scale : 1; }

static void MTL_SoF_HUDShutdown(void)
{
	for (int i = 0; i < mtl_hud_numimages; i++) {
		mtl_image_t *image = mtl_hud_images[i].image;
		MTL_HUDFreeImage(image);
	}
	memset(mtl_hud_images,0,sizeof(mtl_hud_images)); mtl_hud_numimages=0; mtl_hud_scale=1;
	for (int i = 0; i < 4; i++) { mtl_hud_fonts[i].loaded=false; mtl_hud_fonts[i].page=NULL; }
	memset(mtl_hud_fontcolor,255,4);
	MTL_SoF_HUDResetState();
	mtl_hud_clipenabled=mtl_hud_scissor_broken=NO;
	mtl_hud_clipx=mtl_hud_clipy=mtl_hud_clipw=mtl_hud_cliph=0;
	mtl_hud_clip_targetw=mtl_hud_clip_targeth=0;
	memset(mtl_hud_scissor,0,sizeof(mtl_hud_scissor));
}
static void MTL_SoF_HUDExports(sofrefexport_t *exports)
{
	/* This HUD subset deliberately leaves Set2D unset until native menu-model
 	 * projection and synchronous readback support exists. MR_Re retains its
 	 * software menu backend instead of selecting an incomplete native table. */
	exports->RegisterPic=MTL_HUDRegisterPic;
	exports->DrawGetPicSize=MTL_HUDGetPicSize; exports->DrawPic=MTL_HUDDrawPic;
	exports->DrawPicScaled=MTL_HUDPicScaled; exports->DrawPicPart=MTL_HUDPicPart;
	exports->DrawStretchPic=MTL_HUDStretch; exports->DrawFill=MTL_HUDFill;
	exports->DrawChar=MTL_HUDChar; exports->DrawCharFloat=MTL_HUDCharFloat;
	exports->DrawString=MTL_HUDString; exports->DrawConsoleString=MTL_HUDConsole;
	exports->DrawConsoleStringColor=MTL_HUDConsoleColor; exports->DrawFadeScreen=MTL_HUDFade;
	exports->DrawFontString=MTL_HUDFontString; exports->FontStringWidth=MTL_HUDFontWidth;
	exports->FontLineHeight=MTL_HUDFontHeight;
	exports->DrawLine=MTL_HUDLine; exports->DrawBevelBox=MTL_HUDBevelBox;
	exports->SetClipRect=MTL_HUDSetClipRect; exports->ResetClipRect=MTL_HUDResetClipRect;
	exports->ClipRightTo=MTL_HUDClipRightTo; exports->ClipLeftFrom=MTL_HUDClipLeftFrom;
	exports->ReapplyClipRect=MTL_HUDReapplyClipRect;
	exports->SetRawImage=MTL_HUDSetRawImage; exports->UnregisterPic=MTL_HUDUnregisterPic;
}
