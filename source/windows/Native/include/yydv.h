#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define YYDV_CALL __cdecl
#ifdef YYDV_BUILD
#define YYDV_EXPORT __declspec(dllexport)
#else
#define YYDV_EXPORT
#endif
#else
#define YYDV_CALL
#define YYDV_EXPORT
#endif
#ifdef __cplusplus
extern "C" {
#endif

#define YYDV_ABI 0x00010001u
enum yydv_result { YYDV_FATAL=-1, YYDV_FALLBACK=0, YYDV_PACKED=1 };
enum yydv_reason {
 YYDV_OK, YYDV_UI_VISIBLE, YYDV_WINDOWED, YYDV_NOT_FOREGROUND,
 YYDV_DISPLAY_UNSUPPORTED, YYDV_NVAPI_UNAVAILABLE, YYDV_DESKTOP_HDR,
 YYDV_TIMING_UNSUPPORTED, YYDV_NVAPI_REJECTED, YYDV_PROFILE_UNSUPPORTED,
 YYDV_METADATA_MISSING, YYDV_METADATA_INVALID, YYDV_EL_MISSING,
 YYDV_PTS_INVALID, YYDV_PIXELS_UNSUPPORTED, YYDV_UPLOAD_FAILED,
 YYDV_COMPOSER_UNAVAILABLE, YYDV_COMPOSE_FAILED, YYDV_PACKET_FAILED,
 YYDV_PRESENT_FAILED, YYDV_SUBTITLE_COLOR_UNSUPPORTED, YYDV_GUI_FAILED,
 YYDV_DEVICE_LOST, YYDV_GEOMETRY_UNSUPPORTED, YYDV_RESTORE_FAILED,
 YYDV_USER_PICTURE_ADJUSTMENT, YYDV_CONNECTION_UNSUPPORTED,
 YYDV_LOW_LATENCY_ONLY, YYDV_HDR10_POLICY
};
enum yydv_pixels { YYDV_P010=1, YYDV_YUV420P10=2 };

struct yydv_picture {
 uint32_t size, format, width, height;
 const uint8_t *planes[3];
 int32_t stride[3];
 uint32_t reserved;
 double pts;
};
struct yydv_frame {
 uint32_t size, profile, compatibility, ui_safe;
 uint64_t epoch;
 struct yydv_picture base, enhancement;
 const void *metadata;
 size_t metadata_size;
 uint32_t display_width, display_height;
 const uint8_t *osd_bgra;
 uint32_t osd_width, osd_height, osd_stride, osd_srgb;
 uint32_t osd_left, osd_top, osd_right, osd_bottom;
};
struct yydv_status {
 uint32_t size, abi, active, reason;
 uint64_t epoch, frames_packed, frames_presented, fel_composed, fel_presented;
 uint32_t source_profile, residual_required, frame_complete, fatal;
 double last_pts;
 int32_t native_result;
 uint32_t reserved;
 // Output negotiation diagnostics, distinct from a D3D HRESULT. No display IDs.
 uint32_t output_stage, output_flags, output_caps_version, output_technology;
 int32_t output_result, initial_caps_result;
};

typedef void *yydv_context;
typedef yydv_context (YYDV_CALL *yydv_create_fn)(void *parent_window);
typedef int (YYDV_CALL *yydv_render_fn)(yydv_context,const struct yydv_frame *);
typedef int (YYDV_CALL *yydv_present_fn)(yydv_context);
typedef void (YYDV_CALL *yydv_reset_fn)(yydv_context,uint64_t);
typedef void (YYDV_CALL *yydv_suspend_fn)(yydv_context,uint32_t);
typedef int (YYDV_CALL *yydv_status_fn)(yydv_context,struct yydv_status *);
typedef void (YYDV_CALL *yydv_destroy_fn)(yydv_context);
YYDV_EXPORT uint32_t YYDV_CALL yydv_abi(void);
YYDV_EXPORT yydv_context YYDV_CALL yydv_create(void *parent_window);
YYDV_EXPORT int YYDV_CALL yydv_render(yydv_context,const struct yydv_frame *);
YYDV_EXPORT int YYDV_CALL yydv_present(yydv_context);
YYDV_EXPORT void YYDV_CALL yydv_reset(yydv_context,uint64_t);
YYDV_EXPORT void YYDV_CALL yydv_suspend(yydv_context,uint32_t);
YYDV_EXPORT int YYDV_CALL yydv_get_status(yydv_context,struct yydv_status *);
YYDV_EXPORT void YYDV_CALL yydv_destroy(yydv_context);
#ifdef __cplusplus
}
#endif
