#pragma once
#include <cstdint>
#include <iomanip>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#include "disc_clpi_access.h"

struct DiscSeekPoint { uint64_t pts90k; uint32_t spn; };

// CLPI EP timestamps have 45 kHz units, quantized to 256 ticks. They are
// presentation access points, never decoder timestamps or synthetic AVIndex.
// The formula matches pinned libbluray 1.3.4 clpi_lookup_spn().
static bool disc_seek_points(const CLPI_CL *cl, uint16_t pid, uint8_t stc,
                             std::vector<DiscSeekPoint> &out) {
    out.clear();
    if (!cl || !pid || pid > 8191 || !cl->clip.num_source_packets ||
        cl->sequence.num_atc_seq != 1 || !cl->sequence.atc_seq) return false;
    const auto &atc = cl->sequence.atc_seq[0];
    if (atc.num_stc_seq != 1 || !atc.stc_seq || atc.offset_stc_id != stc)
        return false;
    const auto &seq = atc.stc_seq[0];
    if (seq.presentation_end_time <= seq.presentation_start_time ||
        seq.spn_stc_start >= cl->clip.num_source_packets ||
        cl->cpi.type != 1 || !cl->cpi.entry) return false;
    const CLPI_EP_MAP_ENTRY *entry = nullptr;
    for (unsigned i = 0; i < cl->cpi.num_stream_pid; ++i) {
        if (cl->cpi.entry[i].pid != pid) continue;
        if (entry) return false;
        entry = &cl->cpi.entry[i];
    }
    if (!entry || !entry->coarse || !entry->fine ||
        entry->num_ep_coarse <= 0 || entry->num_ep_fine < 2 ||
        entry->num_ep_coarse > entry->num_ep_fine ||
        entry->num_ep_fine > 65536 || entry->coarse[0].ref_ep_fine_id != 0)
        return false;
    std::vector<DiscSeekPoint> points;
    points.reserve(entry->num_ep_fine);
    for (int i = 0; i < entry->num_ep_coarse; ++i) {
        const auto &coarse = entry->coarse[i];
        const int start = coarse.ref_ep_fine_id;
        const int end = i + 1 < entry->num_ep_coarse
            ? entry->coarse[i + 1].ref_ep_fine_id : entry->num_ep_fine;
        if (start < 0 || end <= start || end > entry->num_ep_fine ||
            coarse.pts_ep < 0 || coarse.pts_ep > 16383) return false;
        for (int j = start; j < end; ++j) {
            const auto &fine = entry->fine[j];
            if (fine.pts_ep < 0 || fine.pts_ep > 2047 ||
                fine.spn_ep < 0 || fine.spn_ep > 131071) return false;
            const uint64_t pts45 = (uint64_t(coarse.pts_ep & ~1) << 18) +
                                   (uint64_t(fine.pts_ep) << 8);
            const uint64_t spn = uint64_t(coarse.spn_ep & ~uint32_t(0x1ffff)) +
                                 uint64_t(fine.spn_ep);
            if (pts45 + 255 < seq.presentation_start_time ||
                pts45 > seq.presentation_end_time ||
                spn < seq.spn_stc_start || spn >= cl->clip.num_source_packets)
                return false;
            const DiscSeekPoint point{pts45 * 2, uint32_t(spn)};
            if (!points.empty() && (point.pts90k <= points.back().pts90k ||
                                    point.spn <= points.back().spn)) return false;
            points.push_back(point);
        }
    }
    out = std::move(points);
    return true;
}

struct DiscSeekListing {
    const std::set<std::string> &allowed;
    std::set<std::string> seen;
    std::string json;
    bool overflow = false;
};
static void disc_seek_visit(void *opaque, uint32_t id, uint16_t pid,
                            uint8_t stc, const CLPI_CL *cl) {
    auto &listing = *static_cast<DiscSeekListing *>(opaque);
    if (listing.overflow || id > 99999) return;
    std::ostringstream name;
    name << std::setw(5) << std::setfill('0') << id;
    const auto clip = name.str();
    if (!listing.allowed.count(clip) || !listing.seen.insert(clip).second) return;
    std::vector<DiscSeekPoint> points;
    if (!disc_seek_points(cl, pid, stc, points)) return;
    std::ostringstream row;
    row << "{\"clip\":\"" << clip << "\",\"pid\":" << pid
        << ",\"packetCount\":" << cl->clip.num_source_packets << ",\"points\":[";
    for (size_t n = 0; n < points.size(); ++n) {
        if (n) row << ',';
        row << '[' << points[n].pts90k << ',' << points[n].spn << ']';
    }
    row << "]}";
    if (listing.json.size() + row.str().size() + 3 > 4 * 1024 * 1024) {
        listing.overflow = true;
        listing.json.clear();
        return;
    }
    if (!listing.json.empty()) listing.json += ',';
    listing.json += row.str();
}
static std::string disc_seek_index(BLURAY *bd, uint32_t playlist,
                                   const std::set<std::string> &allowed) {
    DiscSeekListing listing{allowed, {}, {}, false};
    if (!yd_visit_playlist_clpi(bd, playlist, &listing, disc_seek_visit) ||
        listing.overflow) return "[]";
    return '[' + listing.json + ']';
}
