
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef int jint; typedef long long jlong; typedef void JNIEnv; typedef void *jclass;
#define JNIEXPORT
#define JNICALL
#define AHARDWAREBUFFER_FORMAT_R10G10B10A2_UNORM 43
static void ANativeWindow_release(void *w){}
typedef int EGLint; typedef int EGLConfig; typedef int EGLNativeWindowType;
typedef struct {int dataspace;} ANativeWindow;
struct priv {int egl_display,egl_context,egl_surface,gl;};
struct yingyu_hdr_priv {struct priv egl; ANativeWindow *window;};
struct options {int WinID;}; struct vo {struct options *opts;};
struct fns {const char *name;};
struct ra_ctx {void *priv;struct fns *fns;struct vo *vo;void *log;};
struct mpegl_cb {int (*refine_config)(void*, EGLConfig*,int);void *user_data;};
struct ra_gl_ctx_params {void (*swap_buffers)(void);};
#define talloc_zero(a,T) calloc(1,sizeof(T))
#define EGL_GL_COLORSPACE_BT2020_PQ_EXT 0x3340
#define EGL_GL_COLORSPACE_BT2020_HLG_EXT 0x3540
#define ADATASPACE_BT2020_PQ 163971072
#define ADATASPACE_BT2020_HLG 168165376
#define EGL_DEFAULT_DISPLAY 0
#define EGL_EXTENSIONS 1
#define EGL_NATIVE_VISUAL_ID 2
#define EGL_GL_COLORSPACE_KHR 3
#define EGL_NONE 0
#define EGL_NO_SURFACE 0
#define RTLD_DEFAULT ((void*)0)
#define RTLD_NOW 2
#define RTLD_LOCAL 0
static int global_api,local_api=1,failed_set,wrong_get,uninit_count,space_seen,opens,closes;
static ANativeWindow window;
static char stage[80];
#define MP_INFO(...) ((void)0)
#define MP_ERR(ctx,fmt,s,egl) snprintf(stage,sizeof(stage),"%s;egl=%x",s,egl)
static ANativeWindow *yingyu_hdr_acquire(int id){return &window;}
static int eglGetDisplay(int id){return 1;}
static int eglInitialize(int d,void*a,void*b){return 1;}
static const char *eglQueryString(int d,int a){return "EGL_KHR_gl_colorspace EGL_EXT_gl_colorspace_bt2020_pq EGL_EXT_gl_colorspace_bt2020_hlg";}
static bool yingyu_egl_extension(const char*s,const char*n){return strstr(s,n)!=NULL;}
static int yingyu_hdr_config(void*p,EGLConfig*c,int n){return 0;}
static int mpegl_create_context_cb(struct ra_ctx*c,int d,struct mpegl_cb cb,int *context,EGLConfig *config){*context=1;*config=1;return 1;}
static int eglGetConfigAttrib(int d,int c,int a,int*v){*v=43;return 1;}
static int ANativeWindow_setBuffersGeometry(ANativeWindow*w,int x,int y,int format){return 0;}
static int32_t set_space(ANativeWindow*w,int32_t s){if(failed_set)return -22;w->dataspace=s;return 0;}
static int32_t get_space(ANativeWindow*w){return wrong_get?0:w->dataspace;}
static void *dlopen(const char *name,int flags){opens++;return local_api?(void*)1:NULL;}
static int dlclose(void *handle){closes++;return 0;}
static void *dlsym(void *handle,const char*name){
 if (!(handle?local_api:global_api))return NULL;
 return strstr(name,"setBuffersDataSpace")?(void*)set_space:(void*)get_space;
}
static int eglCreateWindowSurface(int d,int c,EGLNativeWindowType w,const int*a){space_seen=a[1];return 1;}
static int eglQuerySurface(int d,int s,int a,int*v){*v=space_seen;return 1;}
static int eglMakeCurrent(int a,int b,int c,int d){return 1;}
static void mpegl_load_functions(void*g,void*log){}
static void android_swap_buffers(void){}
static bool ra_gl_ctx_init(struct ra_ctx*c,void*g,struct ra_gl_ctx_params p){return true;}
static unsigned eglGetError(void){return 0x3000;}
static void yingyu_hdr_uninit(struct ra_ctx*c){uninit_count++;}
