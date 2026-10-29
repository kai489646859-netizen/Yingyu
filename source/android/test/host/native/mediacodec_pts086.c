/* Synthetic IO around complete, unmodified production queue/copy-wrap/flush.
 * This is not Android decoding, codec ordering, or a device playback test. */
#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#define AV_NOPTS_VALUE INT64_MIN
#define AVERROR(x) (-(x))
#define AVERROR_EXTERNAL (-1001)
#define AVERROR_EOF (-1002)
#define AVERROR_INVALIDDATA (-1003)
#define AV_LOG_ERROR 1
#define AV_LOG_WARNING 2
#define AV_LOG_TRACE 3
#define AV_LOG_DEBUG 4
#define INPUT_DEQUEUE_TIMEOUT_US 8000
#define FFMIN(a,b) ((a)<(b)?(a):(b))
#define COLOR_FormatYUV420Planar 1
#define COLOR_FormatYUV420SemiPlanar 2
#define COLOR_QCOM_FormatYUV420SemiPlanar 3
#define COLOR_QCOM_FormatYUV420SemiPlanar32m 4
#define COLOR_TI_FormatYUV420PackedSemiPlanar 5
#define COLOR_TI_FormatYUV420PackedSemiPlanarInterlaced 6
#define COLOR_QCOM_FormatYUV420PackedSemiPlanar64x32Tile2m8ka 7
typedef struct AVRational {int num,den;} AVRational;
#define AV_TIME_BASE_Q ((AVRational){1,1000000})
typedef struct AVCodecContext {int width,height,pix_fmt; AVRational pkt_timebase;} AVCodecContext;
typedef struct AVPacket {uint8_t *data; int size; int64_t pts;} AVPacket;
typedef struct AVFrame {int width,height,format,linesize[3];int64_t pts,pkt_dts;} AVFrame;
typedef struct FFAMediaFormat {int unused;} FFAMediaFormat;
typedef struct FFAMediaCodecBufferInfo {int64_t presentationTimeUs;} FFAMediaCodecBufferInfo;
typedef struct FFAMediaCodec {
    int count,cap,dequeues,queue_error,flush_error,released,flushed;
    int64_t wire[2048]; size_t sizes[2048]; uint8_t input[4096];
} FFAMediaCodec;
/* HEADER */
/* CONTEXT */
static void av_log(void *p,int level,const char *fmt,...) {(void)p;(void)level;(void)fmt;}
static int64_t av_rescale_q(int64_t v,AVRational a,AVRational b) {
    return (int64_t)llroundl((long double)v*a.num*b.den/a.den/b.num);
}
static int ff_get_buffer(AVCodecContext *c,AVFrame *f,int n) {(void)c;(void)n;f->pts=123;return 0;}
static ssize_t ff_AMediaCodec_dequeueInputBuffer(FFAMediaCodec *c,int64_t t) {(void)t;if(!c->dequeues)return -11;c->dequeues--;return c->count;}
static int ff_AMediaCodec_infoTryAgainLater(FFAMediaCodec *c,ssize_t n) {(void)c;return n==-11;}
static uint8_t *ff_AMediaCodec_getInputBuffer(FFAMediaCodec *c,ssize_t i,size_t *n) {(void)i;*n=c->cap;return c->input;}
static int ff_AMediaCodec_queueInputBuffer(FFAMediaCodec *c,ssize_t i,int o,size_t n,int64_t t,int f) {(void)i;(void)o;(void)f;if(c->queue_error)return -1;c->wire[c->count]=t;c->sizes[c->count++]=n;return 0;}
static uint32_t ff_AMediaCodec_getBufferFlagEndOfStream(FFAMediaCodec *c) {(void)c;return 4;}
static int ff_AMediaCodec_releaseOutputBuffer(FFAMediaCodec *c,ssize_t i,int r) {(void)i;(void)r;c->released++;return 0;}
static int ff_AMediaCodec_flush(FFAMediaCodec *c) {c->flushed++;return c->flush_error;}
#define COPY(name) static void name(AVCodecContext *a,MediaCodecDecContext *s,uint8_t *d,size_t n,FFAMediaCodecBufferInfo *i,AVFrame *f) {(void)a;(void)s;(void)d;(void)n;(void)i;(void)f;}
COPY(ff_mediacodec_sw_buffer_copy_yuv420_planar)
COPY(ff_mediacodec_sw_buffer_copy_yuv420_semi_planar)
COPY(ff_mediacodec_sw_buffer_copy_yuv420_packed_semi_planar)
COPY(ff_mediacodec_sw_buffer_copy_yuv420_packed_semi_planar_64x32Tile2m8ka)
/* FUNCTIONS */
static int passed,failed;
static void check(const char *name,bool ok) {printf("%s %s\n",ok?"PASS":"FAIL",name);if(ok)passed++;else failed++;}
static void init(MediaCodecDecContext *s,FFAMediaCodec *c,int enabled) {
    memset(s,0,sizeof(*s));memset(c,0,sizeof(*c));c->cap=4096;c->dequeues=2048;s->codec=c;s->current_input_buffer=-1;s->color_format=COLOR_FormatYUV420SemiPlanar;atomic_init(&s->refcount,1);atomic_init(&s->serial,1);
#if CURRENT
    s->yy_disc_pts=enabled;
#else
    (void)enabled;
#endif
}
static int send(AVCodecContext *a,MediaCodecDecContext *s,int64_t pts,int size) {uint8_t data[4096]={0};AVPacket p={data,size,pts};return ff_mediacodec_dec_send(a,s,&p,false);}
static int out(AVCodecContext *a,MediaCodecDecContext *s,int64_t wire,int64_t *pts) {FFAMediaCodecBufferInfo i={wire};AVFrame f={0};uint8_t data[1]={0};int r=mediacodec_wrap_sw_buffer(a,s,data,1,0,&i,&f);*pts=f.pts;return r;}
int main(void) {
    AVCodecContext a={.width=3840,.height=2160,.pkt_timebase={1,90000}};MediaCodecDecContext s;FFAMediaCodec c;int64_t p,v[4],old;
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);check("source unknown remains unknown",out(&a,&s,c.wire[0],&p)==0&&p==AV_NOPTS_VALUE);
    init(&s,&c,1);send(&a,&s,0,1);check("legitimate zero",out(&a,&s,c.wire[0],&p)==0&&p==0);
    init(&s,&c,1);send(&a,&s,-90001,1);check("negative PTS",out(&a,&s,c.wire[0],&p)==0&&p==-90001);
    init(&s,&c,1);send(&a,&s,130150020,1);check("known 1446 second anchor",out(&a,&s,c.wire[0],&p)==0&&p==130150020);
    init(&s,&c,1);v[0]=130150020;v[1]=AV_NOPTS_VALUE;v[2]=0;v[3]=-90000;for(int i=0;i<4;i++)send(&a,&s,v[i],1);bool ok=true;int order[]={2,3,1,0};for(int j=0;j<4;j++){int i=order[j];ok&=out(&a,&s,c.wire[i],&p)==0&&p==v[i];}check("B frame reorder unknown zero negative",ok);
    init(&s,&c,1);for(int i=0;i<8;i++)send(&a,&s,AV_NOPTS_VALUE,1);ok=true;for(int i=7;i>=0;i--)ok&=out(&a,&s,c.wire[i],&p)==0&&p==AV_NOPTS_VALUE;check("consecutive unknown reversed outputs",ok);
    init(&s,&c,0);send(&a,&s,AV_NOPTS_VALUE,1);check("ordinary option off preserved",out(&a,&s,c.wire[0],&p)==0&&p==0);
    init(&s,&c,1);s.surface=(void *)1;send(&a,&s,AV_NOPTS_VALUE,1);check("Surface path unmodified",c.wire[0]==0&&out(&a,&s,0,&p)==0&&p==0);
    init(&s,&c,1);c.dequeues=0;check("EAGAIN no submission",send(&a,&s,AV_NOPTS_VALUE,1)==AVERROR(EAGAIN)&&c.count==0);
    init(&s,&c,1);c.queue_error=1;check("queue failure real",send(&a,&s,AV_NOPTS_VALUE,1)==AVERROR_EXTERNAL&&c.count==0);
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,0);check("EOS empty excluded",c.count==1&&c.sizes[0]==0&&c.wire[0]==0&&s.draining);
    init(&s,&c,1);c.cap=2;check("partial packet queues all chunks",send(&a,&s,AV_NOPTS_VALUE,5)==5&&c.count==3);ok=true;for(int i=0;i<3;i++)ok&=out(&a,&s,c.wire[i],&p)==0&&p==AV_NOPTS_VALUE;check("partial chunks preserve source unknown",ok);
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);old=c.wire[0];mediacodec_dec_flush_codec(&a,&s);send(&a,&s,0,1);check("flush new generation valid zero",out(&a,&s,c.wire[1],&p)==0&&p==0&&atomic_load(&s.serial)==2);
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);old=c.wire[0];c.queue_error=1;int fail=send(&a,&s,0,1);c.queue_error=0;send(&a,&s,0,1);check("failed submit preserves live identity",fail<0&&c.count==2&&out(&a,&s,old,&p)==0&&p==AV_NOPTS_VALUE&&out(&a,&s,c.wire[1],&p)==0&&p==0);
    init(&s,&c,1);c.cap=2;c.dequeues=1;int partial=send(&a,&s,AV_NOPTS_VALUE,5);c.dequeues=2048;int remaining=send(&a,&s,AV_NOPTS_VALUE,3);check("partial EAGAIN resume",partial==2&&remaining==3&&c.count==3&&out(&a,&s,c.wire[2],&p)==0&&p==AV_NOPTS_VALUE);
    init(&s,&c,1);send(&a,&s,90000,1);old=c.wire[0];c.flush_error=-1;int flushed=mediacodec_dec_flush_codec(&a,&s);check("flush failure rejects stale identity",flushed==AVERROR_EXTERNAL&&out(&a,&s,old,&p)<0&&c.released==1);
    init(&s,&c,1);send(&a,&s,0,1);send(&a,&s,90,1);check("real media PTS resembles token",out(&a,&s,c.wire[1],&p)==0&&p==90&&out(&a,&s,c.wire[0],&p)==0&&p==0);
    init(&s,&c,1);a.pkt_timebase=(AVRational){0,0};send(&a,&s,-123456,1);check("no timebase known preserved",out(&a,&s,c.wire[0],&p)==0&&p==-123456);send(&a,&s,AV_NOPTS_VALUE,1);check("no timebase unknown preserved",out(&a,&s,c.wire[1],&p)==0&&p==AV_NOPTS_VALUE);a.pkt_timebase=(AVRational){1,90000};
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);old=c.wire[0];mediacodec_dec_flush_codec(&a,&s);send(&a,&s,0,1);
    check("copy flush dispatch is immediate",ff_mediacodec_dec_flush(&a,&s)==1&&c.flushed==2&&!s.flushing);
    init(&s,&c,1);s.surface=(void *)1;s.delay_flush=true;atomic_store(&s.refcount,2);check("Surface deferred flush preserved",ff_mediacodec_dec_flush(&a,&s)==0&&c.flushed==0&&s.flushing);
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);old=c.wire[0];mediacodec_dec_flush_codec(&a,&s);send(&a,&s,0,1);
#if CURRENT
    check("flush token never reused",old!=c.wire[1]);
    check("late old generation rejected",out(&a,&s,old,&p)<0);
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);check("driver zero rewrite rejected",out(&a,&s,0,&p)<0);
    check("driver unassociated rewrite rejected",out(&a,&s,c.wire[0]+1,&p)<0);
    init(&s,&c,1);for(int i=0;i<513;i++)send(&a,&s,i*3750,1);check("bounded history newest retained",out(&a,&s,c.wire[512],&p)==0&&p==512*3750);check("expired history rejected",out(&a,&s,c.wire[0],&p)<0);
    init(&s,&c,1);s.yy_pts.submitted=INT64_MAX/1000/YY_MC_PTS_STEP_US;check("nanosecond overflow rejected",send(&a,&s,AV_NOPTS_VALUE,1)<0&&c.count==0);
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);check("repeat outputs same origin",out(&a,&s,c.wire[0],&p)==0&&p==AV_NOPTS_VALUE&&out(&a,&s,c.wire[0],&p)==0&&p==AV_NOPTS_VALUE);
#else
    check("flush token never reused",old!=c.wire[1]);check("late old generation rejected",out(&a,&s,old,&p)<0);
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);check("driver zero rewrite rejected",out(&a,&s,0,&p)<0);check("driver unassociated rewrite rejected",out(&a,&s,c.wire[0]+1,&p)<0);
    init(&s,&c,1);for(int i=0;i<513;i++)send(&a,&s,i*3750,1);check("bounded history newest retained",out(&a,&s,c.wire[512],&p)==0&&p==512*3750);check("expired history rejected",out(&a,&s,c.wire[0],&p)<0);
    init(&s,&c,1);send(&a,&s,AV_NOPTS_VALUE,1);check("repeat outputs same origin",out(&a,&s,c.wire[0],&p)==0&&p==AV_NOPTS_VALUE&&out(&a,&s,c.wire[0],&p)==0&&p==AV_NOPTS_VALUE);
#endif
    printf("SUMMARY passed=%d failed=%d total=%d\n",passed,failed,passed+failed);return failed?1:0;
}
