// Synthetic packet IO for the pinned LGPL FFmpeg n6.0 av_read_frame.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <errno.h>
#define AV_NOPTS_VALUE INT64_MIN
#define AVFMT_FLAG_GENPTS 1
#define AVFMT_GENERIC_INDEX 2
#define AV_PKT_FLAG_KEY 1
#define AVINDEX_KEYFRAME 1
#define AVDISCARD_ALL 48
#define AVERROR(x) (-(x))
#define RELATIVE_TS_BASE (INT64_MAX - (1LL << 48))
#define av_assert2 assert
typedef struct AVPacket { int64_t pts,dts,duration,pos; int stream_index,flags; } AVPacket;
typedef struct PacketListEntry { AVPacket pkt; struct PacketListEntry *next; } PacketListEntry;
typedef struct PacketList { PacketListEntry *head,*tail; } PacketList;
typedef struct FFFormatContext { PacketList packet_buffer; } FFFormatContext;
typedef struct AVStream { int pts_wrap_bits, discard,index; } AVStream;
typedef struct AVInputFormat { int flags; } AVInputFormat;
typedef struct AVFormatContext {
    int flags; AVStream **streams; AVInputFormat *iformat; FFFormatContext internal;
    AVPacket *packets; int count, cursor, reads;
} AVFormatContext;
static FFFormatContext *ffformatcontext(AVFormatContext *s) { return &s->internal; }
static int read_frame_internal(AVFormatContext *s, AVPacket *pkt) {
    s->reads++;
    if (s->cursor == s->count) return -1;
    *pkt=s->packets[s->cursor++]; return 0;
}
static int avpriv_packet_list_get(PacketList *p, AVPacket *pkt) {
    PacketListEntry *e=p->head; assert(e); *pkt=e->pkt; p->head=e->next;
    if (!p->head) p->tail=NULL; free(e); return 0;
}
static int avpriv_packet_list_put(PacketList *p, AVPacket *pkt, void *unused, int flags) {
    PacketListEntry *e=calloc(1,sizeof(*e)); assert(e); e->pkt=*pkt;
    if (p->tail) p->tail->next=e; else p->head=e; p->tail=e; return 0;
}
static int64_t av_compare_mod(uint64_t a, uint64_t b, uint64_t mod) {
    int64_t c=(a-b)&(mod-1); if (c>(mod>>1)) c-=mod; return c;
}
static int is_relative(int64_t ts) { return ts > RELATIVE_TS_BASE - (1LL << 48); }
static void av_packet_unref(AVPacket *p) {}
static void ff_reduce_index(AVFormatContext *s,int i) { assert(0); }
static void av_add_index_entry(AVStream *s,int64_t pos,int64_t ts,int a,int b,int f) { assert(0); }
/* PINNED_AV_READ_FRAME */
#define AV_LOG_WARNING 1
#define av_log(...) ((void)0)
static int64_t mediacodec_pts(AVPacket *pkt) {
    int64_t pts;
    /* PINNED_MEDIACODEC_PTS */
    return pts;
}
static void run(const char *name,int genpts,AVPacket *input,int count,const int64_t *expected,int first_reads) {
    AVStream v={33,0,0}, a={33,0,1}; AVStream *streams[]={&v,&a}; AVInputFormat fmt={0};
    AVFormatContext s={.flags=genpts,.streams=streams,.iformat=&fmt,.packets=input,.count=count};
    for(int i=0;i<count;i++) {
        AVPacket p; assert(av_read_frame(&s,&p)==0); assert(p.pts==expected[i]);
        assert(p.dts==input[i].dts && p.stream_index==input[i].stream_index);
        if (!i && first_reads>=0) assert(s.reads==first_reads);
        if(p.pts==AV_NOPTS_VALUE) assert(mediacodec_pts(&p)==0);
        else assert(mediacodec_pts(&p)==expected[i]);
    }
    AVPacket p; assert(av_read_frame(&s,&p)<0); assert(!s.internal.packet_buffer.head);
    printf("%s\"%s\"", name[0]=='o'?"":",",name);
}
#define P(pts,dts,stream) {pts,dts,3600,0,stream,0}
int main(void) {
    // Includes B frames. DTS must not be blindly copied to PTS.
    AVPacket broken[]={P(AV_NOPTS_VALUE,54000000,0),P(54003600,54003600,0),P(54007200,54007200,0),P(54021600,54010800,0)};
    int64_t before[]={AV_NOPTS_VALUE,54003600,54007200,54021600};
    int64_t repaired[]={54010800,54003600,54007200,54021600};
    printf("[");run("old_missing_pts_reaches_zero",0,broken,4,before,1);
    run("disc_missing_pts_b_frame_order",1,broken,4,repaired,4);
    AVPacket valid[]={P(54010800,54000000,0),P(54003600,54003600,0),P(54007200,54007200,0),P(54021600,54010800,0)};
    run("valid_pts_no_lookahead_or_rewrite",1,valid,4,repaired,1);
    AVPacket absent[]={P(AV_NOPTS_VALUE,AV_NOPTS_VALUE,0)};int64_t unknown[]={AV_NOPTS_VALUE};
    run("missing_dts_is_not_fabricated",1,absent,1,unknown,1);
    AVPacket end[]={P(AV_NOPTS_VALUE,54000000,0)};int64_t endpts[]={54003600};
    run("eof_reference_frame",1,end,1,endpts,2);
    AVPacket mixed[]={P(AV_NOPTS_VALUE,54000000,0),P(123,100,1),P(54010800,54003600,0)};
    int64_t mixpts[]={54003600,123,54010800};run("audio_stream_cannot_supply_video_pts",1,mixed,3,mixpts,3);
    AVPacket zero[]={P(0,0,0)};int64_t zeropts[]={0};run("legitimate_zero_pts_preserved",1,zero,1,zeropts,1);
    // A new context at a precise seek has no previous-packet state to leak.
    run("fresh_seek_does_not_reuse_stale_pts",1,broken,4,repaired,4);
    printf("]\n");return 0;
}
