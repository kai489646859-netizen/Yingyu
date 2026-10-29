// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "yydv.h"
#include <stdbool.h>
struct yydv_mpv {
    void *module;
    yydv_context context;
    yydv_create_fn create;
    yydv_render_fn render;
    yydv_present_fn present;
    yydv_reset_fn reset;
    yydv_suspend_fn suspend;
    yydv_status_fn get_status;
    yydv_destroy_fn destroy;
    struct yydv_status status;
    struct mp_draw_sub_cache *osd_cache;
    bool ui_safe, owned_frame, source_dolby, fatal, blocked_osd;
    uint64_t epoch;
    uint64_t retry_after;
};
struct yydv_property_status { char json[1024]; };
