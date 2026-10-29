// Compile the unchanged pinned release in this translation unit. The sole
// extension below reads playlist metadata and never selects/plays a title.
#include "libbluray/bluray.c"
#include "disc_clpi_access.h"

int yd_visit_playlist_clpi(BLURAY *bd, uint32_t playlist, void *context,
                          yd_clpi_visitor visitor)
{
    if (!bd || !visitor || playlist > 99999) return 0;
    bd_mutex_lock(&bd->mutex);
    int listed = 0;
    if (bd->title_list && bd->title_list->count <= 4096) {
        for (unsigned n = 0; n < bd->title_list->count; ++n)
            listed |= bd->title_list->title_info[n].mpls_id == playlist;
    }
    if (!listed) { bd_mutex_unlock(&bd->mutex); return 0; }
    char name[12];
    snprintf(name, sizeof(name), "%05u.mpls", playlist);
    // Same read-only operation used by bd_get_playlist_info. Do not use
    // bd_select_playlist: that opens m2ts and preloads subtitle subpaths.
    NAV_TITLE *title = nav_title_open(bd->disc, name, 0);
    if (title && title->clip_list.count <= 4096 && title->pl &&
        title->clip_list.count == title->pl->list_count) {
        for (unsigned n = 0; n < title->clip_list.count; ++n) {
            const NAV_CLIP *clip = &title->clip_list.clip[n];
            const MPLS_PI *item = &title->pl->play_item[n];
            if (!item->clip || item->is_multi_angle || item->stn.num_video != 1 ||
                !item->stn.video || item->stn.video[0].stream_type != 1 ||
                clip->clip_id > 99999) continue;
            visitor(context, clip->clip_id, item->stn.video[0].pid,
                    item->clip[0].stc_id, clip->cl);
        }
    }
    const int ok = title != NULL;
    nav_title_close(&title);
    bd_mutex_unlock(&bd->mutex);
    return ok;
}
