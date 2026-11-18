#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "disc_seek_index.h"

enum { AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_AUDIO, SEEK_FORWARD = 1,
       SEEK_FACTOR = 2, AVFMT_NO_BYTE_SEEK = 4, AVSEEK_FLAG_BYTE = 8 };
typedef struct { int codec_type; } Codec;
typedef struct { Codec *codecpar; int id; } AVStream;
typedef struct { unsigned nb_streams; AVStream **streams; } Format;
typedef struct { const char *name; } Input;
struct info { bool *sh; };
struct stream { const char *url; int64_t size; };
struct options { const char *yingyu_disc_index; };
typedef struct {
    Format *avfc;
    struct info **streams;
    unsigned num_streams;
    Input *avif;
    struct stream *stream;
    struct options *opts;
    void *pb;
    bool any_ts_fixed;
    int linearize_ts, avif_flags;
} Private;

static int chosen_mode;
static int64_t logical_position;
static bool fail_byte_seek;
static char diagnostic[100];
#define MP_VERBOSE(context, ...) ((void)snprintf(diagnostic, sizeof(diagnostic), __VA_ARGS__))

static bool demux_stream_is_selected(bool *selected) { return *selected; }
static int64_t stream_get_size(struct stream *stream) { return stream->size; }
static int av_seek_frame(Format *format, int stream, int64_t target, int flags)
{
    (void)format;
    (void)stream;
    chosen_mode = flags;
    logical_position = fail_byte_seek && flags == AVSEEK_FLAG_BYTE ? target + 1 : target;
    return 0;
}
static int64_t avio_tell(void *pb) { (void)pb; return logical_position; }

static void seek(Private *priv, double seek_pts, int flags)
{
    int seek_stream = -1, avsflags = 0;
    int64_t seek_pts_av = (int64_t)(seek_pts * 1000000);
    /* GENERATED_SEEK_BLOCK */
}

#define CHECK(name, expression) do { if (!(expression)) { \
    fprintf(stderr, "FAIL %s\n", name); return 1; \
} printf("PASS %s\n", name); } while (0)

int main(void)
{
    Codec video = {AVMEDIA_TYPE_VIDEO}, audio = {AVMEDIA_TYPE_AUDIO};
    AVStream main_video = {&video, 4113}, auxiliary = {&video, 4114}, soundtrack = {&audio, 4352};
    AVStream *tracks[] = {&main_video, &auxiliary, &soundtrack};
    Format format = {3, tracks};
    Input input = {"mpegts"};
    bool play_main = true, play_aux = false;
    struct info main_info = {&play_main}, aux_info = {&play_aux};
    struct info *infos[] = {&main_info, &aux_info, NULL};
    struct stream stream = {"yingyu-disc://session-1/clip/00001.m2ts", 1920000};
    struct options options = {"YI1|session-1|00001,4113,10000,54000000:0,54090000:100,54180000:200,54270000:300,54360000:400"};
    Private priv = {&format, infos, 3, &input, &stream, &options, &format, false, 0, 0};

    seek(&priv, 603.5, 0);
    CHECK("selected video uses real CLPI landing despite unselected second video", chosen_mode == AVSEEK_FLAG_BYTE && logical_position == 38400);
    play_aux = true;
    seek(&priv, 603.5, 0);
    CHECK("two selected videos retain timestamp seek", chosen_mode == 0);
    play_main = false;
    seek(&priv, 603.5, 0);
    CHECK("selected video with different PID cannot use this CLPI", chosen_mode == 0);
    play_aux = false;
    seek(&priv, 603.5, 0);
    CHECK("unknown selection with two videos retains timestamp seek", chosen_mode == 0);
    format.nb_streams = 1;
    seek(&priv, 603.5, 0);
    CHECK("single-video behavior before selection stays indexed", chosen_mode == AVSEEK_FLAG_BYTE && logical_position == 38400);
    seek(&priv, 603.5, SEEK_FORWARD);
    CHECK("explicit forward seek stays on timestamp search", chosen_mode == 0);
    fail_byte_seek = true;
    seek(&priv, 603.5, 0);
    CHECK("invalid byte landing still invokes timestamp fallback", chosen_mode == 0);
    fail_byte_seek = false;
    stream.size++;
    seek(&priv, 603.5, 0);
    CHECK("file length mismatch retains timestamp search", chosen_mode == 0);
    return 0;
}
