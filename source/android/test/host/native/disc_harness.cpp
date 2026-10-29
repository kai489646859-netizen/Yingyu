// Host-only adapter invokes the actual production callbacks on native threads.
// libbluray/libudfread are real; no MPV player or audio/video decoder is started.
#ifndef YINGYU_DISC_SOURCE
#define YINGYU_DISC_SOURCE "disc_direct.cpp"
#endif
#include YINGYU_DISC_SOURCE
extern "C" int yt_mpv_origin_from_playlist(int);
namespace {
std::mutex tests_mutex;
std::map<int64_t, std::shared_ptr<StreamInfo>> streams;
std::shared_ptr<StreamInfo> get_stream(int64_t id) {
    std::lock_guard<std::mutex> lock(tests_mutex);
    auto it = streams.find(id); return it == streams.end() ? nullptr : it->second;
}
}
EXPORT void yt_open(const char *uri, int64_t port, void *poster) {
    const std::string name(uri);
    std::thread([name, port, poster] {
        auto info = std::shared_ptr<StreamInfo>(new StreamInfo{}, [](StreamInfo *v) {
            if (v->cookie) v->close_fn(v->cookie); delete v;
        });
        auto result = open_stream(nullptr, const_cast<char *>(name.c_str()), info.get());
        int64_t id = 0;
        if (!result) {
            id = serial.fetch_add(1);
            std::lock_guard<std::mutex> lock(tests_mutex); streams[id] = info;
        }
        Session messenger("", port, reinterpret_cast<Post>(poster));
        post(messenger, {number(id), number(result), number(id ? info->size_fn(info->cookie) : 0)});
    }).detach();
}
EXPORT void yt_read(int64_t id, int64_t at, int length, int64_t port, void *poster) {
    auto info = get_stream(id);
    std::thread([info, at, length, port, poster] {
        int64_t n = -1;
        std::vector<uint8_t> data(length > 0 && length <= 4 * PAGE ? length : 0);
        if (info && !data.empty() && at >= 0 && info->seek_fn(info->cookie, at) == at) {
            n = 0;
            while (n < length) {
                auto got = info->read_fn(info->cookie, reinterpret_cast<char *>(data.data() + n), length - n);
                if (got < 0) { n = -1; break; }
                if (!got) break;
                n += got;
            }
        }
        Dart_CObject bytes{}; bytes.type = Dart_CObject_kTypedData;
        bytes.value.as_typed_data = {Dart_TypedData_kUint8, n > 0 ? static_cast<intptr_t>(n) : 0, data.data()};
        Session messenger("", port, reinterpret_cast<Post>(poster));
        post(messenger, {number(n), bytes});
    }).detach();
}
// Reproduce MPV's FS playlist -> custom callback rejection before opening IO.
// EDL passes its parent's origin through unchanged. This is not a full player.
EXPORT void yt_open_from_origin(const char *uri, int from_playlist, int64_t port, void *poster) {
    if (yt_mpv_origin_from_playlist(from_playlist)) {
        yt_open(uri, port, poster);
    } else {
        Session messenger("", port, reinterpret_cast<Post>(poster));
        post(messenger, {number(0), number(MPV_ERROR_LOADING_FAILED), number(0)});
    }
}
EXPORT void yt_cancel(int64_t id) {
    auto info = get_stream(id); if (info) info->cancel_fn(info->cookie);
}
EXPORT void yt_read_once(int64_t id, int64_t at, int length, int64_t port, void *poster) {
    auto info = get_stream(id);
    std::thread([info, at, length, port, poster] {
        int64_t n = -1;
        std::vector<uint8_t> data(length > 0 && length <= PAGE ? length : 0);
        if (info && !data.empty() && at >= 0 && info->seek_fn(info->cookie, at) == at)
            n = info->read_fn(info->cookie, reinterpret_cast<char *>(data.data()), length);
        Dart_CObject bytes{}; bytes.type = Dart_CObject_kTypedData;
        bytes.value.as_typed_data = {Dart_TypedData_kUint8, n > 0 ? static_cast<intptr_t>(n) : 0, data.data()};
        Session messenger("", port, reinterpret_cast<Post>(poster));
        post(messenger, {number(n), bytes});
    }).detach();
}
EXPORT void yt_close(int64_t id) {
    std::lock_guard<std::mutex> lock(tests_mutex); streams.erase(id);
}
EXPORT int yt_sessions() {
    std::lock_guard<std::mutex> lock(registry_mutex); return static_cast<int>(sessions.size());
}
EXPORT int yt_requests() {
    std::lock_guard<std::mutex> lock(registry_mutex); return static_cast<int>(requests.size());
}

// Exercise actual remote_read with deterministic bytes, without a player or
// decoder. Metadata uses full validated pages; streaming permits 64 KiB prefixes.
namespace {
thread_local bool synthetic_prefix = false;
constexpr int64_t synthetic_size = 7 * PAGE + 123;
bool synthetic_page(int64_t, Dart_CObject *message) {
    auto values = message->value.as_array.values;
    if (values[1]->value.as_int64 == 0) return true;
    const auto id = values[0]->value.as_int64;
    const auto at = values[3]->value.as_int64;
    auto length = std::min<int64_t>(values[4]->value.as_int64, synthetic_size - at);
    if (synthetic_prefix) length = std::min<int64_t>(length, 65536);
    if (length < 0) return false;
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    for (int64_t i = 0; i < length; ++i) bytes[i] = (at + i) % 251;
    yd_reply(id, 0, synthetic_size, bytes.data(), static_cast<int>(length));
    return true;
}
}
EXPORT int yt_metadata_pages(int mode) {
    auto s = std::make_shared<Session>("offline-pages", 1, synthetic_page);
    s->ready = synthetic_prefix = mode == 1;
    const auto check = [&](int64_t at, int count) {
        std::vector<uint8_t> bytes(count);
        auto n = remote_read(s.get(), "", at, bytes.data(), count);
        if (n != std::min<int64_t>(count, synthetic_size - at)) return false;
        for (int64_t i = 0; i < n; ++i) if (bytes[i] != (at + i) % 251) return false;
        return s->page_bytes <= 8 * PAGE;
    };
    bool valid = mode == 0 ? check(1179648, 2048) && check(1048576, 2048)
               : mode == 1 ? check(PAGE + 65536, 256) && check(PAGE, 256)
               : mode == 2 ? check(PAGE - 100, PAGE + 300)
               : mode == 3 ? check(7 * PAGE + 50, 4096) : false;
    return valid ? static_cast<int>(s->requests.load()) : -1;
}

#if defined(YINGYU_DISC_INDEX_CACHE_TEST)
// Production cache-only path: misses cannot post any request, including size
// probes used by HTTP BDMV file_open. A restored flag must allow normal reads.
EXPORT int yt_index_cache_only(int mode) {
    auto s = std::make_shared<Session>("offline-index", 1, synthetic_page);
    uint8_t bytes[4]{};
    if (mode != 0 && remote_read(s.get(), "BDMV/CLIPINF/00001.clpi", 0, bytes, 4) != 4)
        return -1;
    const int64_t before = s->requests;
    s->metadata_cache_only = true;
    bool valid = false;
    if (mode == 0) {
        valid = remote_read(s.get(), "", 0, bytes, 4) == -1;
    } else if (mode == 1) {
        valid = remote_read(s.get(), "BDMV/CLIPINF/00001.clpi", 0, bytes, 4) == 4 && bytes[3] == 3;
    } else if (mode == 2) {
        auto f = file_open(s.get(), "BDMV/CLIPINF/00001.clpi");
        valid = f && f->read(f, bytes, 4) == 4 && bytes[3] == 3;
        if (f) f->close(f);
    } else if (mode == 3) {
        auto f = file_open(s.get(), "BDMV/STREAM/00001.m2ts");
        valid = !f;
        if (f) f->close(f);
    } else if (mode == 4) {
        valid = remote_read(s.get(), "BDMV/CLIPINF/00001.clpi", 2 * PAGE, bytes, 4) == -1;
    } else if (mode == 5) {
        valid = !request(s.get(), 3, "BDMV", 0, 0);
    } else if (mode == 6) {
        s->metadata_cache_only = false;
        valid = remote_read(s.get(), "BDMV/CLIPINF/00001.clpi", 2 * PAGE, bytes, 4) == 4 && s->requests == before + 1;
        return valid ? 0 : -1;
    }
    return valid && s->requests == before ? 0 : -1;
}
#endif
