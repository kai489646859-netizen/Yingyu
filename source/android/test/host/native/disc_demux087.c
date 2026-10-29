// Complete old/new demux_seek_lavf functions are extracted verbatim by the
// runner. These observable AVIO calls are synthetic; no decoder or speed test.
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "disc_seek_index.h"
#define SEEK_FORWARD 1
#define SEEK_FACTOR 2
#define AVSEEK_FLAG_BACKWARD 1
#define AVSEEK_FLAG_BYTE 2
#define AVFMT_NO_BYTE_SEEK 32768
#define AV_TIME_BASE 1000000
#define AV_NOPTS_VALUE INT64_MIN
#define AVMEDIA_TYPE_VIDEO 0
#define AVMEDIA_TYPE_AUDIO 1
#define MP_WARN(...) ((void)0)
#define MP_VERBOSE(...) ((void)0)
#define MP_HANDLE_OOM(p) do { if (!(p)) abort(); } while (0)
typedef struct { int num, den; } AVRational;
typedef struct { int codec_type, block_align; } AVCodecParameters;
typedef struct { AVCodecParameters *codecpar; int id,index; AVRational time_base; } AVStream;
typedef struct { int64_t pos; } AVIOContext;
typedef struct { unsigned nb_streams; AVStream **streams; int64_t duration; AVIOContext *pb; } AVFormatContext;
typedef struct { const char *name; } AVInputFormat;
typedef struct { int size; } AVPacket;
struct stream { const char *url; int64_t size; };
struct demux_lavf_opts { const char *yingyu_disc_index; };
typedef struct {
    bool any_ts_fixed;
    int linearize_ts, avif_flags, pcm_seek_hack_packet_size;
    double seek_delay;
    struct stream *stream;
    AVIOContext *pb;
    AVFormatContext *avfc;
    AVInputFormat *avif;
    AVStream *pcm_seek_hack;
    struct demux_lavf_opts *opts;
} lavf_priv_t;
typedef struct { lavf_priv_t *priv; bool ts_resets_possible; } demuxer_t;
typedef struct { int stream; int64_t position; int flags; } Call;
static Call calls[8];
static int call_count, stat_updates, byte_result, time_failures;
static bool wrong_landing;
static int64_t stream_get_size(struct stream *s) { return s->size; }
static int64_t avio_tell(AVIOContext *pb) { return pb->pos; }
static double av_q2d(AVRational q) { return (double)q.num/q.den; }
static AVPacket *av_packet_alloc(void) { return calloc(1,sizeof(AVPacket)); }
static int av_read_frame(AVFormatContext *s, AVPacket *p) { (void)s;(void)p; return -1; }
static void av_packet_free(AVPacket **p) { free(*p);*p=NULL; }
static void add_new_streams(demuxer_t *d) { (void)d; }
static void update_read_stats(demuxer_t *d) { (void)d; stat_updates++; }
static void av_strerror(int r,char *buf,size_t size) { snprintf(buf,size,"%d",r); }
static int av_seek_frame(AVFormatContext *s,int stream,int64_t pos,int flags) {
    if (call_count>=8) abort();
    calls[call_count++]=(Call){stream,pos,flags};
    if (flags & AVSEEK_FLAG_BYTE) {
        if (byte_result>=0) s->pb->pos=pos+(wrong_landing?192:0);
        return byte_result;
    }
    if (time_failures>0) { time_failures--; return -1; }
    return 0;
}
#include "old_demux_seek.c"
#include "new_demux_seek.c"

typedef struct {
    AVCodecParameters video_codec, audio_codec;
    AVStream video, second;
    AVStream *streams[2];
    AVIOContext pb;
    AVFormatContext avfc;
    AVInputFormat avif;
    struct stream input;
    struct demux_lavf_opts opts;
    lavf_priv_t priv;
    demuxer_t demux;
} Fixture;
static void init(Fixture *f) {
    memset(f,0,sizeof(*f));
    f->video_codec.codec_type=AVMEDIA_TYPE_VIDEO;
    f->audio_codec.codec_type=AVMEDIA_TYPE_AUDIO;
    f->video=(AVStream){&f->video_codec,4113,0,{1,90000}};
    f->second=(AVStream){&f->audio_codec,4352,1,{1,48000}};
    f->streams[0]=&f->video;f->streams[1]=&f->second;
    f->avfc=(AVFormatContext){2,f->streams,200000000,&f->pb};
    f->avif.name="mpegts";
    f->input=(struct stream){"yingyu-disc://abc/clip/00001.m2ts",192000};
    f->opts.yingyu_disc_index="YI1|abc|00001,4113,1000,0:0,900000:100,1800000:200,2700000:300";
    f->priv=(lavf_priv_t){.stream=&f->input,.pb=&f->pb,.avfc=&f->avfc,.avif=&f->avif,.opts=&f->opts,.seek_delay=.25};
    f->demux=(demuxer_t){&f->priv,true};
    call_count=stat_updates=byte_result=time_failures=0;wrong_landing=false;
}
static int checks;
static void check(const char *name,bool ok) {
    if(!ok) { fprintf(stderr,"FAIL %s calls=%d first=%lld flags=%d\n",name,call_count,(long long)calls[0].position,calls[0].flags);exit(1); }
    checks++;printf("PASS %s\n",name);
}
int main(void) {
    const char *scenarios[]={"eligible exact-seek landing","forward remains timestamp","factor remains existing byte ratio",
        "two videos remain timestamp","fixed timestamps remain timestamp","linearized timeline remains timestamp",
        "foreign session remains timestamp","ordinary URL remains timestamp","non-mpegts remains timestamp",
        "demuxer forbids byte seek","source length mismatch","video PID mismatch","zero-origin startup target",
        "target outside point coverage","missing index","byte failure falls back","wrong byte tell falls back",
        "byte and backward failure keep forward retry","initial linearize state becomes zero","codec delay respected",
        "fractional target stays before access point",
        "nonzero PTS startup target","startup target within first second",
        "codec padding before first PTS","target one second before first PTS",
        "more than one second before first PTS stays timestamp","first point beyond bounded prefix stays timestamp",
        "full second preroll retains normal point landing","beginning beyond final point stays timestamp",
        "beginning byte failure keeps timestamp fallback","beginning wrong byte tell keeps timestamp fallback",
        "beginning byte and timestamp failure keep forward retry","beginning validates all index blocks",
        "beginning rejects wrong session","beginning forward keeps timestamp","beginning factor keeps ratio seek",
        "beginning two videos keep timestamp","beginning linearized timeline keeps timestamp",
        "beginning fixed timestamps keep timestamp","beginning non-mpegts keeps timestamp",
        "beginning wrong PID keeps timestamp","beginning wrong size keeps timestamp",
        "beginning no-byte-seek format keeps timestamp","negative adjusted target keeps timestamp"};
    for(int old=1;old>=0;old--) {
        void (*seek)(demuxer_t*,double,int)=old?old_demux_seek_lavf:new_demux_seek_lavf;
        const char *version=old?"old":"new";
        Fixture f; char name[160];
        for(unsigned scenario=0;scenario<sizeof(scenarios)/sizeof(*scenarios);scenario++) {
            init(&f);int flags=0;double target=21.5;bool eligible=!old;
            int64_t expected=38400;
            if(scenario>=21) {
                f.input.size=1920000;
                f.opts.yingyu_disc_index="YI1|abc|00001,4113,10000,54000000:4096,54045000:4200,54900000:5000";
                target=600.75;expected=0;
            }
            switch(scenario) {
                case 0: break;
                case 1: flags=SEEK_FORWARD;eligible=false;break;
                case 2: flags=SEEK_FACTOR;target=.5;eligible=false;break;
                case 3: f.second.codecpar=&f.video_codec;eligible=false;break;
                case 4: f.priv.any_ts_fixed=true;eligible=false;break;
                case 5: f.priv.linearize_ts=1;eligible=false;break;
                case 6: f.input.url="yingyu-disc://other/clip/00001.m2ts";eligible=false;break;
                case 7: f.input.url="https://ordinary.invalid/movie.m2ts";eligible=false;break;
                case 8: f.avif.name="matroska,webm";eligible=false;break;
                case 9: f.priv.avif_flags=AVFMT_NO_BYTE_SEEK;eligible=false;break;
                case 10: f.input.size--;eligible=false;break;
                case 11: f.video.id=4114;eligible=false;break;
                case 12: target=.5;expected=0;break;
                case 13: target=45;eligible=false;break;
                case 14: f.opts.yingyu_disc_index="";eligible=false;break;
                case 15: byte_result=-1;break;
                case 16: wrong_landing=true;break;
                case 17: byte_result=-1;time_failures=1;break;
                case 18: f.priv.linearize_ts=-1;break;
                case 19: f.priv.seek_delay=1.0;target=21.5;expected=19200;break;
                case 20: target=21.249999;expected=19200;break;
                case 21: target=600.25;break;
                case 22: target=601.249999;break;
                case 23: target=600;break;
                case 24: target=600;f.priv.seek_delay=1.0;break;
                case 25: target=599.249999;eligible=false;break;
                case 26: f.opts.yingyu_disc_index="YI1|abc|00001,4113,10000,54000000:4097,54900000:5000";eligible=false;break;
                case 27: target=601.25;expected=4096*192;break;
                case 28: f.opts.yingyu_disc_index="YI1|abc|00001,4113,10000,54000000:1,54022500:2";eligible=false;break;
                case 29: byte_result=-1;break;
                case 30: wrong_landing=true;break;
                case 31: byte_result=-1;time_failures=1;break;
                case 32: f.opts.yingyu_disc_index="YI1|abc|00001,4113,10000,54000000:8,54900000:100|00002,0,10000,0:0,90000:1";eligible=false;break;
                case 33: f.input.url="yingyu-disc://other/clip/00001.m2ts";eligible=false;break;
                case 34: flags=SEEK_FORWARD;eligible=false;break;
                case 35: flags=SEEK_FACTOR;target=.5;eligible=false;break;
                case 36: f.second.codecpar=&f.video_codec;eligible=false;break;
                case 37: f.priv.linearize_ts=1;eligible=false;break;
                case 38: f.priv.any_ts_fixed=true;eligible=false;break;
                case 39: f.avif.name="matroska,webm";eligible=false;break;
                case 40: f.video.id=4114;eligible=false;break;
                case 41: f.input.size--;eligible=false;break;
                case 42: f.priv.avif_flags=AVFMT_NO_BYTE_SEEK;eligible=false;break;
                case 43: target=0;eligible=false;break;
            }
            seek(&f.demux,target,flags);
            bool ok=stat_updates==1;
            if(eligible) {
                ok &= calls[0].flags==AVSEEK_FLAG_BYTE && calls[0].stream==-1 && calls[0].position==expected;
                if(byte_result<0 || wrong_landing) {
                    const bool retry_forward=scenario==17 || scenario==31;
                    ok &= call_count==(retry_forward?3:2) && calls[1].flags==AVSEEK_FLAG_BACKWARD && calls[1].position==(int64_t)((target-f.priv.seek_delay)*AV_TIME_BASE);
                    if(retry_forward) ok &= calls[2].flags==0;
                } else ok &= call_count==1;
            } else if(flags & SEEK_FACTOR) {
                ok &= call_count==1 && calls[0].flags==(AVSEEK_FLAG_BACKWARD|AVSEEK_FLAG_BYTE) && calls[0].position==(int64_t)(f.input.size*target);
            } else {
                const bool retry_forward=scenario==17 || scenario==31;
                ok &= call_count==(retry_forward?2:1) && calls[0].flags==(flags&SEEK_FORWARD?0:AVSEEK_FLAG_BACKWARD) && calls[0].position==(int64_t)((target-(flags&SEEK_FORWARD?0:f.priv.seek_delay))*AV_TIME_BASE);
                if(retry_forward) ok &= calls[1].flags==0;
            }
            snprintf(name,sizeof(name),"%s %s",version,scenarios[scenario]);check(name,ok);
        }
    }
    printf("TOTAL %d\n",checks);
}
