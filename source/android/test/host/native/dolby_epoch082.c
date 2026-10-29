/* Complete production generation API and draw/flip guard; synthetic codec
 * serial, VO frames and warning IO. No MPV, decoder, Android, GL or pixels. */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#define AVERROR(x) (-(x))
#define IMGFMT_MEDIACODEC 1
#define IMGFMT_YUV420P10 2
typedef struct { int delay_flush; atomic_int serial; } Codec;
typedef struct { Codec *ctx; atomic_int released; int serial; int64_t pts; } AVMediaCodecBuffer;
struct mp_image { struct { bool yingyu_dovi_raw; } params; int imgfmt; void *planes[4]; };
struct priv { bool yy_skip_flip,frame_pending,yy_stale_logged,want_reset; uint64_t yy_stale_id; void *sw; };
struct vo { struct priv *priv; };
struct vo_frame { struct mp_image *current; uint64_t frame_id; };
static int warnings,errors,submits;
static bool started,submit_fails;
#define MP_WARN(...) ((void)warnings++)
#define MP_ERR(...) ((void)errors++)
static bool pl_swapchain_submit_frame(void *sw)
{
    (void)sw;assert(started);started=false;submits++;return !submit_fails;
}

/* YINGYU_CODEC_EPOCH_API */
/* YINGYU_DOVI_EPOCH_GUARD */

static Codec codec;
static AVMediaCodecBuffer buffer;
static struct mp_image image;
static struct priv p;
static struct vo vo;
static struct vo_frame frame;
static void reset(void)
{
    codec=(Codec){.serial=1};
    buffer=(AVMediaCodecBuffer){.ctx=&codec,.serial=1,.pts=1234567};
    image=(struct mp_image){.params={true},.imgfmt=IMGFMT_MEDIACODEC};
    image.planes[3]=&buffer;
    p=(struct priv){0}; vo=(struct vo){&p};
    frame=(struct vo_frame){&image,10}; warnings=errors=submits=0;
    started=submit_fails=false;
}
int main(void)
{
    int64_t pts=0;
    reset();
    assert(av_mediacodec_yingyu_buffer_current(&buffer)==1);
    assert(av_mediacodec_yingyu_buffer_pts(&buffer,&pts)==0 && pts==1234567);
    assert(!yy_dovi_skip_draw(&vo,&frame) && !yy_dovi_skip_flip(&p));

    // A same-generation buffer can already have been presented. Its acquired
    // AImage may be reused; the read-only generation guard must allow it.
    atomic_store(&buffer.released,1);
    assert(av_mediacodec_yingyu_buffer_current(&buffer)==1);
    assert(av_mediacodec_yingyu_buffer_pts(&buffer,&pts)<0);
    assert(!yy_dovi_skip_draw(&vo,&frame) && !yy_dovi_skip_flip(&p));

    // The old mapper would report a generic error for this real flush serial.
    // The new complete guard rejects it before touching the old render queue.
    reset(); atomic_fetch_add(&codec.serial,1);
    assert(av_mediacodec_yingyu_buffer_pts(&buffer,&pts)<0);
    assert(av_mediacodec_yingyu_buffer_current(&buffer)==0);
    assert(yy_dovi_skip_draw(&vo,&frame));
    assert(yy_dovi_skip_flip(&p) && !p.yy_skip_flip && warnings==1);
    assert(yy_dovi_skip_draw(&vo,&frame));
    assert(yy_dovi_skip_flip(&p) && warnings==1);
    frame.frame_id++;
    assert(yy_dovi_skip_draw(&vo,&frame));
    assert(yy_dovi_skip_flip(&p) && warnings==2);

    // First fresh frame after that flush uses the existing queue reset/map.
    buffer.serial=atomic_load(&codec.serial); frame.frame_id++;
    assert(!yy_dovi_skip_draw(&vo,&frame));
    assert(!yy_dovi_skip_flip(&p));
    assert(av_mediacodec_yingyu_buffer_pts(&buffer,&pts)==0 && pts==1234567);

    // A frame acquired by the normal path must never be abandoned by flip.
    reset(); atomic_fetch_add(&codec.serial,1); p.frame_pending=true;
    assert(yy_dovi_skip_draw(&vo,&frame));
    assert(!yy_dovi_skip_flip(&p) && !p.yy_skip_flip && p.frame_pending);

    // Ordinary HDR/SDR and software paths never enter the raw-Dolby guard.
    reset(); atomic_fetch_add(&codec.serial,1); image.params.yingyu_dovi_raw=false;
    assert(!yy_dovi_skip_draw(&vo,&frame) && !yy_dovi_skip_flip(&p));
    image.params.yingyu_dovi_raw=true; image.imgfmt=IMGFMT_YUV420P10;
    assert(!yy_dovi_skip_draw(&vo,&frame) && !yy_dovi_skip_flip(&p));
    frame.current=NULL;
    assert(!yy_dovi_skip_draw(&vo,&frame) && !yy_dovi_skip_flip(&p));

    // Unknown inputs do not gain the meaning "obsolete" or hide an error.
    reset(); image.planes[3]=NULL;
    assert(av_mediacodec_yingyu_buffer_current(NULL)<0);
    assert(!yy_dovi_skip_draw(&vo,&frame));
    image.planes[3]=&buffer; buffer.ctx=NULL;
    assert(av_mediacodec_yingyu_buffer_current(&buffer)<0);
    assert(!yy_dovi_skip_draw(&vo,&frame));

    // In delayed-flush mode FFmpeg intentionally retains buffer validity until
    // the codec is actually flushed. Mirror that pinned upstream contract.
    reset(); codec.delay_flush=1; atomic_fetch_add(&codec.serial,1);
    assert(av_mediacodec_yingyu_buffer_current(&buffer)==1);
    assert(!yy_dovi_skip_draw(&vo,&frame));
    codec.delay_flush=0;
    assert(yy_dovi_skip_draw(&vo,&frame) && yy_dovi_skip_flip(&p));

    // Exact TOCTOU: early check current, swapchain acquired, codec flushed,
    // actual mapper's PTS check fails. Recheck marks obsolete and balances
    // the start/submit lock without allowing actual buffer presentation.
    reset(); assert(!yy_dovi_skip_draw(&vo,&frame)); started=true;
    atomic_fetch_add(&codec.serial,1);
    assert(av_mediacodec_yingyu_buffer_pts(&buffer,&pts)<0);
    assert(yy_dovi_mark_obsolete(&vo,&image,frame.frame_id));
    assert(p.want_reset && yy_dovi_finish_obsolete_draw(&vo));
    assert(submits==1 && !started && !p.frame_pending && errors==0);
    assert(yy_dovi_skip_flip(&p));
    buffer.serial=atomic_load(&codec.serial);frame.frame_id++;
    assert(!yy_dovi_skip_draw(&vo,&frame));
    assert(!yy_dovi_finish_obsolete_draw(&vo) && !yy_dovi_skip_flip(&p));
    assert(submits==1);

    // The same recheck also discards a frame invalidated just after mapping.
    reset(); assert(!yy_dovi_skip_draw(&vo,&frame)); started=true;
    assert(av_mediacodec_yingyu_buffer_pts(&buffer,&pts)==0);
    atomic_store(&buffer.released,1);atomic_fetch_add(&codec.serial,1);
    assert(yy_dovi_mark_obsolete(&vo,&image,frame.frame_id));
    assert(yy_dovi_finish_obsolete_draw(&vo) && yy_dovi_skip_flip(&p));
    assert(submits==1 && !started);

    // Failure to finish an acquired frame remains a real fixed error.
    reset(); started=submit_fails=true;atomic_fetch_add(&codec.serial,1);
    assert(yy_dovi_mark_obsolete(&vo,&image,frame.frame_id));
    assert(yy_dovi_finish_obsolete_draw(&vo));
    assert(errors==1 && !started && yy_dovi_skip_flip(&p));
    puts("{\"passed\":17,\"failed\":0,\"scope\":\"Complete production codec generation APIs and VO draw/finish/flip guard, synthetic serial/frame/swapchain-lock/warning IO; no decoder, Android, GPU or picture validation\"}");
    return 0;
}
