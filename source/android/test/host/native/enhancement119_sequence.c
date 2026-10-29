/* Exact production admission and COLOR hook; only allocator/hash IO wrappers.
 * Real pinned libplacebo parses/runs both hooks and emits the final shader.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <windows.h>
#include <bcrypt.h>
#include <libplacebo/dummy.h>
#include <libplacebo/shaders/custom.h>
#include <libplacebo/log.h>
#define MP_ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
struct bstr { unsigned char *start; size_t len; };
#define BSTR_P(x) (int)(x).len,(char*)(x).start
static bool bstr_eatstart0(struct bstr *b,const char *s) {
    size_t n=strlen(s);if(b->len<n||memcmp(b->start,s,n))return false;
    b->start+=n;b->len-=n;return true;
}
static bool bstr_split_tok(struct bstr b,const char *s,struct bstr *a,struct bstr *r) {
    size_t n=strlen(s);for(size_t i=0;i+n<=b.len;i++)if(!memcmp(b.start+i,s,n)){
        *a=(struct bstr){b.start,i};*r=(struct bstr){b.start+i+n,b.len-i-n};return true;
    }return false;
}
#define talloc_zero(parent,type) ((type*)calloc(1,sizeof(type)))
static char *talloc_asprintf(void *parent,const char *fmt,...) {
    va_list a,b;va_start(a,fmt);va_copy(b,a);int n=vsnprintf(NULL,0,fmt,b);va_end(b);
    char *p=malloc(n+1);vsnprintf(p,n+1,fmt,a);va_end(a);return p;
}
struct AVSHA {BCRYPT_ALG_HANDLE alg;BCRYPT_HASH_HANDLE hash;};
static struct AVSHA *av_sha_alloc(void){return calloc(1,sizeof(struct AVSHA));}
static int av_sha_init(struct AVSHA *s,int bits) {
    return bits!=256 || BCryptOpenAlgorithmProvider(&s->alg,BCRYPT_SHA256_ALGORITHM,NULL,0) || BCryptCreateHash(s->alg,&s->hash,NULL,0,NULL,0,0);
}
static void av_sha_update(struct AVSHA *s,const unsigned char *p,size_t n){if(BCryptHashData(s->hash,(PUCHAR)p,(ULONG)n,0))abort();}
static void av_sha_final(struct AVSHA *s,unsigned char *out){if(BCryptFinishHash(s->hash,out,32,0))abort();BCryptDestroyHash(s->hash);BCryptCloseAlgorithmProvider(s->alg,0);}
static void av_free(void *p){free(p);}
/* PRODUCTION_HEADER */
static int allocations;
static pl_tex deny_extra(void *p,int w,int h){allocations++;return NULL;}

#include <libplacebo/opengl.h>
#include <libplacebo/renderer.h>
#include <math.h>
struct seen {char text[8192];};
static void capture(void *priv,const struct pl_render_info *info) {
    struct seen *s=priv;
    size_t n=strlen(s->text);
    snprintf(s->text+n,sizeof(s->text)-n,"[%d:%d] %s\n",info->stage,info->index,info->pass->shader->description);
}
__declspec(dllexport) int sequence(void *proc,const char *dir,const char *report) {
    FILE *f=fopen(report,"w");
    pl_log log=pl_log_create(PL_API_VER,pl_log_params(.log_cb=pl_log_simple,.log_priv=stderr,.log_level=PL_LOG_WARN));
    pl_opengl gl=pl_opengl_create(log,pl_opengl_params(.get_proc_addr=(pl_voidfunc_t(*)(const char*))proc,.allow_software=true,.max_glsl_version=300));
    if(!gl){fprintf(f,"GL unavailable\n");fclose(f);return 1;}
    pl_gpu gpu=gl->gpu;pl_renderer rr=pl_renderer_create(log,gpu);
    pl_fmt fmt=pl_find_named_fmt(gpu,"rgba16f");
    if(!fmt){fprintf(f,"format unavailable\n");fclose(f);return 2;}
    float rgba[16];for(int i=0;i<4;i++){rgba[4*i]=.12;rgba[4*i+1]=.08;rgba[4*i+2]=.04;rgba[4*i+3]=1;}
    pl_tex input=pl_tex_create(gpu,pl_tex_params(.w=2,.h=2,.format=fmt,.sampleable=true,.initial_data=rgba));
    pl_tex output=pl_tex_create(gpu,pl_tex_params(.w=2,.h=2,.format=fmt,.renderable=true));
    if(!input||!output){fprintf(f,"tex unavailable\n");fclose(f);return 3;}
    struct pl_frame src={.num_planes=1,.planes={{.texture=input,.components=3,.component_mapping={0,1,2,3}}},.repr=pl_color_repr_rgb,.color=pl_color_space_monitor};
    struct pl_frame dst=src;dst.planes[0].texture=output;
    struct seen seen={0};struct pl_render_params params=pl_render_default_params;
    params.info_callback=capture;params.info_priv=&seen;
    const struct pl_frame *frames[]={&src};uint64_t signatures[]={1};float timestamps[]={0};
    struct pl_frame_mix mix={.num_frames=1,.frames=frames,.signatures=signatures,.timestamps=timestamps,.vsync_duration=1};
    const char *steps[]={NULL,"bt1886-0-5.hook","bt1886-0-10.hook","bt1886-0-15.hook",NULL,"bt1886-25-0.hook","bt1886-75-0.hook",NULL,"bt1886-50-0.hook","bt1886-25-0.hook","bt1886-75-0.hook","bt1886-50-0.hook"};
    for(int i=0;i<12;i++) {
        const struct pl_hook *hook=NULL;char *tagged=NULL;
        if(steps[i]) {
            char path[1024];snprintf(path,sizeof(path),"%s/%s",dir,steps[i]);FILE *shader=fopen(path,"rb");if(!shader)return 4;
            fseek(shader,0,SEEK_END);long n=ftell(shader);rewind(shader);char *text=calloc(n+1,1);fread(text,1,n,shader);fclose(shader);
            char *desc=strstr(text,"//!DESC "),*body=strchr(desc,'\n')+1;
            size_t prefix=desc-text;const char *marker="//!DESC Yingyu Dolby enhancement v1\n";
            tagged=calloc(prefix+strlen(marker)+strlen(body)+1,1);memcpy(tagged,text,prefix);strcat(tagged,marker);strcat(tagged,body);
            hook=yy_dolby_enhance_parse(NULL,(struct bstr){(unsigned char*)tagged,strlen(tagged)});if(!hook)return 5;
        }
        params.hooks=&hook;params.num_hooks=!!hook;seen.text[0]=0;
        bool ok=pl_render_image_mix(rr,&mix,&dst,&params);
        float pixels[16]={0}; bool read=true;
        pl_voidfunc_t(*get)(const char*)=(pl_voidfunc_t(*)(const char*))proc;
        unsigned texture=pl_opengl_unwrap(gpu,output,NULL,NULL,NULL),fbo; int before=0;
        ((void(*)(unsigned,int*))get("glGetIntegerv"))(0x8ca6,&before);
        ((void(*)(int,unsigned*))get("glGenFramebuffers"))(1,&fbo);
        ((void(*)(unsigned,unsigned))get("glBindFramebuffer"))(0x8d40,fbo);
        ((void(*)(unsigned,unsigned,unsigned,unsigned,int))get("glFramebufferTexture2D"))(0x8d40,0x8ce0,0x0de1,texture,0);
        ((void(*)(int,int,int,int,unsigned,unsigned,void*))get("glReadPixels"))(0,0,2,2,0x1908,0x1406,pixels);
        ((void(*)(unsigned,unsigned))get("glBindFramebuffer"))(0x8d40,before);
        ((void(*)(int,const unsigned*))get("glDeleteFramebuffers"))(1,&fbo);
        if (!ok || pl_renderer_get_errors(rr).errors ||
            ((i==0 || i==4 || i==7) ? fabs(pixels[0]-.12)>.001 : pixels[0]<=.125)) return 9;
        if (hook && !strstr(seen.text,((struct yy_dolby_enhance*)hook->priv)->description)) return 10;
        fprintf(f,"step=%d shader=%s ok=%d read=%d rgb=%f,%f,%f,%f errors=%u\n%s\n",i,steps[i]?steps[i]:"off",ok,read,pixels[0],pixels[1],pixels[2],pixels[3],pl_renderer_get_errors(rr).errors,seen.text);
        fflush(f);
    }
    fclose(f);pl_tex_destroy(gpu,&input);pl_tex_destroy(gpu,&output);pl_renderer_destroy(&rr);pl_opengl_destroy(&gl);pl_log_destroy(&log);return 0;
}
