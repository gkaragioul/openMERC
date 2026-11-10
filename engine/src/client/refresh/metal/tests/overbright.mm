// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-AMEND-016 current GPL overbright controls and draw destinations.
#define ri factory_ri
#define mtl_refdef factory_refdef
#include "overbright_factories_fixture.h"
#undef mtl_refdef
#undef ri
#include <map>
#include <string>
#include <cmath>
#include "overbright_flags.h"
#define DEG2RAD(x) ((x)*0.017453292519943295769f)
#define VectorCopy(a,b) memcpy((b),(a),sizeof(float)*3)
#define VectorClear(a) memset((a),0,sizeof(float)*3)
#define VectorSet(a,x,y,z) ((a)[0]=(x),(a)[1]=(y),(a)[2]=(z))
#define VectorScale(a,s,b) do {for(int v=0;v<3;v++)(b)[v]=(a)[v]*(s);}while(0)
typedef float vec3_t[3];
typedef struct {int flags,frame;float origin[3],angles[3];} entity_t;
typedef struct {float value;int flags;} cvar_t;
static std::map<std::string,cvar_t> cvars;
static cvar_t *get_cvar(const char *name,const char *value,int flags){return &cvars.emplace(name,cvar_t{(float)atof(value),flags}).first->second;}
static struct {cvar_t *(*Cvar_Get)(const char*,const char*,int);} ri={get_cvar};
#define CVAR_ARCHIVE 1
static struct {float time;int rdflags;float vieworg[3],viewangles[3];int num_entities;entity_t *entities;} mtl_refdef;
#if __has_include("../mtl_overbright.h")
#include "../mtl_overbright.h"
#else
// Absent pre-change controls use the actual native route's scale of one.
static void MTL_OverbrightInit(void){}
static float MTL_Overbright(void){return 1;}
static float MTL_OverbrightModels(void){return 1;}
#endif
static const sofrefdef_t *mtl_sof_frame;
static cvar_t fullbright={0},light_multiply={1.3f},light_method={3};
static cvar_t *mtl_fullbright_cvar=&fullbright,*mtl_ghoul_light_multiply_cvar=&light_multiply,*mtl_ghoul_light_method_cvar=&light_method;
static cvar_t *mtl_ghoul_debug_cvar,*mtl_ghoul_specular_cvar,*mtl_ghoul_fast_lights_cvar,*mtl_ghoul_gllight_directional_cvar,*mtl_ghoul_gllight_attenuation_cvar,*mtl_ghoul_gllight_max_lights_cvar,*mtl_ghoul_max_lights_cvar;
static float sampled_light[3]={.2f,.35f,.6f},mtl_ghoul_mvp[16],mtl_ghoul_entity_emission;
static void *mtl_ghoul_system=(void*)1;
static om_ghoul_render_params_t reported_params;
static float MTL_GameTime(void){return mtl_sof_frame?mtl_sof_frame->gametime:mtl_refdef.time;}
static void MTL_SoFLightPoint(const float*,float out[3]){VectorCopy(sampled_light,out);}
static void MTL_ApplyDepthHack(const float *in,float *out){memcpy(out,in,16*sizeof(float));}
static void AngleVectors(const float*,float forward[3],float*,float*){VectorSet(forward,1,0,0);}
extern "C" void *OMGhoul_FindInstance(void*,int){return (void*)1;}
extern "C" void OMGhoul_DrawInstance(void*,const om_ghoul_render_params_t *params){reported_params=*params;}
#include "overbright_production.h"
static cvar_t *r_om_overbright,*r_om_overbright_scale,*r_om_overbright_models;
#define r_newrefdef mtl_refdef
#include "overbright_reference.h"
#undef r_newrefdef
static int checks;
static void test(bool pass,const char *name){checks++;if(!pass){fprintf(stderr,"FAIL overbright: %s\n",name);failures++;}}
static void set(const char *name,float value){get_cvar(name,"0",CVAR_ARCHIVE)->value=value;}
static bool equal3(const float a[3],const float b[3]){for(int i=0;i<3;i++)if(fabsf(a[i]-b[i])>1e-6)return false;return true;}
static id<MTLTexture> image(const unsigned char *bytes,int width=1,MTLPixelFormat format=MTLPixelFormatRGBA8Unorm){auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:1 mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;auto t=[mtl_device newTextureWithDescriptor:d];[t replaceRegion:MTLRegionMake2D(0,0,width,1) mipmapLevel:0 withBytes:bytes bytesPerRow:width*(format==MTLPixelFormatR8Unorm?1:4)];return t;}
static void gpu(int kind,const float color[4],float expected_ob,const char *name,const float expected_color[4]=nullptr){
 bool world=kind==1;
 mtl_test_pipeline_targets={1,1,MTLPixelFormatBGRA8Unorm,MTLPixelFormatInvalid};auto state=world?MTL_BuildWorldPipeline():MTL_BuildAliasPipeline(0,kind==2?2:0);
 auto target=make_target(MTLPixelFormatBGRA8Unorm,1);auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
 pass.depthAttachment.texture=make_target(MTLPixelFormatDepth32Float,1);pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.clearDepth=1;
 auto cb=[queue commandBuffer];auto enc=[cb renderCommandEncoderWithDescriptor:pass];[enc setRenderPipelineState:state];[enc setDepthStencilState:mtl_depth_2d];[enc setCullMode:MTLCullModeNone];
 float identity[16]={};for(int i=0;i<4;i++)identity[i*5]=1;const float xy[3][2]={{-1,-1},{3,-1},{-1,3}};
 mtl_world_vertex_t vertices[3]={};mtl_alias_vertex_t alias[3]={};for(int i=0;i<3;i++){vertices[i].pos[0]=alias[i].pos[0]=xy[i][0];vertices[i].pos[1]=alias[i].pos[1]=xy[i][1];vertices[i].pos[2]=alias[i].pos[2]=.5;vertices[i].uv[0]=vertices[i].uv[1]=vertices[i].luv[0]=vertices[i].luv[1]=alias[i].uv[0]=alias[i].uv[1]=.5;memcpy(alias[i].color,color,4*sizeof(float));}
 [enc setVertexBytes:world?(void*)vertices:(void*)alias length:world?sizeof(vertices):sizeof(alias) atIndex:0];[enc setVertexBytes:identity length:sizeof(identity) atIndex:1];
 const unsigned char diffuse[4]={64,96,128,128},light[4]={64,96,128,255},black[4]={0};
 [enc setFragmentTexture:image(diffuse) atIndex:0];[enc setFragmentSamplerState:mtl_samp_ui atIndex:0];
 if(world){mtl_world_uniform_t u={};memcpy(u.mvp,identity,sizeof(identity));u.overbright=MTL_TestWorldFactor();[enc setVertexBytes:&u length:sizeof(u) atIndex:1];[enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
  float styles[20]={1,1,1};[enc setFragmentBytes:styles length:sizeof(styles) atIndex:3];mtl_post_fragment_uniform_t emission={};[enc setFragmentBytes:&emission length:sizeof(emission) atIndex:4];
  [enc setFragmentTexture:image(light) atIndex:1];for(int i=4;i<8;i++)[enc setFragmentTexture:image(black) atIndex:i];
  unsigned char table[256];for(int i=0;i<256;i++)table[i]=(unsigned char)(i*i/255);[enc setFragmentTexture:image(table,256,MTLPixelFormatR8Unorm) atIndex:2];[enc setFragmentSamplerState:mtl_samp_ui atIndex:1];[enc setFragmentSamplerState:mtl_samp_ui atIndex:2];
 }
 if(kind==2){float cutoff=-1;mtl_post_fragment_uniform_t post={};[enc setFragmentBytes:&cutoff length:sizeof(cutoff) atIndex:2];[enc setFragmentBytes:&post length:sizeof(post) atIndex:3];}
 [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error)MTL_Fatal(name,cb.error.localizedDescription.UTF8String);
 unsigned char bytes[16*16*4];[target getBytes:bytes bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];auto p=bytes+(8*16+8)*4;bool pass_rgb=true;for(int k=0;k<3;k++){float factor=world?(light[k]*light[k]/255)/255.f*expected_ob:(kind==2?(expected_color?expected_color:color)[k]:fminf((expected_color?expected_color:color)[k],1.5f));int expected=(int)lroundf(fminf(diffuse[k]*factor,255));pass_rgb&=abs(p[2-k]-expected)<=1;}test(pass_rgb,name);
 if(kind==0)test(abs(p[3]-(int)lroundf(diffuse[3]*(expected_color?expected_color:color)[3]))<=1,"alias texture alpha uses scaled passColor cap");
}
int main(){@autoreleasepool{
 MTL_OverbrightInit();test(cvars.count("r_om_overbright")&&cvars.count("r_om_overbright_scale")&&cvars.count("r_om_overbright_models"),"controls registered");
 r_om_overbright=get_cvar("r_om_overbright","0",CVAR_ARCHIVE);r_om_overbright_scale=get_cvar("r_om_overbright_scale","2",CVAR_ARCHIVE);r_om_overbright_models=get_cvar("r_om_overbright_models","1",CVAR_ARCHIVE);
 test(r_om_overbright->value==0&&r_om_overbright_scale->value==2&&r_om_overbright_models->value==1&&r_om_overbright->flags==CVAR_ARCHIVE&&r_om_overbright_scale->flags==CVAR_ARCHIVE&&r_om_overbright_models->flags==CVAR_ARCHIVE,"archived defaults match GPL");
 for(float enabled:{0.f,1.f})for(float scale:{-2.f,1.f,2.f,3.5f,8.f})for(int nv:{0,1})for(int models:{0,1}){set("r_om_overbright",enabled);set("r_om_overbright_scale",scale);set("r_om_overbright_models",models);mtl_refdef.rdflags=nv?RDF_IRGOGGLES:0;test(MTL_Overbright()==GL3_Post_Overbright(),"world/alias control equals actual GPL clamp/nightvision");test(MTL_OverbrightModels()==GL3_Post_OverbrightModels(),"Ghoul models control equals actual GPL");}
 set("r_om_overbright",1);set("r_om_overbright_scale",3);set("r_om_overbright_models",1);mtl_refdef.rdflags=0;
 entity_t entities[2]={};mtl_refdef.entities=entities;mtl_refdef.num_entities=2;float out0[3]={-1,-1,-1},out1[3]={-1,-1,-1};sofentity_t se0={},se1={};se0.lightout=out0;se1.lightout=out1;sofentity_t *originals[2]={&se0,&se1};sofrefdef_t sof={};sof.entities=originals;sof.num_entities=2;mtl_sof_frame=&sof;
 float identity[16]={};for(int i=0;i<4;i++)identity[i*5]=1;
 MTL_DrawGhoulEntity(&entities[1],identity);float raw[3],scaled[3];for(int k=0;k<3;k++){raw[k]=sampled_light[k]*1.3f;scaled[k]=raw[k]*3;}
 test(equal3(reported_params.light_color,scaled),"actual Ghoul draw scales only drawing light");test(equal3(out1,raw)&&out0[0]==-1,"actual Ghoul lightout reports unscaled color to matching source entity");
 set("r_om_overbright_models",0);MTL_DrawGhoulEntity(&entities[1],identity);test(equal3(reported_params.light_color,raw),"models0 suppresses Ghoul overbright");
 set("r_om_overbright_models",1);entities[1].flags=RF_FULLBRIGHT;MTL_DrawGhoulEntity(&entities[1],identity);float white[3]={1.3f,1.3f,1.3f};test(equal3(reported_params.light_color,white)&&equal3(out1,white),"entity fullbright excludes Ghoul overbright after light multiply/report");entities[1].flags=0;
 fullbright.value=1;MTL_DrawGhoulEntity(&entities[1],identity);test(equal3(reported_params.light_color,white),"global fullbright excludes Ghoul overbright");fullbright.value=0;
 mtl_refdef.rdflags=RDF_IRGOGGLES;MTL_DrawGhoulEntity(&entities[1],identity);test(equal3(reported_params.light_color,white),"nightvision excludes Ghoul overbright");mtl_refdef.rdflags=0;
 entity_t e={};float shade[3];MTL_AliasShadeLight(&e,shade);float alias_expected[3];for(int k=0;k<3;k++)alias_expected[k]=sampled_light[k]*3;test(equal3(shade,alias_expected),"actual alias light scaled before GPU1.5 clamp");set("r_om_overbright_models",0);MTL_AliasShadeLight(&e,shade);test(equal3(shade,alias_expected),"alias remains independent of Ghoul models control");
 test(MTL_TestAliasAlpha(.8f)==1.5f&&fabsf(MTL_TestAliasAlpha(.2f)-.6f)<1e-6,"actual generic alias alpha scales and caps as GPL passColor");
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 77;queue=[mtl_device newCommandQueue];mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;MTL_TestInitSamplers();auto d=[MTLDepthStencilDescriptor new];d.depthCompareFunction=MTLCompareFunctionAlways;mtl_depth_2d=[mtl_device newDepthStencilStateWithDescriptor:d];
 float colors[4]={shade[0],shade[1],shade[2],MTL_TestAliasAlpha(.8f)};float reference_alias[4]={sampled_light[0]*3,sampled_light[1]*3,sampled_light[2]*3,1.5f};gpu(false,colors,3,"actual alias production shader uses scaled color before clamp",reference_alias);gpu(true,colors,3,"actual world production shader scales AFTER nonlinear color table");
 set("r_om_overbright_models",1);MTL_DrawGhoulEntity(&entities[1],identity);float ghoul_colors[4]={reported_params.light_color[0],reported_params.light_color[1],reported_params.light_color[2],1};float ghoul_expected[4]={scaled[0],scaled[1],scaled[2],1};
 gpu(2,ghoul_colors,3,"actual Ghoul shader receives drawing-only overbright without alias cap",ghoul_expected);
 set("r_om_overbright_models",0);MTL_DrawGhoulEntity(&entities[1],identity);for(int k=0;k<3;k++){ghoul_colors[k]=reported_params.light_color[k];ghoul_expected[k]=raw[k];}gpu(2,ghoul_colors,1,"actual Ghoul shader returns to unscaled model light",ghoul_expected);
 set("r_om_overbright",0);gpu(true,colors,1,"world option off retains authentic table output");set("r_om_overbright",1);mtl_refdef.rdflags=RDF_IRGOGGLES;gpu(true,colors,1,"nightvision world factor remains one");
 printf("Overbright checks: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}}
