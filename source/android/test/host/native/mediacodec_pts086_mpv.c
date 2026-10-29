/* Fixed MPV downstream timestamp functions; minimal synthetic type/log IO.
 * SPDX-License-Identifier: GPL-2.0-or-later
 * The source generator inserts the complete unchanged upstream functions.
 */
#include <stdint.h>
#include <stdio.h>
#include <math.h>

#define AV_NOPTS_VALUE INT64_MIN
#define MP_NOPTS_VALUE (-0x1p+63)
#define AV_TIME_BASE 1000000
#define AV_TIME_BASE_Q ((AVRational){1, AV_TIME_BASE})
#define MPMAX(a,b) ((a) > (b) ? (a) : (b))
#define MP_WARN(...) ((void)0)
#define VDCTRL_GET_BFRAMES 1
typedef struct AVRational { int num, den; } AVRational;
struct opts { int correct_pts; };
struct codec { int avi_dts; };
struct decoder { void *f; int (*control)(void *, int, void *); };
struct priv {
    struct opts *opts;
    struct codec *codec;
    struct decoder *decoder;
    double fps, first_packet_pdts, pts, codec_pts, codec_dts;
    int play_dir, has_broken_decoded_pts, has_broken_packet_pts;
    int num_codec_pts_problems, num_codec_dts_problems;
};
struct mp_image { double pts, dts; };

/* YINGYU_MPV_PTS086_FUNCTIONS */

static int passed, failed, count;
static struct opts opts = {1};
static struct codec codec = {0};

static struct priv state(double prior, double packet_seed)
{
    return (struct priv){.opts=&opts, .codec=&codec, .fps=24000.0/1001,
        .first_packet_pdts=packet_seed, .pts=prior, .codec_pts=prior,
        .codec_dts=MP_NOPTS_VALUE, .play_dir=1};
}

static double output(struct priv *p, int64_t original_pts, int64_t decoded_dts,
                     AVRational timebase)
{
    /* This IO boundary is the only old/new difference: the old wrapper loses
     * unknown as numeric zero; the repaired wrapper returns AV_NOPTS again.
     * C's separate complete queue/wrap replay validates that boundary itself.
     */
    int64_t frame_pts = original_pts;
#if !YINGYU_PTS086_NEW
    if (frame_pts == AV_NOPTS_VALUE) frame_pts=0;
#endif
    struct mp_image mpi = {.pts=mp_pts_from_av(frame_pts, &timebase),
                           .dts=mp_pts_from_av(decoded_dts, &timebase)};
    crazy_video_pts_stuff(p, &mpi);
    correct_video_pts(p, &mpi);
    return mpi.pts;
}

static void check(const char *name, int success)
{
    if (count++) printf(",");
    printf("{\"name\":\"%s\",\"result\":\"%s\"}", name,
           success ? "success" : "failure");
    if (success) passed++; else failed++;
}
static int near(double a, double b) { return fabs(a-b)<0.000001; }

int main(void)
{
    AVRational us = {1,1000000};
    const AVRational ts = {1,90000};
    struct priv p;
    double a,b;
    printf("{\"tests\":[");

    p=state(1446.111333,1443.4837);
    a=output(&p,AV_NOPTS_VALUE,AV_NOPTS_VALUE,us);
    check("known1446_then_unknown_uses_native_frame_step",near(a,1446.153041333333));

    p=state(1446.111333,1443.4837);
    a=output(&p,AV_NOPTS_VALUE,AV_NOPTS_VALUE,us);
    b=output(&p,AV_NOPTS_VALUE,AV_NOPTS_VALUE,us);
    check("consecutive_unknown_never_becomes_real_zero",a>1446 && near(b,1446.194749666667));

    p=state(1446.111333,1443.4837);
    output(&p,AV_NOPTS_VALUE,AV_NOPTS_VALUE,us);
    a=output(&p,1446194744,AV_NOPTS_VALUE,us);
    check("known_next_pts_is_preserved",near(a,1446.194744));

    p=state(1446.111333,1443.4837);
    a=output(&p,0,AV_NOPTS_VALUE,us);
    check("legal_zero_is_preserved",a==0 && p.pts==0);

    p=state(-0.6,-0.6);
    a=output(&p,-500000,AV_NOPTS_VALUE,us);
    check("legal_negative_pts_is_preserved",a==-0.5);

    p=state(1446.0,1443.4837);
    int same=1;
    const int64_t presentation_order[]={1446111333,1446153044,1446194744};
    for (unsigned i=0;i<sizeof(presentation_order)/sizeof(*presentation_order);i++)
        same &= near(output(&p,presentation_order[i],AV_NOPTS_VALUE,us),presentation_order[i]/1e6);
    check("b_frame_returned_presentation_order_is_preserved",same);

    /* The existing decf_reset/reset_decoder contract clears p->pts and
     * first_packet_pdts. A subsequent packet supplies the new seed. This
     * injects that contract as IO; it is not a full seek implementation. */
    p=state(MP_NOPTS_VALUE,2000.0);
    a=output(&p,AV_NOPTS_VALUE,AV_NOPTS_VALUE,us);
    check("seek_reset_unknown_uses_new_packet_seed",a==2000.0);

    p=state(MP_NOPTS_VALUE,0);
    a=output(&p,0,AV_NOPTS_VALUE,us);
    check("seek_to_legal_zero_remains_zero",a==0);

    p=state(MP_NOPTS_VALUE,MP_NOPTS_VALUE);
    a=output(&p,AV_NOPTS_VALUE,AV_NOPTS_VALUE,us);
    check("no_clock_or_packet_seed_retains_native_zero_fallback",a==0);

    p=state(10,10); p.fps=0;
    a=output(&p,AV_NOPTS_VALUE,AV_NOPTS_VALUE,us);
    check("unknown_fps_retains_native_25fps_fallback",near(a,10.04));

    p=state(1446.111333,1443.4837);
    a=output(&p,AV_NOPTS_VALUE,1446153044,us);
    check("actual_decoded_dts_fallback_is_preserved",near(a,1446.153044));

    p=state(-1,-1);
    a=output(&p,-45000,AV_NOPTS_VALUE,ts);
    b=output(&p,0,AV_NOPTS_VALUE,ts);
    check("native_timebase_conversion_negative_and_zero",a==-0.5 && b==0);

    AVRational invalid={0,0};
    check("invalid_timebase_uses_native_microsecond_default",
          near(mp_pts_from_av(1446111333,&invalid),1446.111333));

    p=state(1446.111333,1443.4837);
    for (int i=0;i<24;i++) a=output(&p,AV_NOPTS_VALUE,AV_NOPTS_VALUE,us);
    check("long_unknown_uses_existing_decoder_estimate",near(a,1447.112333));

    check("av_nopts_conversion_is_distinct_from_numeric_zero",
          mp_pts_from_av(AV_NOPTS_VALUE,&us)==MP_NOPTS_VALUE && mp_pts_from_av(0,&us)==0);
    printf("],\"passed\":%d,\"failed\":%d,\"total\":%d}\n",passed,failed,count);
    return failed ? 1 : 0;
}
