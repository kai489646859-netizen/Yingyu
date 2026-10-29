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
/* PRODUCTION_PROOF_HEADER */
static int allocations;
static pl_tex deny_extra(void *p,int w,int h){allocations++;return NULL;}

#include <libplacebo/opengl.h>
#include <libplacebo/renderer.h>
#include <math.h>
struct seen {char text[8192];struct yy_enhancement_proof *proof;};
static void capture(void *priv,const struct pl_render_info *info) {
    struct seen *s=priv;
    yy_proof_dispatch(s->proof,info->pass->shader->description);
    size_t n=strlen(s->text);
    snprintf(s->text+n,sizeof(s->text)-n,"[%d:%d] %s\n",info->stage,info->index,info->pass->shader->description);
}
/* TEST_DOVI_METADATA */

static int logged_errors;
static void checked_log(void *priv,enum pl_log_level level,const char *msg){if(level<=PL_LOG_ERR)logged_errors++;pl_log_simple(priv,level,msg);}
static void pixels(void *proc,pl_gpu gpu,pl_tex output,bool floating,float *out,int count) {
 pl_voidfunc_t(*get)(const char*)=(pl_voidfunc_t(*)(const char*))proc;
 unsigned texture=pl_opengl_unwrap(gpu,output,NULL,NULL,NULL),fbo;int before=0;
 ((void(*)(unsigned,int*))get("glGetIntegerv"))(0x8ca6,&before);
 ((void(*)(int,unsigned*))get("glGenFramebuffers"))(1,&fbo);
 ((void(*)(unsigned,unsigned))get("glBindFramebuffer"))(0x8d40,fbo);
 ((void(*)(unsigned,unsigned,unsigned,unsigned,int))get("glFramebufferTexture2D"))(0x8d40,0x8ce0,0x0de1,texture,0);
 if(floating)((void(*)(int,int,int,int,unsigned,unsigned,void*))get("glReadPixels"))(0,0,16,16,0x1908,0x1406,out);
 else {unsigned char b[1024];((void(*)(int,int,int,int,unsigned,unsigned,void*))get("glReadPixels"))(0,0,16,16,0x1908,0x1401,b);for(int j=0;j<count;j++)out[j]=b[j]/255.0f;}
 if(((unsigned(*)(void))get("glGetError"))())abort();
 ((void(*)(unsigned,unsigned))get("glBindFramebuffer"))(0x8d40,before);
 ((void(*)(int,const unsigned*))get("glDeleteFramebuffers"))(1,&fbo);
}
__declspec(dllexport) int sequence(void *proc,const char *dir,const char *report) {
 FILE *f=fopen(report,"w");int failed=0;
 pl_log log=pl_log_create(PL_API_VER,pl_log_params(.log_cb=checked_log,.log_priv=stderr,.log_level=PL_LOG_WARN));
 pl_opengl gl=pl_opengl_create(log,pl_opengl_params(.get_proc_addr=(pl_voidfunc_t(*)(const char*))proc,.allow_software=true,.max_glsl_version=300));if(!gl)return 1;
 pl_gpu gpu=gl->gpu;
 const char *steps[]={NULL,"bt1886-0-5.hook","bt1886-0-15.hook","bt1886-25-0.hook","bt1886-75-0.hook","bt1886-75-15.hook",NULL};
 for(int mode=0;mode<4;mode++)for(int floatfmt=0;floatfmt<2;floatfmt++)for(int geometry=0;geometry<3;geometry++) {
  pl_renderer rr=pl_renderer_create(log,gpu);pl_fmt fmt=pl_find_named_fmt(gpu,"rgba16f");
  float rgba[1024];for(int i=0;i<256;i++){float y=.07f+.45f*(i%16)/15.0f;rgba[4*i]=y;rgba[4*i+1]=mode<2?y:.5f;rgba[4*i+2]=mode<2?y:.5f;rgba[4*i+3]=1;}
  pl_tex input=pl_tex_create(gpu,pl_tex_params(.w=16,.h=16,.format=fmt,.sampleable=true,.initial_data=rgba));
  pl_tex output=pl_tex_create(gpu,pl_tex_params(.w=16,.h=16,.format=floatfmt?fmt:pl_find_named_fmt(gpu,"rgba8"),.renderable=true,.blit_dst=true));if(!input||!output)return 2;
  struct pl_frame src={.num_planes=1,.planes={{.texture=input,.components=3,.component_mapping={0,1,2,3}}},.repr=pl_color_repr_rgb,.color=pl_color_space_monitor};
  if(mode){src.color.primaries=PL_COLOR_PRIM_BT_2020;src.color.transfer=PL_COLOR_TRC_PQ;src.color.hdr.max_luma=10000;src.color.hdr.max_pq_y=.518193;src.color.hdr.avg_pq_y=.300122;}
  if(mode>=2){src.repr=pl_color_repr_uhdtv;src.repr.bits=(struct pl_bit_encoding){.sample_depth=10,.color_depth=10};}
  struct pl_dovi_metadata identity={.nonlinear={{{1,0,1.4746},{1,-.164553,-.571353},{1,1.8814,0}}},.linear={{{1,0,0},{0,1,0},{0,0,1}}},.nonlinear_offset={0,.5,.5}};
  for(int k=0;k<3;k++){identity.comp[k].num_pivots=2;identity.comp[k].pivots[1]=1;identity.comp[k].poly_coeffs[0][1]=1;}
  if(mode>=3){src.repr.sys=PL_COLOR_SYSTEM_DOLBYVISION;src.repr.dovi=mode==3?&identity:&dovi_meta;}
  struct pl_frame dst={.num_planes=1,.planes={{.texture=output,.components=4,.component_mapping={0,1,2,3}}},.repr=pl_color_repr_rgb,.color=pl_color_space_monitor};
  if(geometry==1){src.crop=(pl_rect2df){1.25f,0,14.25f,16};dst.crop=(pl_rect2df){2,1,15,14};}
  if(geometry==2)src.rotation=PL_ROTATION_90;
  if(!floatfmt)dst.repr.bits=(struct pl_bit_encoding){.sample_depth=8,.color_depth=8};
  struct yy_enhancement_proof proof={0};struct seen seen={.proof=&proof};struct pl_render_params params=pl_render_default_params;
  params.info_callback=capture;params.info_priv=&seen;
  struct pl_color_map_params cm=pl_color_map_default_params;cm.tone_mapping_function=&pl_tone_map_bt2390;cm.tone_mapping_param=.5;params.color_map_params=&cm;
  params.peak_detect_params=NULL;params.dither_params=NULL;
  const struct pl_frame *frames[]={&src};uint64_t signatures[]={1};float timestamps[]={0};
  struct pl_frame_mix mix={.num_frames=1,.frames=frames,.signatures=signatures,.timestamps=timestamps,.vsync_duration=1};
  float baseline[1024];
  for(int step=0;step<28;step++) {
   const struct pl_hook *hook=NULL;
   if(steps[step%7]){char path[1024];snprintf(path,sizeof(path),"%s/%s",dir,steps[step%7]);FILE *s=fopen(path,"rb");if(!s)return 3;fseek(s,0,SEEK_END);long n=ftell(s);rewind(s);char *text=calloc(n+1,1);fread(text,1,n,s);fclose(s);
    char *desc=strstr(text,"//!DESC "),*body=strchr(desc,'\n')+1;size_t prefix=desc-text;const char *marker="//!DESC Yingyu Dolby enhancement v1\n";
    char *tagged=calloc(prefix+strlen(marker)+strlen(body)+1,1);memcpy(tagged,text,prefix);strcat(tagged,marker);strcat(tagged,body);
    hook=yy_dolby_enhance_parse(NULL,(struct bstr){(unsigned char*)tagged,strlen(tagged)});if(!hook)return 4;
   }
   params.hooks=&hook;params.num_hooks=!!hook;seen.text[0]=0;yy_proof_begin(&proof,hook?((struct yy_dolby_enhance*)hook->priv)->hash:"",true);
   params.skip_caching_single_frame=step>=7;params.preserve_mixing_cache=step>=14;signatures[0]=step>=21?step:1;
   bool ok=pl_render_image_mix(rr,&mix,&dst,&params);yy_proof_rendered(&proof,ok);yy_proof_presented(&proof,true);
   float values[1024];pixels(proc,gpu,output,floatfmt,values,1024);if(!step)memcpy(baseline,values,sizeof(values));
   double delta=0;int changed=0;float maxdiff=0;for(int j=0;j<256;j++)for(int k=0;k<3;k++){float d=values[4*j+k]-baseline[4*j+k];changed+=fabs(d)>.001;delta+=d;maxdiff=fmaxf(maxdiff,fabsf(d));}
   bool passed=ok&&!pl_renderer_get_errors(rr).errors&&(hook?(changed>0&&proof.valid):maxdiff<=(floatfmt?.001f:1.0f/255+.00001f));
   fprintf(f,"mode=%d float=%d geometry=%d step=%d shader=%s changed=%d delta=%f proof=%d ok=%d passed=%d first=%f,%f,%f mid=%f,%f,%f\n%s\n",mode,floatfmt,geometry,step,steps[step%7]?steps[step%7]:"off",changed,delta,proof.valid,ok,passed,values[0],values[1],values[2],values[32],values[33],values[34],seen.text);fflush(f);failed+=!passed;
  }
  pl_tex_destroy(gpu,&input);pl_tex_destroy(gpu,&output);pl_renderer_destroy(&rr);
 }
 fclose(f);pl_opengl_destroy(&gl);pl_log_destroy(&log);return failed+logged_errors;
}
