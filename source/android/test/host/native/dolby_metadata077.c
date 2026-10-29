/* Synthetic allocation/parser IO around the complete production queue adapter.
 * This tests pairing and lifetime, not RPU parsing or Android decoding. */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define AVERROR(x) (-(x))
#define AVERROR_INVALIDDATA (-1234)
#define AV_NOPTS_VALUE INT64_MIN
#define AV_CODEC_ID_HEVC 1
#define AV_LOG_ERROR 1
#define AV_PKT_DATA_DOVI_CONF 1
#define AV_FRAME_DATA_DOVI_METADATA 1
#define AV_FRAME_DATA_DOVI_RPU_BUFFER 2
typedef struct { int num, den; } AVRational;
#define AV_TIME_BASE_Q ((AVRational){1, 1000000})
typedef struct { int vdr_rpu_profile, bl_video_full_range_flag; } AVDOVIRpuDataHeader;
typedef struct { int dv_profile; } AVDOVIDecoderConfigurationRecord;
typedef struct { void *logctx; AVDOVIRpuDataHeader header; int tag; } DOVIContext;
typedef struct { int refs; size_t size; uint8_t *data; } Storage;
typedef struct { Storage *storage; uint8_t *data; size_t size; } AVBufferRef;
typedef struct { int type; AVBufferRef *buf; uint8_t *data; size_t size; } AVFrameSideData;
typedef struct { int nb_side_data; AVFrameSideData *side_data[4]; int64_t pts; } AVFrame;
typedef struct { uint8_t *data; int size; int64_t pts; AVDOVIDecoderConfigurationRecord *cfg; } AVPacket;
typedef struct { AVRational pkt_timebase; } AVCodecContext;
typedef struct { const uint8_t *data; int size; } NAL;
typedef struct { int nb_nals; NAL nals[1]; } H2645Packet;
static int frames, buffers;
static AVBufferRef *buffer_new(size_t size) {
    AVBufferRef *b=calloc(1,sizeof(*b));b->storage=calloc(1,sizeof(*b->storage));
    b->storage->refs=1;b->storage->size=size;b->storage->data=calloc(1,size);
    b->data=b->storage->data;b->size=size;buffers++;return b;
}
static AVBufferRef *av_buffer_ref(AVBufferRef *src) {
    AVBufferRef *b=malloc(sizeof(*b));*b=*src;b->storage->refs++;return b;
}
static void av_buffer_unref(AVBufferRef **b) {
    if (!*b)return;
    if (!--(*b)->storage->refs) {free((*b)->storage->data);free((*b)->storage);buffers--;}
    free(*b);*b=NULL;
}
static AVFrame *av_frame_alloc(void) {frames++;return calloc(1,sizeof(AVFrame));}
static AVFrameSideData *av_frame_new_side_data_from_buf(AVFrame *f,int type,AVBufferRef *b) {
    assert(f->nb_side_data<4);AVFrameSideData *sd=calloc(1,sizeof(*sd));
    *sd=(AVFrameSideData){type,b,b->data,b->size};f->side_data[f->nb_side_data++]=sd;return sd;
}
static AVFrameSideData *av_frame_new_side_data(AVFrame *f,int type,size_t size) {
    return av_frame_new_side_data_from_buf(f,type,buffer_new(size));
}
static AVFrameSideData *av_frame_get_side_data(AVFrame *f,int type) {
    for(int i=0;i<f->nb_side_data;i++)if(f->side_data[i]->type==type)return f->side_data[i];return NULL;
}
static void av_frame_free(AVFrame **f) {
    if(!*f)return;
    for(int i=0;i<(*f)->nb_side_data;i++){av_buffer_unref(&(*f)->side_data[i]->buf);free((*f)->side_data[i]);}
    free(*f);*f=NULL;frames--;
}
static const uint8_t *av_packet_get_side_data(const AVPacket *p,int type,size_t *size) {
    (void)type;*size=p->cfg?sizeof(*p->cfg):0;return (const uint8_t *)p->cfg;
}
static void av_log(void *ctx,int level,const char *message) {(void)ctx;(void)level;(void)message;}
static int64_t av_rescale_q(int64_t pts,AVRational from,AVRational to) {
    return pts * from.num * to.den / from.den / to.num;
}
static void ff_dovi_ctx_unref(DOVIContext *q) {void *log=q->logctx;memset(q,0,sizeof(*q));q->logctx=log;}
static void ff_dovi_ctx_flush(DOVIContext *q) {q->tag=0;}
static void ff_dovi_update_cfg(DOVIContext *q,const AVDOVIDecoderConfigurationRecord *cfg) {(void)q;(void)cfg;}
static int ff_h2645_packet_split(H2645Packet *q,const uint8_t *p,int size,void *ctx,int a,int b,int c,int d,int e) {
    (void)ctx;(void)a;(void)b;(void)c;(void)d;(void)e;
    q->nb_nals=1;q->nals[0]=(NAL){p+3,size-3};return 0;
}
static void ff_h2645_packet_uninit(H2645Packet *q) {memset(q,0,sizeof(*q));}
static int ff_dovi_rpu_parse(DOVIContext *q,const uint8_t *p,size_t size) {
    if(size!=2 || p[0]==255)return AVERROR_INVALIDDATA;
    q->header=(AVDOVIRpuDataHeader){p[0]==5?0:1,p[0]==5};q->tag=p[1];return 0;
}
static int ff_dovi_attach_side_data(DOVIContext *q,AVFrame *f) {
    AVFrameSideData *sd=av_frame_new_side_data(f,AV_FRAME_DATA_DOVI_METADATA,1);
    sd->data[0]=q->tag;return 0;
}

/* YINGYU_DOVI_HEADER */

static AVCodecContext codec={{1,1000}};
static int submit(YYDoviQueue *q,int64_t pts,int profile,int tag) {
    uint8_t data[]={0,0,0,1,2,1,128,0,0,1,124,1,(uint8_t)profile,(uint8_t)tag};
    AVPacket p={data,sizeof(data),pts,NULL};return yy_dovi_submit(q,&codec,&p);
}
static void output(YYDoviQueue *q,int64_t pts,int tag) {
    AVFrame *f=av_frame_alloc();f->pts=918273;
    assert(yy_dovi_output(q,f,pts)==0);
    AVFrameSideData *sd=av_frame_get_side_data(f,AV_FRAME_DATA_DOVI_METADATA);
    assert(sd && sd->data[0]==tag);assert(f->pts==918273);av_frame_free(&f);
}
static void clean(YYDoviQueue *q) {yy_dovi_clear(q,1);assert(!q->count);assert(!frames && !buffers);}
int main(void) {
    YYDoviQueue q={0};
    assert(!submit(&q,1000,5,1));assert(!submit(&q,3000,5,3));assert(!submit(&q,2000,5,2));
    output(&q,3000000,3);output(&q,1000000,1);output(&q,2000000,2);clean(&q);
    assert(!submit(&q,0,5,8));output(&q,0,8);clean(&q);
    assert(!submit(&q,-100,5,9));output(&q,-100000,9);clean(&q);
    assert(!submit(&q,100,5,1));assert(submit(&q,100,5,2)<0);assert(q.count==1);output(&q,100000,1);clean(&q);
    assert(submit(&q,AV_NOPTS_VALUE,5,1)<0);clean(&q);
    for(int i=0;i<YY_DOVI_QUEUE_SIZE;i++)assert(!submit(&q,i,5,1));
    assert(submit(&q,YY_DOVI_QUEUE_SIZE,5,1)<0);assert(q.count==YY_DOVI_QUEUE_SIZE);clean(&q);
    assert(!submit(&q,100,5,1));yy_dovi_clear(&q,0);assert(q.count==0 && !frames && !buffers);
    AVFrame *f=av_frame_alloc();assert(yy_dovi_output(&q,f,100000)<0);av_frame_free(&f);clean(&q);
    assert(!submit(&q,100,5,1));f=av_frame_alloc();assert(yy_dovi_output(&q,f,200000)<0);av_frame_free(&f);clean(&q);
    assert(submit(&q,100,255,1)<0);clean(&q);
    uint8_t bare[]={0,0,1,2,1,128};AVPacket p={bare,sizeof(bare),100,NULL};
    assert(!yy_dovi_submit(&q,&codec,&p));assert(q.count==0);clean(&q);
    AVDOVIDecoderConfigurationRecord cfg={5};p.cfg=&cfg;
    assert(yy_dovi_submit(&q,&codec,&p)<0);clean(&q);
    uint8_t twice[]={0,0,1,2,1,128,0,0,1,124,1,5,1,0,0,1,124,1,5,2};
    p=(AVPacket){twice,sizeof(twice),100,NULL};assert(yy_dovi_submit(&q,&codec,&p)<0);clean(&q);
    assert(!submit(&q,100,8,8));output(&q,100000,8);clean(&q);
    uint8_t header[]={0,0,1,64,1,128};p=(AVPacket){header,sizeof(header),100,NULL};
    assert(!yy_dovi_submit(&q,&codec,&p));assert(!q.count);clean(&q);
    puts("{\"passed\":14,\"failed\":0,\"scope\":\"Complete production metadata queue with synthetic parser/allocation IO; no decoder or RPU parser validation\"}");
    return 0;
}
