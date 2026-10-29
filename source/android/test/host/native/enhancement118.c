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
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    FILE *f=fopen(argv[1],"rb");if(!f)return 3;fseek(f,0,SEEK_END);long n=ftell(f);rewind(f);char *text=calloc(n+1,1);fread(text,1,n,f);fclose(f);
    struct bstr original={(unsigned char*)text,n};
    /* Ordinary HDR/SDR and every original shader must keep the generic parser. */
    if(yy_dolby_enhance_parse(NULL,original))return 4;
    char *desc=strstr(text,"//!DESC "),*body=strchr(desc,'\n')+1;
    size_t prefix=desc-text;const char *marker="//!DESC Yingyu Dolby enhancement v1\n";
    char *tagged=calloc(prefix+strlen(marker)+strlen(body)+1,1);
    memcpy(tagged,text,prefix);strcat(tagged,marker);strcat(tagged,body);
    struct bstr input={(unsigned char*)tagged,strlen(tagged)};
    const struct pl_hook *gain=yy_dolby_enhance_parse(NULL,input);
    if(!gain||gain->input!=PL_HOOK_SIG_COLOR||gain->stages!=PL_HOOK_OUTPUT)return 5;
    pl_log log=pl_log_create(PL_API_VER,pl_log_params(.log_level=PL_LOG_NONE));
    struct pl_gpu_dummy_params caps=pl_gpu_dummy_default_params;
    caps.glsl.version=300;caps.glsl.gles=true;caps.glsl.compute=false;
    pl_gpu gpu=pl_gpu_dummy_create(log,&caps);pl_dispatch dp=pl_dispatch_create(log,gpu);
    pl_tex tex=pl_tex_create(gpu,pl_tex_params(.w=16,.h=16,.format=pl_find_fmt(gpu,PL_FMT_FLOAT,4,16,0,PL_FMT_CAP_SAMPLEABLE),.sampleable=true));
    struct pl_color_space color=pl_color_space_monitor;struct pl_color_repr repr=pl_color_repr_rgb;
    struct pl_hook_params p={.gpu=gpu,.dispatch=dp,.get_tex=deny_extra,.stage=PL_HOOK_OUTPUT,.tex=tex,.rect={0,0,16,16},.color=color,.repr=repr,.orig_color=&color,.orig_repr=&repr,.components=3,.src_rect={0,0,16,16},.dst_rect={0,0,16,16}};
    const struct pl_hook *old=pl_mpv_user_shader_parse(gpu,text,n);
    struct pl_hook_res prior=old->hook(old->priv,&p);
    if(!prior.failed||allocations!=1)return 6;
    allocations=0;
    p.sh=pl_shader_alloc(log,pl_shader_params(.gpu=gpu));
    if(!pl_shader_custom(p.sh,&(struct pl_custom_shader){.input=PL_SHADER_SIG_NONE,.output=PL_SHADER_SIG_COLOR,.header="uniform vec4 yy_input;",.body="color = yy_input;"}))return 7;
    struct pl_hook_res result=gain->hook(gain->priv,&p);
    if(result.failed||allocations||result.output!=PL_HOOK_SIG_COLOR)return 8;
    const struct pl_shader_res *s=pl_shader_finalize(result.sh);
    if(!s||s->num_descriptors)return 9;
    f=fopen(argv[2],"wb");fprintf(f,"#version 300 es\nprecision highp float;\nout vec4 yy_output;\n%s\nvoid main(){yy_output=%s();}\n",s->glsl,s->name);fclose(f);
    char saved=tagged[strlen(tagged)-2];tagged[strlen(tagged)-2]='!';
    if(yy_dolby_enhance_parse(NULL,input))return 10;tagged[strlen(tagged)-2]=saved;
    printf("old_extra_fbo_failure=1 new_extra_fbos=0 ordinary_parser_unchanged=1 shader=%s\n",s->info->description);
    return 0;
}
