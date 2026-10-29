#pragma once
#include <cstring>
#include <set>
#include <sstream>
#include <string>
extern "C" {
#include "libbluray/bluray.h"
}
// Metadata already present in title_info; this never reads additional sectors.
// Keep conflicting PID languages, deduplicate repeated clips to bound metadata.
static void track_languages(std::ostream &out, const BLURAY_TITLE_INFO *title, bool subtitles) {
    out << "["; bool first = true;
    std::set<std::pair<uint16_t, std::string>> seen;
    for (uint32_t i = 0; i < title->clip_count; ++i) {
        const auto &clip = title->clips[i];
        const auto streams = subtitles ? clip.pg_streams : clip.audio_streams;
        const unsigned count = subtitles ? clip.pg_stream_count : clip.audio_stream_count;
        if (!streams) continue;
        for (unsigned j = 0; j < count; ++j) {
            const auto &stream = streams[j];
            bool valid = stream.pid > 0 && stream.pid <= 8191;
            for (int k = 0; k < 3; ++k) valid &= stream.lang[k] >= 'a' && stream.lang[k] <= 'z';
            if (!valid) continue;
            if (!seen.emplace(stream.pid, std::string((const char *)stream.lang, 3)).second) continue;
            if (!first) out << ","; first = false;
            out << "{\"pid\":" << stream.pid << ",\"language\":\"";
            for (int k = 0; k < 3; ++k) out << (char)stream.lang[k];
            out << "\"}";
        }
    }
    out << "]";
}
static std::string disc_titles(BLURAY *bd) {
    // VideoLAN excludes playlists that repeat the same clip/time span more
    // than twice, then ranks the main feature by chapters, streams and length.
    // The longest unfiltered playlist can be a short menu repeated for hours.
    uint32_t count = bd_get_titles(bd, TITLES_RELEVANT, 0);
    if (!count || count > 4096) return {};
    const int main_title = bd_get_main_title(bd);
    std::ostringstream out; out << "["; bool first = true;
    for (uint32_t n = 0; n < count; n++) {
        auto t = bd_get_title_info(bd, n, 0);
        if (!t) continue;
        if (t->duration && t->clip_count && t->clip_count <= 4096) {
            if (!first) out << ","; first = false;
            out << "{\"playlist\":" << t->playlist << ",\"main\":" << ((int)n == main_title ? "true" : "false") << ",\"duration\":" << t->duration << ",\"clips\":[";
            for (uint32_t j = 0; j < t->clip_count; j++) {
                auto &c = t->clips[j]; if (j) out << ",";
                // Emit only numeric clip IDs; never pass disc names or paths into JSON.
                bool valid = std::strlen(c.clip_id) == 5;
                for (int k = 0; k < 5 && valid; k++) valid = c.clip_id[k] >= '0' && c.clip_id[k] <= '9';
                out << "{\"id\":\"" << (valid ? c.clip_id : "invalid") << "\",\"in\":" << c.in_time << ",\"out\":" << c.out_time << "}";
            }
            out << "],\"chapters\":[";
            for (uint32_t j = 0; j < t->chapter_count; j++) { if (j) out << ","; out << t->chapters[j].start; }
            out << "],\"audio\":"; track_languages(out, t, false);
            out << ",\"subtitles\":"; track_languages(out, t, true);
            out << "}";
        }
        bd_free_title_info(t);
        if (out.tellp() > 4 * 1024 * 1024) return {};
    }
    out << "]"; return out.str();
}
