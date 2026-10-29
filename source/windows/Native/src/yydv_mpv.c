// Included in vo_gpu_next.c after priv and set_colorspace_hint, before draw.
// SPDX-License-Identifier: GPL-3.0-or-later
#if HAVE_WIN32_DESKTOP
#include <libavutil/frame.h>
#include <libavutil/dovi_meta.h>
#include "video/mp_image_pool.h"
#include "video/out/w32_common.h"
#include "player/client.h"
#include "common/yydv_complete.h"
#include "common/global.h"

struct yydv_window_call {struct yydv_mpv *d;HWND parent;};
static void yydv_create_window(void *ptr)
{
    struct yydv_window_call *call=ptr;
    call->d->context=call->d->create(call->parent);
}
static void yydv_destroy_window(void *ptr)
{
    struct yydv_mpv *d=ptr;d->destroy(d->context);d->context=NULL;
}

static bool yydv_load_module(struct vo *vo)
{
    struct priv *p = vo->priv;
    struct yydv_mpv *d = &p->native_dv;
    if (d->module)
        return d->context != NULL;
    HMODULE core = NULL;
    wchar_t path[32768];
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)(uintptr_t)&yydv_load_module, &core))
        return false;
    DWORD n = GetModuleFileNameW(core, path, MP_ARRAY_SIZE(path));
    if (!n || n >= MP_ARRAY_SIZE(path))
        return false;
    wchar_t *last = wcsrchr(path, L'\\');
    if (!last || last-path > 32700)
        return false;
    wcscpy(last + 1, L"Yingyu.NativeDolby.dll");
    HMODULE dll = LoadLibraryExW(path, NULL,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!dll)
        return false;
    typedef uint32_t (__cdecl *abi_fn)(void);
    abi_fn abi = (abi_fn)GetProcAddress(dll, "yydv_abi");
    if (!abi || abi() != YYDV_ABI) {
        FreeLibrary(dll);
        return false;
    }
#define YYDV_LOAD(field, symbol, type) d->field = (type)GetProcAddress(dll, symbol)
    YYDV_LOAD(create, "yydv_create", yydv_create_fn);
    YYDV_LOAD(render, "yydv_render", yydv_render_fn);
    YYDV_LOAD(present, "yydv_present", yydv_present_fn);
    YYDV_LOAD(reset, "yydv_reset", yydv_reset_fn);
    YYDV_LOAD(suspend, "yydv_suspend", yydv_suspend_fn);
    YYDV_LOAD(get_status, "yydv_get_status", yydv_status_fn);
    YYDV_LOAD(destroy, "yydv_destroy", yydv_destroy_fn);
#undef YYDV_LOAD
    if (!d->create || !d->render || !d->present || !d->reset || !d->suspend ||
        !d->get_status || !d->destroy) {
        FreeLibrary(dll);
        return false;
    }
    // A window class retains the DLL's window procedure until process exit.
    HMODULE pinned = NULL;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN |
                      GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                      (LPCWSTR)(uintptr_t)d->create, &pinned);
    d->module = dll;
    // A child HWND must live on mpv's pumping Win32 thread. Creating it on the
    // VO worker would leave synchronous input/window messages unserviced.
    struct yydv_window_call call={d,vo_w32_hwnd(vo)};
    vo_w32_run_on_thread(vo,yydv_create_window,&call);
    d->status = (struct yydv_status){.size=sizeof(d->status),.abi=YYDV_ABI};
    d->osd_cache = mp_draw_sub_alloc(p, vo->global);
    return d->context != NULL;
}

static const AVBufferRef *yydv_raw_metadata(const struct mp_image *image)
{
    if (!image) return NULL;
    for (int i=0; i<image->num_ff_side_data; i++)
        if (image->ff_side_data[i].type == AV_FRAME_DATA_DOVI_METADATA)
            return image->ff_side_data[i].buf;
    return NULL;
}

static void yydv_refresh(struct vo *vo)
{
    struct priv *p=vo->priv;
    struct yydv_mpv *d=&p->native_dv;
    if (d->context) {
        uint32_t previous=d->status.active,reason=d->status.reason;
        d->get_status(d->context,&d->status);
        if (previous!=d->status.active || reason!=d->status.reason)
            vo_event(vo,VO_EVENT_WIN_STATE);
    }
}

static void yydv_fail(struct vo *vo,unsigned reason)
{
    struct priv *p=vo->priv;
    struct yydv_mpv *d=&p->native_dv;
    if (d->context) d->suspend(d->context,reason);
    d->fatal=true;d->owned_frame=false;d->status.fatal=1;
    d->status.active=0;d->status.reason=reason;d->status.epoch=d->epoch;
    mp_native_dv_failure(vo->global,d->epoch,reason);
    vo_event(vo,VO_EVENT_WIN_STATE);
}

static int yydv_fallback(struct vo *vo,unsigned reason)
{
    struct priv *p=vo->priv;struct yydv_mpv *d=&p->native_dv;
    bool was_native=d->owned_frame||d->status.active;d->owned_frame=false;
    if(d->context)d->suspend(d->context,reason);
    yydv_refresh(vo);
    if(d->status.fatal){yydv_fail(vo,d->status.reason);return -1;}
    if(was_native)p->want_reset=true;
    return 0;
}

static struct mp_image *yydv_download(struct mp_image *source,struct yydv_picture *out)
{
    if (!source) return NULL;
    struct mp_image *image=source->hwctx ? mp_image_hw_download(source,NULL)
                                      : mp_image_new_ref(source);
    if (!image) return NULL;
    unsigned fmt=image->imgfmt==IMGFMT_P010 ? YYDV_P010
                 : image->imgfmt==pixfmt2imgfmt(AV_PIX_FMT_YUV420P10LE) ? YYDV_YUV420P10 : 0;
    *out=(struct yydv_picture){.size=sizeof(*out),.format=fmt,
         .width=image->w,.height=image->h,.pts=source->pts==MP_NOPTS_VALUE ? NAN : source->pts};
    for(int i=0;i<3;i++){out->planes[i]=image->planes[i];out->stride[i]=image->stride[i];}
    return image;
}

static bool yydv_osd(struct vo *vo,struct mp_image *image,struct yydv_frame *f)
{
    struct priv *p=vo->priv;struct yydv_mpv *d=&p->native_dv;
    struct sub_bitmap_list *subs=osd_render(vo->osd,p->osd_res,image->pts,0,mp_draw_sub_formats);
    bool safe=true;
    for(int i=0;i<subs->num_items;i++){
        struct sub_bitmaps *b=subs->items[i];
        if(b->format==SUBBITMAP_BGRA&&b->num_parts){
            for(int j=0;j<b->num_parts;j++)
                if(b->video_color_space||b->parts[j].bgra.video_color_space||
                   (b->parts[j].bgra.transfer!=PL_COLOR_TRC_UNKNOWN&&
                    b->parts[j].bgra.transfer!=PL_COLOR_TRC_SRGB)||
                   (b->parts[j].bgra.primaries!=PL_COLOR_PRIM_UNKNOWN&&
                    b->parts[j].bgra.primaries!=PL_COLOR_PRIM_BT_709))safe=false;
        }
    }
    struct mp_rect active[16],changed[16];int na=0,nc=0;
    struct mp_image *overlay=mp_draw_sub_overlay(d->osd_cache,subs,active,16,&na,changed,16,&nc);
    if (!overlay) {talloc_free(subs);return false;}
    if(na>0){
        f->osd_bgra=overlay->planes[0];f->osd_stride=overlay->stride[0];
        f->osd_width=overlay->w;f->osd_height=overlay->h;f->osd_srgb=safe;
        struct mp_rect bounds=active[0];for(int i=1;i<na;i++){
            bounds.x0=MPMIN(bounds.x0,active[i].x0);bounds.y0=MPMIN(bounds.y0,active[i].y0);
            bounds.x1=MPMAX(bounds.x1,active[i].x1);bounds.y1=MPMAX(bounds.y1,active[i].y1);
        }
        f->osd_left=MPMAX(0,bounds.x0);f->osd_top=MPMAX(0,bounds.y0);
        f->osd_right=MPMIN(overlay->w,bounds.x1);f->osd_bottom=MPMIN(overlay->h,bounds.y1);
    }
    talloc_free(subs);return true;
}

// -1: source completeness failure; 0: ordinary/HDR renderer; 1: carrier owned.
static int yydv_try_frame(struct vo *vo,struct vo_frame *frame)
{
    struct priv *p=vo->priv;struct yydv_mpv *d=&p->native_dv;
    d->ui_safe=atomic_load(&vo->global->native_dv_ui_safe);
    struct mp_image *image=frame->current;
    if(!image)return 0;
    uint64_t epoch=mp_native_dv_epoch(vo->global);
    if(d->epoch!=epoch){
        d->epoch=epoch;d->fatal=false;d->blocked_osd=false;d->retry_after=0;
        if(d->context)d->reset(d->context,epoch);
        yydv_refresh(vo);
        if(d->status.fatal){yydv_fail(vo,d->status.reason);return -1;}
    }
    if(d->fatal)return -1;
    const AVBufferRef *meta=yydv_raw_metadata(image);
    if(!meta)meta=yydv_raw_metadata(image->enhancement_layer);
    int profile=image->params.dv_profile,compat=image->params.dv_compatibility;
    if(!profile&&image->enhancement_layer){profile=image->enhancement_layer->params.dv_profile;compat=image->enhancement_layer->params.dv_compatibility;}
    d->source_dolby=profile>0||image->dovi||meta;
    if(!d->source_dolby){
        return yydv_fallback(vo,YYDV_OK);
    }
    if(!meta||!image->dovi){yydv_fail(vo,YYDV_METADATA_MISSING);return -1;}
    // Validate completeness BEFORE every early fallback, including a missing
    // transport DLL. A fallback is never permission to discard a required EL.
    int required=yydv_required_el(meta);
    if(required<0){yydv_fail(vo,YYDV_METADATA_INVALID);return -1;}
    if(required){
        struct mp_image *el=image->enhancement_layer;
        if(!el){yydv_fail(vo,YYDV_EL_MISSING);return -1;}
        if(image->pts==MP_NOPTS_VALUE||el->pts==MP_NOPTS_VALUE||!isfinite(image->pts)||!isfinite(el->pts)||fabs(image->pts-el->pts)>1e-6){yydv_fail(vo,YYDV_PTS_INVALID);return -1;}
    }
    if(d->context&&!d->ui_safe)return yydv_fallback(vo,YYDV_UI_VISIBLE);
    if(GetTickCount64()<d->retry_after)return 0;
    if(!yydv_load_module(vo)){d->status.reason=YYDV_NVAPI_UNAVAILABLE;return 0;}
    // The native carrier must bypass color/gamma alteration. Retain a user's
    // explicit gamma adjustment through the ordinary HDR renderer instead.
    if(fabsf(p->pars->color_adjustment.gamma-1.0f)>1e-6f)
        return yydv_fallback(vo,YYDV_USER_PICTURE_ADJUSTMENT);
    if(image->params.rotate||image->params.vflip||p->src.x0||p->src.y0||
       p->src.x1!=image->w||p->src.y1!=image->h){
        return yydv_fallback(vo,YYDV_GEOMETRY_UNSUPPORTED);
    }
    struct yydv_frame input={.size=sizeof(input),.profile=profile,.compatibility=compat,
                            .ui_safe=d->ui_safe,.epoch=epoch};
    input.metadata=meta->data;input.metadata_size=meta->size;
    int dw=0,dh=0;mp_image_params_get_dsize(&image->params,&dw,&dh);
    input.display_width=dw;input.display_height=dh;
    struct mp_image *bl=yydv_download(image,&input.base);
    struct mp_image *el=image->enhancement_layer ? yydv_download(image->enhancement_layer,&input.enhancement) : NULL;
    if(!bl || (required&&!el)){talloc_free(bl);talloc_free(el);return yydv_fallback(vo,YYDV_PIXELS_UNSUPPORTED);}
    if(!yydv_osd(vo,image,&input)){talloc_free(bl);talloc_free(el);return yydv_fallback(vo,YYDV_GUI_FAILED);}
    d->blocked_osd=input.osd_bgra&&!input.osd_srgb;
    bool was_active=d->status.active;
    if(input.ui_safe && !was_active)set_colorspace_hint(p,NULL);
    int result=d->render(d->context,&input);
    talloc_free(bl);talloc_free(el);yydv_refresh(vo);
    if(result==YYDV_FATAL){yydv_fail(vo,d->status.reason);return -1;}
    if(result==YYDV_PACKED){d->owned_frame=true;return 1;}
    d->owned_frame=false;
    if(input.ui_safe) {
        unsigned r=d->status.reason;
        // A stable refusal must not oscillate SDR/HDR swap-chain hints every
        // few seconds on a non-NVIDIA laptop or unsupported output timing.
        // New media/seek, UI transitions and resize explicitly rearm it.
        bool stable=r==YYDV_DISPLAY_UNSUPPORTED||r==YYDV_NVAPI_UNAVAILABLE||
            r==YYDV_DESKTOP_HDR||r==YYDV_TIMING_UNSUPPORTED||r==YYDV_NVAPI_REJECTED||
            r==YYDV_PROFILE_UNSUPPORTED||r==YYDV_SUBTITLE_COLOR_UNSUPPORTED||
            r==YYDV_CONNECTION_UNSUPPORTED||r==YYDV_LOW_LATENCY_ONLY;
        d->retry_after=stable?UINT64_MAX:GetTickCount64()+5000;
    }
    if(was_active){p->want_reset=true;vo->want_redraw=true;}
    return 0;
}

static int yydv_control(struct vo *vo,uint32_t request,void *data)
{
    struct priv *p=vo->priv;struct yydv_mpv *d=&p->native_dv;
    if(request==VOCTRL_NATIVE_DV_UI_SAFE){
        bool value=*(bool*)data;if(value!=d->ui_safe)d->retry_after=0;d->ui_safe=value;
        if(!value&&d->context)yydv_fallback(vo,YYDV_UI_VISIBLE);
        vo->want_redraw=true;return VO_TRUE;
    }
    if(request==VOCTRL_NATIVE_DV_STATUS){
        yydv_refresh(vo);
        struct yydv_property_status *out=data;
        snprintf(out->json,sizeof(out->json),"{\"abi\":%u,\"active\":%u,\"reason\":%u,\"epoch\":%llu,\"profile\":%u,\"packed\":%llu,\"presented\":%llu,\"felComposed\":%llu,\"felPresented\":%llu,\"complete\":%u,\"fatal\":%u,\"nativeResult\":%d,\"uiSafe\":%u,\"osdBlocked\":%u,\"outputStage\":%u,\"outputFlags\":%u,\"capsVersion\":%u,\"outputTechnology\":%u,\"outputResult\":%d,\"initialCapsResult\":%d}",
          d->status.abi,d->status.active,d->status.reason,(unsigned long long)d->epoch,d->status.source_profile,
          (unsigned long long)d->status.frames_packed,(unsigned long long)d->status.frames_presented,(unsigned long long)d->status.fel_composed,
          (unsigned long long)d->status.fel_presented,d->status.frame_complete,d->status.fatal||d->fatal,d->status.native_result,d->ui_safe,d->blocked_osd,
          d->status.output_stage,d->status.output_flags,d->status.output_caps_version,d->status.output_technology,d->status.output_result,d->status.initial_caps_result);
        return VO_TRUE;
    }
    return VO_NOTIMPL;
}
#endif
