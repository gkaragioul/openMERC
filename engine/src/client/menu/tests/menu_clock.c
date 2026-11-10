// SPDX-License-Identifier: GPL-2.0-or-later
// Production functions use controlled OS/cvar/render boundaries, no game/window.
// Catches clocks which freeze only drawing, creation or rotation independently.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>
#include <limits.h>
#define MAX_QPATH 64
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
typedef bool qboolean;
typedef unsigned char byte;
typedef struct { float value; int modified; } cvar_t;
typedef struct { bool ready; } mscreen_t;
typedef struct { mscreen_t *screen; } mpage_t;
typedef struct {} mwidget_t;
typedef struct {} mgmodel_t;
typedef struct mmodel_s mmodel_t;
enum { key_game, key_menu };
static struct {
    bool active,forced,drawing;
    int now,created,lastpop,cursorv,depth,framecount;
    void *capture,*tipwidget,*lasthover;
    float mx,my;
    mscreen_t *stack[32];
} ms;
static struct { int key_dest; } cls;
static struct { int width,height; } viddef={640,480};
static int m_layoutw=640,m_layouth=480,m_layoutaspect=1,m_layoutrail,m_layoutwide;
static float m_layoutscale=1;
static cvar_t mousex,mousey,*menu_mouse_x=&mousex,*menu_mouse_y=&mousey;
static cvar_t selected={-1,0};
static int walltime,registered,registration_flags=-1;
static bool registration_default;
static bool m_hasthumb;
static byte m_thumb[128*128*4];
static mscreen_t screen;
static int drawn_begin,drawn_end;
static bool change_during_draw;
static float played_time,angles[3];
static int play_calls,failures,checks;
static int M_Time(void);
static int Sys_Milliseconds(void) { return walltime; }
static cvar_t *Cvar_Get(const char *name,const char *value,int flags)
{
    if(strcmp(name,"om_menutesttime")) abort();
    registered++; registration_flags=flags; registration_default=!strcmp(value,"-1");
    return &selected;
}
static float Cvar_VariableValue(const char *name) { return 0; }
static void Cvar_SetValue(const char *name,float value) {}
static void Cvar_Set(const char *name,const char *value) {}
static void S_StopAllSounds(void) {}
static int Com_ServerState(void) { return 0; }
static bool MR_Thumbnail(byte *pixels) { return false; }
static int MR_VirtualW(void) { return 640; }
static int MR_VirtualH(void) { return 480; }
static void M_FreeScreen(mscreen_t *scr) {}
static mscreen_t *M_TopScreen(void) { return &screen; }
static bool SCR_AspectCorrect(void) { return true; }
static float MR_Scale(void) { return 1; }
static bool MR_RailShown(void) { return false; }
static bool MWD_Enabled(void) { return false; }
static void M_RebuildScreens(void) {}
static void M_ClampPointer(void) {}
static void MR_BeginFrame(void) { drawn_begin=M_Time(); }
static void M_DrawScreen(mscreen_t *scr,bool input)
{
    walltime+=77;
    if(change_during_draw) selected.value=1750;
    drawn_end=M_Time();
}
static void MR_EndFrame(void) {}
static void MT_FrameEnd(void) {}
static void MS_ServerFrame(void) {}
static void M_RunQueue(void) {}
static void MT_Frame(bool drawn) {}
static void MG_Play(mgmodel_t *g,float now,int mode,float offset)
{ played_time=now; play_calls++; }
static void MG_SetTransform(mgmodel_t *g,float scale,float a[3])
{ memcpy(angles,a,sizeof(angles)); }
static void MG_ProcessEvents(mgmodel_t *g,float now) {}
static void MM_ScreenPoint(mmodel_t *m) {}
#include "menu_clock_production.h"

static void check(bool pass,const char *label)
{ checks++; if(!pass) { failures++; fprintf(stderr,"FAIL: %s\n",label); } }
int main(void)
{
    walltime=100; check(M_Time()==100,"default clock reads current wall time");
    walltime=110; check(M_Time()==110,"default clock advances normally");
    check(registered>0 && registration_flags==0 && registration_default,"test clock is registered disabled and nonarchived");
    ms.drawing=true; ms.now=105; check(M_Time()==105,"normal drawing retains frame snapshot"); ms.drawing=false;
    selected.value=1250; check(M_Time()==1250,"fixed clock selected outside drawing");
    walltime=9000; check(M_Time()==1250,"fixed clock ignores elapsed OS time");
    M_CreateSystem(); check(ms.created==1250 && ms.lastpop==1250,"menu creation uses selected clock");
    ms.depth=1; ms.stack[0]=&screen; M_PopTop(); check(ms.lastpop==1250,"menu pop uses selected clock");
    M_Draw(); check(drawn_begin==1250 && drawn_end==1250 && ms.now==1250,"draw/update clock stays fixed throughout frame");
    check(!ms.drawing,"drawing releases snapshot after frame");
    change_during_draw=true; M_Draw();
    check(drawn_begin==1250 && drawn_end==1250,"fixed clock change waits for next draw snapshot");
    check(M_Time()==1750,"outside drawing immediately uses changed fixed clock");
    change_during_draw=false; M_Draw(); check(drawn_begin==1750 && drawn_end==1750,"next frame selects new fixed time");
    selected.value=0; check(M_Time()==0,"zero is a valid fixed test timestamp");
    selected.value=-2; walltime=9200; check(M_Time()==9200,"any negative value disables fixed clock");
    selected.value=-1; walltime=9300; M_Draw();
    check(drawn_begin==9300 && drawn_end==9300,"unfreeze returns to advancing wall-clock snapshots");
    walltime=9400; check(M_Time()==9400,"normal clock resumes outside frame");
    selected.value=NAN; check(M_Time()==9400,"NaN uses normal clock");
    selected.value=INFINITY; check(M_Time()==9400,"out-of-range clock uses normal clock");
    selected.value=1250;
    mmodel_t model={0}; mgmodel_t dummy; model.g=&dummy; model.parent=&model; model.hastime=true; model.time=.375f;
    model.rotation[0]=1; model.rotation[1]=2; model.rotation[2]=3;
    model.rotate[0]=.001f; model.rotate[1]=.002f; model.rotate[2]=-.001f;
    MM_Update(&model);
    check(play_calls==1 && fabsf(played_time-1.25f)<.00001f,"model sequence starts at selected seconds");
    check(fabsf(angles[0]-2.25f)<.00001f && fabsf(angles[1]-4.5f)<.00001f && fabsf(angles[2]-1.75f)<.00001f,
        "all model rotation axes use selected milliseconds");
    walltime=19000; MM_Update(&model);
    check(fabsf(angles[0]-2.25f)<.00001f && play_calls==1,"fixed model pose/rotation survives OS time changes");
    selected.value=-1; walltime=2000; MM_Update(&model); check(fabsf(angles[0]-3.0f)<.00001f,"normal model rotation resumes on unfreeze");
    walltime=3000; MM_Update(&model); check(fabsf(angles[0]-4.0f)<.00001f,"normal model rotation keeps advancing");
    printf("Menu clock checks: %d passed, %d failed\n",checks-failures,failures);
    return failures?1:0;
}
