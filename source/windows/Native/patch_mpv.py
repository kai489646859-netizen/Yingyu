"""Apply the bounded native-DV integration to the pinned pristine mpv tree."""
from pathlib import Path
import shutil, sys

root=Path(sys.argv[1]).resolve()
native=Path(__file__).resolve().parent
def change(path,old,new,count=1):
    p=root/path;s=p.read_text(encoding='utf-8')
    if s.count(old)!=count: raise RuntimeError(f'{path}: expected {count} anchors, got {s.count(old)}')
    p.write_text(s.replace(old,new),encoding='utf-8',newline='\n')

change('demux/stheader.h','    uint8_t dv_profile;','    uint8_t dv_profile;\n    uint8_t dv_compatibility;')
change('demux/demux_lavf.c','codec->dv_profile = cfg->dv_profile;','codec->dv_profile = cfg->dv_profile;\n        sh->codec->dv_compatibility = cfg->dv_bl_signal_compatibility_id;')
change('demux/demux_mkv.c','sh_v->dv_profile = track->dovi_config->dv_profile;','sh_v->dv_profile = track->dovi_config->dv_profile;\n        sh_v->dv_compatibility = track->dovi_config->dv_bl_signal_compatibility_id;')
change('demux/dovi_split.c','el->codec->dv_profile = cfg->dv_profile;','el->codec->dv_profile = cfg->dv_profile;\n    el->codec->dv_compatibility = cfg->dv_bl_signal_compatibility_id;')
change('demux/demux_lavf.c','    if (!el_sh || !bl_sh)\n        return;\n\n    // Group storage', '''    if (!el_sh || !bl_sh)
        return;
    // FFmpeg explicitly identifies standard BDMV BL/EL PIDs as a Dolby group
    // even without a DOVI descriptor. Preserve explicit container profiles;
    // infer P7/HDR10 compatibility only for this confirmed dual-HEVC group.
    if(el_st->codecpar->codec_id==AV_CODEC_ID_HEVC && bl_st->codecpar->codec_id==AV_CODEC_ID_HEVC) {
        if(!bl_sh->codec->dv_profile) {
            bl_sh->codec->dv_profile=el_sh->codec->dv_profile ? el_sh->codec->dv_profile : 7;
            bl_sh->codec->dv_compatibility=el_sh->codec->dv_profile ? el_sh->codec->dv_compatibility : 6;
        }
        if(!el_sh->codec->dv_profile) {
            el_sh->codec->dv_profile=bl_sh->codec->dv_profile;
            el_sh->codec->dv_compatibility=bl_sh->codec->dv_compatibility;
        }
        bl_sh->codec->dv_el_present=true;
        bl_sh->codec->dovi=el_sh->codec->dovi=true;
    }

    // Group storage''')
change('video/mp_image.h','struct mp_image_params {','struct mp_image_params {\n    int dv_profile, dv_compatibility;\n    bool dv_el_present;')
change('video/mp_image.c','    dst->params.vflip = src->params.vflip;','    dst->params.dv_profile=src->params.dv_profile;\n    dst->params.dv_compatibility=src->params.dv_compatibility;\n    dst->params.dv_el_present=src->params.dv_el_present;\n    dst->params.vflip = src->params.vflip;')
change('video/mp_image.c','        dst->params.no_dovi = p->no_dovi;','        dst->params.dv_profile=p->dv_profile;\n        dst->params.dv_compatibility=p->dv_compatibility;\n        dst->params.dv_el_present=p->dv_el_present;\n        dst->params.no_dovi = p->no_dovi;')
change('video/mp_image.c','    return p1->imgfmt == p2->imgfmt &&','    return p1->dv_profile==p2->dv_profile && p1->dv_compatibility==p2->dv_compatibility && p1->dv_el_present==p2->dv_el_present &&\n           p1->imgfmt == p2->imgfmt &&')
change('video/decode/vd_lavc.c','    if (mpi->imgfmt == IMGFMT_CUDA && !mpi->planes[0]) {','    mpi->params.dv_profile = ctx->codec->dv_profile;\n    mpi->params.dv_compatibility = ctx->codec->dv_compatibility;\n    mpi->params.dv_el_present = ctx->codec->dv_el_present;\n\n    if (mpi->imgfmt == IMGFMT_CUDA && !mpi->planes[0]) {')
change('common/global.h','#define MPV_MPV_H','#define MPV_MPV_H\n#include <stdatomic.h>\n#include <stdint.h>')
change('common/global.h','    struct mp_log *log;','    struct mp_log *log;\n    atomic_uint_fast64_t native_dv_epoch;\n    atomic_uint_fast64_t native_dv_failed_epoch;\n    atomic_uint native_dv_failure_reason;\n    atomic_bool native_dv_ui_safe;')
change('player/client.c','    mpctx->global->client_api = mpctx->clients;','    mpctx->global->client_api = mpctx->clients;\n    atomic_init(&mpctx->global->native_dv_epoch, 1);\n    atomic_init(&mpctx->global->native_dv_failed_epoch, 0);\n    atomic_init(&mpctx->global->native_dv_failure_reason, 0);\n    atomic_init(&mpctx->global->native_dv_ui_safe, false);')
change('player/client.h','#endif', '''
uint64_t mp_native_dv_epoch(struct mpv_global *global);
void mp_native_dv_failure(struct mpv_global *global, uint64_t epoch, unsigned reason);
#endif''')
change('player/client.c','static void do_kill(void *ptr)', '''struct native_dv_failure {
    struct MPContext *mpctx;
    uint64_t epoch;
    unsigned reason;
};
uint64_t mp_native_dv_epoch(struct mpv_global *global)
{
    return atomic_load(&global->native_dv_epoch);
}
static void native_dv_pause(void *ptr)
{
    struct native_dv_failure *f = ptr;
    if (mp_native_dv_epoch(f->mpctx->global) == f->epoch) {
        MP_ERR(f->mpctx, "Native Dolby frame incomplete; paused (epoch=%"PRIu64" reason=%u).\\n", f->epoch, f->reason);
        set_pause_state(f->mpctx, true);
        mp_client_property_change(f->mpctx, "native-dolby-status");
    }
    talloc_free(f);
}
void mp_native_dv_failure(struct mpv_global *global, uint64_t epoch, unsigned reason)
{
    if (!global->client_api || epoch != mp_native_dv_epoch(global)) return;
    if (atomic_exchange(&global->native_dv_failed_epoch, epoch) == epoch) return;
    atomic_store(&global->native_dv_failure_reason,reason);
    struct native_dv_failure *f = talloc(NULL, struct native_dv_failure);
    *f = (struct native_dv_failure){global->client_api->mpctx, epoch, reason};
    mp_dispatch_enqueue(f->mpctx->dispatch, native_dv_pause, f);
}
static void do_kill(void *ptr)''')
change('player/video.c','#include \"common/common.h\"','#include \"common/common.h\"\n#include \"common/global.h\"')
change('player/video.c','void reset_video_state(struct MPContext *mpctx)\n{','void reset_video_state(struct MPContext *mpctx)\n{\n    atomic_fetch_add(&mpctx->global->native_dv_epoch, 1);')
change('filters/f_enhancement_pair.c','#include <libavutil/buffer.h>','#include <libavutil/buffer.h>\n#include <libavutil/frame.h>\n#include <libavutil/dovi_meta.h>\n#include "player/client.h"\n#include "common/yydv_complete.h"')
change('filters/f_enhancement_pair.c','    bool el_seen;','    bool el_seen;\n    bool failed;\n    uint64_t epoch;')
change('filters/f_enhancement_pair.c','    if (bl->params.no_dovi || bl->dovi || !el->dovi)','    if (!bl->params.dv_profile) {\n        bl->params.dv_profile=el->params.dv_profile;\n        bl->params.dv_compatibility=el->params.dv_compatibility;\n    }\n    if (bl->params.no_dovi || bl->dovi || !el->dovi)')
change('filters/f_enhancement_pair.c','    drain_pin(f, in,','    if (!p->epoch) p->epoch=mp_native_dv_epoch(f->global);\n    if (p->failed) return;\n\n    drain_pin(f, in,')
change('filters/f_enhancement_pair.c','        int cmp = p->num_el_pending > 0', '''        if (bl->pts==MP_NOPTS_VALUE || (p->num_el_pending && p->el_pending[0]->pts==MP_NOPTS_VALUE)) {
            p->failed=true;
            mp_native_dv_failure(f->global,p->epoch,13);
            return;
        }
        int cmp = p->num_el_pending > 0''')
# A missing EL is acceptable only when THIS frame's parsed header proves zero
# residual. Missing metadata must not turn P7 into an unnoticed BL-only stream.
change('filters/f_enhancement_pair.c','        MP_VERBOSE(f, "emitting BL', '''        bool zero_residual=false;
        for (int i=0;i<bl->num_ff_side_data;i++) {
            if (bl->ff_side_data[i].type!=AV_FRAME_DATA_DOVI_METADATA) continue;
            AVBufferRef *b=bl->ff_side_data[i].buf;
            zero_residual=yydv_required_el(b)==0;
        }
        if (!zero_residual) {
            p->failed=true;
            MP_ERR(f,"Required Dolby enhancement frame missing; refusing BL-only output.\\n");
            mp_native_dv_failure(f->global,p->epoch,12);
            return;
        }
        MP_VERBOSE(f, "emitting BL''')
change('filters/f_enhancement_pair.c','    p->bl_eof = false;','    p->failed=false; p->epoch=0;\n    p->bl_eof = false;')
change('filters/f_enhancement_pair.c','        MP_WARN(f, "Failed to set up enhancement-layer decoder; "\n                "rendering base layer only.\\n");','        MP_ERR(f, "Failed to set up required enhancement-layer decoder.\\n");\n        mp_native_dv_failure(f->global,mp_native_dv_epoch(f->global),12);')

change('video/out/vo.h','    VOCTRL_EXTERNAL_RESIZE,','    VOCTRL_EXTERNAL_RESIZE,\n    VOCTRL_NATIVE_DV_UI_SAFE, // bool*; synchronous restoration before UI\n    VOCTRL_NATIVE_DV_STATUS, // struct yydv_property_status*')
shutil.copyfile(native/'src/yydv_complete.h',root/'common/yydv_complete.h')
out=root/'video/out'
for name in ['yydv_mpv.h','yydv_mpv.c']: shutil.copyfile(native/'src'/name,out/name)
shutil.copyfile(native/'include/yydv.h',out/'yydv.h')
change('video/out/vo_gpu_next.c','struct priv {','#include "yydv_mpv.h"\n#include "player/client.h"\n\nstruct priv {\n    struct yydv_mpv native_dv;')
change('video/out/vo_gpu_next.c','static bool draw_frame(struct vo *vo, struct vo_frame *frame)','#include "yydv_mpv.c"\n\nstatic bool draw_frame(struct vo *vo, struct vo_frame *frame)')
change('video/out/vo_gpu_next.c','    update_options(vo);\n\n    struct pl_render_params params', '''    update_options(vo);
#if HAVE_WIN32_DESKTOP
    int native_result=yydv_try_frame(vo,frame);
    if (native_result) {p->frame_pending=false;return native_result>0;}
    p->native_dv.owned_frame=false;
#endif

    struct pl_render_params params''')
change('video/out/vo_gpu_next.c','static void flip_page(struct vo *vo)\n{\n    struct priv *p = vo->priv;', '''static void flip_page(struct vo *vo)
{
    struct priv *p = vo->priv;
#if HAVE_WIN32_DESKTOP
    if(p->native_dv.fatal) return;
    if(p->native_dv.owned_frame) {
        int result=p->native_dv.present(p->native_dv.context);
        yydv_refresh(vo);
        if(result<0)yydv_fail(vo,p->native_dv.status.reason);
        if(result<=0){p->native_dv.owned_frame=false;p->want_reset=true;vo->want_redraw=true;}
        return;
    }
#endif''')
change('video/out/vo_gpu_next.c','static void get_vsync(struct vo *vo, struct vo_vsync_info *info)\n{\n    struct priv *p = vo->priv;', '''static void get_vsync(struct vo *vo, struct vo_vsync_info *info)
{
    struct priv *p = vo->priv;
    if(p->native_dv.owned_frame) return;''')
change('video/out/vo_gpu_next.c','static void resize(struct vo *vo)\n{\n    struct priv *p = vo->priv;','static void resize(struct vo *vo)\n{\n    struct priv *p = vo->priv;\n    p->native_dv.retry_after=0;')
change('video/out/vo_gpu_next.c','    switch (request) {\n    case VOCTRL_SET_PANSCAN:', '''    switch (request) {
#if HAVE_WIN32_DESKTOP
    case VOCTRL_NATIVE_DV_UI_SAFE:
    case VOCTRL_NATIVE_DV_STATUS:
        return yydv_control(vo,request,data);
#endif
    case VOCTRL_SET_PANSCAN:''')
change('video/out/vo_gpu_next.c','    case VOCTRL_RESET:\n        // Defer','    case VOCTRL_RESET:\n#if HAVE_WIN32_DESKTOP\n        if(p->native_dv.context)p->native_dv.reset(p->native_dv.context,mp_native_dv_epoch(vo->global));\n        p->native_dv.owned_frame=false;\n#endif\n        // Defer')
change('video/out/vo_gpu_next.c','    // Drain any in-flight uploads.', '''#if HAVE_WIN32_DESKTOP
    if(p->native_dv.context)vo_w32_run_on_thread(vo,yydv_destroy_window,&p->native_dv);
    if(p->native_dv.module)FreeLibrary(p->native_dv.module);
#endif
    // Drain any in-flight uploads.''')
change('video/out/vo_gpu_next.c','            MP_WARN(vo, "Failed setting up enhancement layer; "\n                    "rendering base layer only.\\n");','            MP_ERR(vo,"Required enhancement layer setup failed; refusing BL-only output.\\n");\n            mp_native_dv_failure(vo->global,mp_native_dv_epoch(vo->global),15);\n            return false;')
change('video/out/vo_gpu_next.c','    return slot_reconfig(p, &p->el_hwdec, fp->el_hwdec, &el_mpi->params) &&\n           slot_acquire(p, &p->el_hwdec, bl_mpi, el_mpi, frame);','    bool ok=slot_reconfig(p, &p->el_hwdec, fp->el_hwdec, &el_mpi->params) &&\n           slot_acquire(p, &p->el_hwdec, bl_mpi, el_mpi, frame);\n    if(!ok)mp_native_dv_failure(fp->vo->global,mp_native_dv_epoch(fp->vo->global),15);\n    return ok;')
# Only after the native attempt refused, ask the ordinary renderer for HDR10.
# Do not set PQ prior to the native attempt, as that changes the desktop state.
change('video/out/vo_gpu_next.c','    bool external_params = false;\n    if (target_hint && frame->current)', '''    bool external_params = false;
    if(p->native_dv.source_dolby && frame->current) {
        target_csp=frame->current->params.color;
        target_csp.transfer=PL_COLOR_TRC_PQ;
        target_csp.primaries=PL_COLOR_PRIM_BT_2020;
        if(!target_csp.hdr.max_luma)target_csp.hdr.max_luma=1000;
        target_hint=true;target_unknown=false;
    }
    if (target_hint && frame->current)''')
change('player/command.c','static int mp_property_focused(', r'''#include "video/out/yydv_mpv.h"
#include "common/global.h"
static int mp_property_native_dv_status(void *ctx,struct m_property *prop,int action,void *arg)
{
    MPContext *mpctx=ctx;
    struct yydv_property_status result={0};
    if(atomic_load(&mpctx->global->native_dv_failed_epoch)==mp_native_dv_epoch(mpctx->global)) {
        snprintf(result.json,sizeof(result.json),"{\"abi\":65537,\"active\":0,\"fatal\":1,\"reason\":%u,\"epoch\":%"PRIu64"}",atomic_load(&mpctx->global->native_dv_failure_reason),mp_native_dv_epoch(mpctx->global));
        return m_property_strdup_ro(action,arg,result.json);
    }
    if(!mpctx->video_out || vo_control(mpctx->video_out,VOCTRL_NATIVE_DV_STATUS,&result)<=0)
        return M_PROPERTY_UNAVAILABLE;
    return m_property_strdup_ro(action,arg,result.json);
}
static int mp_property_native_dv_ui(void *ctx,struct m_property *prop,int action,void *arg)
{
    MPContext *mpctx=ctx;
    if(action==M_PROPERTY_GET_TYPE) {
        *(struct m_option*)arg=(struct m_option){.type=CONF_TYPE_FLAG};return M_PROPERTY_OK;
    }
    if(action!=M_PROPERTY_SET)return m_property_bool_ro(action,arg,atomic_load(&mpctx->global->native_dv_ui_safe));
    bool value=*(int*)arg;
    atomic_store(&mpctx->global->native_dv_ui_safe,value);
    if(!mpctx->video_out)return M_PROPERTY_OK;
    return vo_control(mpctx->video_out,VOCTRL_NATIVE_DV_UI_SAFE,&value)>0 ? M_PROPERTY_OK : M_PROPERTY_ERROR;
}
static int mp_property_focused(''')
change('player/command.c','    {"video-target-params", mp_property_tgt_imgparams},','    {"video-target-params", mp_property_tgt_imgparams},\n    {"native-dolby-status", mp_property_native_dv_status},\n    {"native-dolby-ui-safe", mp_property_native_dv_ui},')
change('player/command.c','      "display-height"),','      "display-height", "native-dolby-status"),')
print('Native Dolby integration applied to',root)
