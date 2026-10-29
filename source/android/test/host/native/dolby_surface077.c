/* Complete production AImage matching/release adapter; synthetic Android,
 * GL fence and clock IO. No actual device, image pixels or GPU execution. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>
#include <limits.h>
#define MPMAX(a,b) ((a)>(b)?(a):(b))
#define MP_ERR(...) ((void)error_logs++)
#define AMEDIA_OK 0
#define AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE 1
#define EGL_NONE 0x3038
typedef int media_status_t;
typedef int EGLint;
typedef struct {int64_t timestamp;} AImage;
typedef struct {int unused;} AImageReader;
typedef struct {void (*Flush)(void);void (*Finish)(void);} GL;
struct mp_image {void *planes[4];};
typedef struct {int unused;} AVMediaCodecBuffer;
static int codec_current=1,error_logs;
static bool expire_on_timestamp,expire_on_wait;
static int av_mediacodec_yingyu_buffer_current(AVMediaCodecBuffer *buffer)
{(void)buffer;return codec_current;}
struct priv_owner {
    AImageReader *reader;
    media_status_t (*AImageReader_acquireNextImage)(AImageReader *,AImage **);
    media_status_t (*AImage_getTimestamp)(const AImage *,int64_t *);
    void (*AImage_delete)(AImage *);
    void (*AImage_deleteAsync)(AImage *,int);
};
struct priv {
    int lock,cond;
    bool image_available;
    AImage *image;
    void *egl_image;
    struct mp_image *yy_source;
    void *(*yy_CreateSync)(void *,int,const int *);
    int (*yy_DestroySync)(void *,void *);
    int (*yy_DupFence)(void *,void *);
    int (*DestroyImageKHR)(void *,void *);
};
struct owner {struct priv_owner *priv;};
struct ra_hwdec_mapper {struct priv *priv;struct owner *owner;void *ra;struct mp_image *src;};
static int64_t now, stamps[20];
static int count, cursor, images, deletes, async_deletes, finishes, flushes, waits, syncs, destroy_images;
static int fence_result, fail_timestamp;
static bool after_wait;
static void finish(void){finishes++;}
static void flush(void){flushes++;}
static GL gl={flush,finish};
static GL *ra_gl_get(void *unused){(void)unused;return &gl;}
static void *eglGetCurrentDisplay(void){return (void *)1;}
static int64_t mp_time_us(void){return now++;}
static struct timespec mp_rel_time_to_timespec(double seconds){
    int64_t us=now+(int64_t)(seconds*1000000);return (struct timespec){us/1000000,(us%1000000)*1000};
}
#define pthread_mutex_lock fake_lock
#define pthread_mutex_unlock fake_lock
#define pthread_cond_timedwait fake_wait
static void fake_lock(int *lock){(void)lock;}
static int fake_wait(int *cond,int *lock,const struct timespec *until){
    (void)cond;(void)lock;waits++;
    if(expire_on_wait)codec_current=0;
    if(after_wait){after_wait=false;now+=1000;}else now=until->tv_sec*1000000+until->tv_nsec/1000;
    return 0;
}
static void mp_image_unrefp(struct mp_image **image){free(*image);*image=NULL;}
static media_status_t acquire(AImageReader *r,AImage **image){
    (void)r;if(after_wait || cursor==count)return AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE;
    *image=malloc(sizeof(**image));(*image)->timestamp=stamps[cursor++];images++;return AMEDIA_OK;
}
static media_status_t timestamp(const AImage *image,int64_t *value){
    if(expire_on_timestamp)codec_current=0;
    if(fail_timestamp)return -1;*value=image->timestamp;return AMEDIA_OK;
}
static void destroy(AImage *image){assert(image);free(image);images--;deletes++;}
static void destroy_async(AImage *image,int fd){assert(fd==42);destroy(image);async_deletes++;}
static void *create_sync(void *display,int type,const int *attributes){
    assert(display);assert(type==0x3144 && attributes[0]==EGL_NONE);syncs++;return (void *)1;
}
static int destroy_sync(void *display,void *sync){assert(display && sync);return 1;}
static int dup_fence(void *display,void *sync){assert(display && sync);return fence_result;}
static int destroy_image(void *display,void *image){assert(display && image);destroy_images++;return 1;}

/* YINGYU_AIMAGE_HEADER */

static struct priv p;
static struct priv_owner o;
static struct owner owner;
static struct ra_hwdec_mapper mapper;
static struct mp_image src_image;
static void reset(void){
    assert(images==0);memset(&p,0,sizeof(p));memset(&o,0,sizeof(o));
    now=1;count=cursor=deletes=async_deletes=finishes=flushes=waits=syncs=destroy_images=0;
    fence_result=42;fail_timestamp=0;after_wait=false;
    codec_current=1;error_logs=0;expire_on_timestamp=expire_on_wait=false;
    o.AImageReader_acquireNextImage=acquire;o.AImage_getTimestamp=timestamp;
    o.AImage_delete=destroy;o.AImage_deleteAsync=destroy_async;
    p.yy_CreateSync=create_sync;p.yy_DestroySync=destroy_sync;p.yy_DupFence=dup_fence;
    p.DestroyImageKHR=destroy_image;owner.priv=&o;mapper=(struct ra_hwdec_mapper){&p,&owner,NULL,&src_image};
}
static void cleanup(void){yy_release_dovi_image(&mapper);assert(images==0 && !p.image && !p.yy_source);}
int main(void){
    reset();stamps[0]=100000;count=1;assert(!yy_acquire_dovi_image(&mapper,100));
    p.egl_image=(void *)1;p.yy_source=calloc(1,sizeof(*p.yy_source));cleanup();
    assert(flushes==1 && syncs==1 && async_deletes==1 && finishes==0 && destroy_images==1);
    cleanup();assert(syncs==1 && deletes==1);
    reset();stamps[0]=1000;stamps[1]=2000;stamps[2]=100000;count=3;
    assert(!yy_acquire_dovi_image(&mapper,100));assert(deletes==2);cleanup();
    reset();stamps[0]=102000;count=1;assert(yy_acquire_dovi_image(&mapper,100)<0);cleanup();
    reset();stamps[0]=100999;count=1;assert(!yy_acquire_dovi_image(&mapper,100));cleanup();
    reset();stamps[0]=101000;count=1;assert(yy_acquire_dovi_image(&mapper,100)<0);cleanup();
    reset();stamps[0]=100000;count=1;after_wait=true;
    assert(!yy_acquire_dovi_image(&mapper,100));assert(waits==1);cleanup();
    reset();assert(yy_acquire_dovi_image(&mapper,100)<0);assert(waits==1 && now>=100000);cleanup();
    reset();for(int i=0;i<10;i++)stamps[i]=i;count=10;
    assert(yy_acquire_dovi_image(&mapper,100)<0);assert(deletes==9);cleanup();
    reset();assert(yy_acquire_dovi_image(&mapper,INT64_MAX)<0);cleanup();
    reset();stamps[0]=-100000;count=1;assert(!yy_acquire_dovi_image(&mapper,-100));cleanup();
    reset();stamps[0]=100000;count=1;fail_timestamp=1;
    assert(yy_acquire_dovi_image(&mapper,100)<0);cleanup();
    reset();stamps[0]=100000;count=1;assert(!yy_acquire_dovi_image(&mapper,100));
    p.yy_CreateSync=NULL;cleanup();assert(finishes==1 && async_deletes==0);
    reset();stamps[0]=100000;count=1;assert(!yy_acquire_dovi_image(&mapper,100));
    fence_result=-1;cleanup();assert(finishes==1 && flushes==1 && async_deletes==0);
    // A proven flush can race draw/map and any AImage wait. It must exit to
    // the caller's obsolete-frame discard without falsely alleging a bad pair.
    reset();codec_current=0;stamps[0]=100000;count=1;
    assert(yy_acquire_dovi_image(&mapper,100)<0);
    assert(cursor==0 && error_logs==0);cleanup();
    reset();stamps[0]=102000;count=1;expire_on_timestamp=true;
    assert(yy_acquire_dovi_image(&mapper,100)<0);
    assert(error_logs==0);cleanup();
    reset();expire_on_wait=true;
    assert(yy_acquire_dovi_image(&mapper,100)<0);
    assert(waits==1 && error_logs==0);cleanup();
    puts("{\"passed\":16,\"failed\":0,\"scope\":\"Complete production AImage matching/release with synthetic Android, GL fence, codec-generation and clock IO; no pixels or GPU execution\"}");
    return 0;
}
