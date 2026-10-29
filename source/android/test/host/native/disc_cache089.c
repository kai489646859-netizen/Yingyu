#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <math.h>
#include <assert.h>
#define MP_NOPTS_VALUE (-0x1p+63)
#define MPMIN(a,b) ((a)<(b)?(a):(b))
#define MPMAX(a,b) ((a)>(b)?(a):(b))
#define MP_PTS_OR_DEF(a,d) ((a)==MP_NOPTS_VALUE?(d):(a))
#define MP_PTS_MAX(a,b) MPMAX(MP_PTS_OR_DEF(a,b),MP_PTS_OR_DEF(b,a))
#define MP_ADD_PTS(a,b) ((a)==MP_NOPTS_VALUE?(a):((a)+(b)))
#define MAX_SEEK_RANGES 10
enum {STREAM_VIDEO,STREAM_AUDIO,STREAM_SUB,STREAM_TYPE_COUNT};
struct queue {void *head;double last_ts;};
struct demux_stream {bool eager,eof,ignore_eof,still_image;void *reader_head;double base_ts;struct queue *queue;int type;};
struct sh_stream {struct demux_stream *ds;};
struct demux_opts {bool yingyu_cache_av_min;};
struct demux_cached_range {double seek_start,seek_end;bool is_bof,is_eof;};
struct demuxer;
struct demux_internal {
 struct demuxer *d_user;int lock;bool eof,seeking,reading,threading;
 int64_t total_bytes;double seeking_in_progress,demux_ts,ts_offset;
 int low_level_seeks,num_streams,num_ranges;uint64_t bytes_per_second,byte_level_seeks;
 void *cache;struct sh_stream **streams;struct demux_cached_range **ranges;
};
struct demuxer {struct demux_internal *in;struct demux_opts *opts;};
struct demux_seek_range {double start,end;};
struct demux_reader_state {
 bool eof,underrun,idle,bof_cached,eof_cached;double ts_duration,ts_reader,ts_end;
 int64_t total_bytes,fw_bytes,file_cache_bytes;double seeking;int low_level_seeks;
 uint64_t byte_level_seeks;double ts_last;uint64_t bytes_per_second;
 int num_seek_ranges;struct demux_seek_range seek_ranges[MAX_SEEK_RANGES];
};
static void pthread_mutex_lock(int *p) {(void)p;}
static void pthread_mutex_unlock(int *p) {(void)p;}
static int demux_cache_get_size(void *p) {(void)p;return 4096;}
static int get_forward_buffered_bytes(struct demux_stream *p) {return p->reader_head?8192:0;}
#include "old_reader.c"
#include "new_reader.c"
struct scenario {char *name;double ar,ae,vr,ve,want;bool audio,video,empty_audio,unknown,eof_audio,seek;};
int main(void) {
 const double N=MP_NOPTS_VALUE;
 struct scenario cases[]={
  {"balanced",100,110,100,110,10,true,true},
  {"future_video_end",2323,2323.208,2323,8245,.208,true,true},
  {"future_audio_end",100,6000,100,101,1,true,true},
  {"different_reader_positions",100,108,103,112,8,true,true},
  {"audio_only",50,56,N,N,6,true,false},
  {"video_only",N,N,50,56,6,false,true},
  {"unknown_audio_known_video",N,N,50,55,5,true,true},
  {"all_unknown",N,N,N,N,-1,true,true},
  {"empty_audio",100,101,100,110,0,true,true,true},
  {"eof_empty_audio",100,101,100,110,10,true,true,true,false,true},
  {"seeking",100,101,100,110,0,true,true,false,false,false,true},
  {"negative_real_pts",-2,3,-2,3,5,true,true},
  {"regressed_invalid_audio",100,99,100,104,4,true,true},
  {"zero_duration",100,100,100,104,0,true,true},
 };
 int passed=0,old_passed=0,off=0;
 for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
  struct scenario s=cases[i];struct queue aq={(void*)1,s.ae},vq={(void*)1,s.ve};
  struct demux_stream a={.eager=s.audio,.eof=s.eof_audio,.reader_head=s.empty_audio?NULL:(void*)1,.base_ts=s.ar,.queue=&aq,.type=STREAM_AUDIO};
  if(s.eof_audio)aq.head=NULL;
  struct demux_stream v={.eager=s.video,.reader_head=(void*)1,.base_ts=s.vr,.queue=&vq,.type=STREAM_VIDEO};
  struct sh_stream as={&a},vs={&v};struct sh_stream *streams[]={&as,&vs};
  struct demux_opts opts={false};struct demuxer d={.opts=&opts};
  struct demux_internal in={.d_user=&d,.streams=streams,.num_streams=2,.reading=true,.threading=true,.seeking=s.seek,.ts_offset=17};d.in=&in;
  struct demux_reader_state old,updated,disabled;
  old_demux_get_reader_state(&d,&old);new_demux_get_reader_state(&d,&disabled);
  assert(old.ts_duration==disabled.ts_duration && old.ts_reader==disabled.ts_reader && old.ts_end==disabled.ts_end && old.idle==disabled.idle && old.underrun==disabled.underrun && old.fw_bytes==disabled.fw_bytes);off++;
  opts.yingyu_cache_av_min=true;new_demux_get_reader_state(&d,&updated);
  bool good=fabs(updated.ts_duration-s.want)<.00001;
  bool previous=fabs(old.ts_duration-s.want)<.00001;
  printf("%s new %s; old=%f new=%f expected=%f\n",good?"PASS":"FAIL",s.name,old.ts_duration,updated.ts_duration,s.want);
  passed+=good;old_passed+=previous;
 }
 printf("{\"cases\":14,\"new_passed\":%d,\"old_passed\":%d,\"default_off_equivalent\":%d}\n",passed,old_passed,off);
 return passed==14 && off==14?0:1;
}
