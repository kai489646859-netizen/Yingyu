// App-owned read-only libmpv adapter. No Java arrays, loopback HTTP, or MPV API
// calls inside stream callbacks. Network/authentication remains in the IO isolate.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>
#include "dart/dart_native_api.h"
#include "disc_metadata.h"
#include "disc_seek_index.h"
#include "mpv/stream_cb.h"
extern "C" {
#include "file/filesystem.h"
#include "util/log_control.h"
}
#if defined(_WIN32)
#include <windows.h>
#define EXPORT extern "C" __declspec(dllexport)
#else
#include <dlfcn.h>
#define EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {
constexpr int PAGE = 1024 * 1024;
using Clock = std::chrono::steady_clock;
using Post = bool (*)(int64_t, Dart_CObject *);
struct Session;
struct Cancel { std::atomic<bool> value{false}; };
struct Request {
    std::mutex mutex;
    bool done = false;
    int status = -1;
    int64_t total = -1;
    std::vector<uint8_t> bytes;
    std::weak_ptr<Session> session;
};
struct Page { std::string path; int64_t at, total; std::vector<uint8_t> bytes; };
struct Session : std::enable_shared_from_this<Session> {
    const std::string id;
    const int64_t port;
    const Post post;
    std::atomic<bool> closed{false};
    std::condition_variable wake;
    // Only the libbluray owner and its file handles use this lock. Cancellation
    // never acquires it; a blocked source read is interrupted by wake instead.
    std::mutex io;
    BLURAY *bd = nullptr;
    std::map<std::string, BD_FILE_H *> clips;
    std::list<Page> pages;
    size_t page_bytes = 0;
    std::set<std::string> allowed;
    bool ready = false;
    bool metadata_cache_only = false; // optional index lookup, under io
    Cancel *reader = nullptr; // valid only under io, points to the active cookie
    std::atomic<int64_t> output{0}, requests{0}, wait_us{0}, read_us{0}, hits{0};
    Clock::time_point deadline = Clock::now() + std::chrono::seconds(120);
    Session(std::string id, int64_t port, Post post) : id(std::move(id)), port(port), post(post) {}
    ~Session() {
        for (auto &item : clips) item.second->close(item.second);
        if (bd) bd_close(bd);
    }
    bool cancelled() const { return closed || (reader && reader->value) || Clock::now() > deadline; }
};
std::mutex registry_mutex;
std::map<std::string, std::shared_ptr<Session>> sessions;
std::map<int64_t, std::shared_ptr<Request>> requests;
std::atomic<int64_t> serial{1};
bool valid_id(const std::string &s) {
    return s.size() == 32 && s.find_first_not_of("0123456789abcdef") == std::string::npos;
}
std::shared_ptr<Session> find_session(const char *id) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    auto it = sessions.find(id ? id : "");
    return it == sessions.end() ? nullptr : it->second;
}
Dart_CObject number(int64_t n) {
    Dart_CObject v{}; v.type = Dart_CObject_kInt64; v.value.as_int64 = n; return v;
}
Dart_CObject string(const char *s) {
    Dart_CObject v{}; v.type = Dart_CObject_kString; v.value.as_string = s; return v;
}
bool post(Session &s, std::initializer_list<Dart_CObject> values) {
    std::vector<Dart_CObject> data(values);
    std::vector<Dart_CObject *> pointers;
    for (auto &v : data) pointers.push_back(&v);
    Dart_CObject message{}; message.type = Dart_CObject_kArray;
    message.value.as_array = {static_cast<intptr_t>(pointers.size()), pointers.data()};
    return s.post(s.port, &message); // synchronous deep copy by the Dart VM
}
std::shared_ptr<Request> request(Session *s, int op, const char *path, int64_t at, int length) {
    if (s->cancelled() || s->metadata_cache_only) return nullptr;
    const auto id = serial.fetch_add(1);
    auto r = std::make_shared<Request>(); r->session = s->shared_from_this();
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        if (s->closed) return nullptr;
        requests[id] = r;
    }
    const auto started = Clock::now();
    if (post(*s, {number(id), number(op), string(path), number(at), number(length)})) {
        std::unique_lock<std::mutex> lock(r->mutex);
        s->wake.wait_until(lock, std::min(s->deadline, started + std::chrono::seconds(35)),
                           [&] { return r->done || s->cancelled(); });
    }
    s->wait_us += std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - started).count();
    s->requests++;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        requests.erase(id);
    }
    // reply() completes under registry_mutex then r->mutex. Acquiring the
    // registry above also fences late replies before the result is inspected.
    if (s->cancelled() || !r->done) {
        post(*s, {number(id), number(0)}); // stop the obsolete producer in Dart
        return nullptr;
    }
    return r->status == 0 ? r : nullptr;
}
int64_t remote_read(Session *s, const char *path, int64_t at, uint8_t *out, int64_t count) {
    if (at < 0 || count < 0 || s->cancelled()) return -1;
    int64_t done = 0;
    while (done < count) {
        const auto pos = at + done;
        auto page = std::find_if(s->pages.begin(), s->pages.end(), [&](const Page &p) {
            return p.path == path && pos >= p.at && pos < p.at + static_cast<int64_t>(p.bytes.size());
        });
        if (page == s->pages.end()) {
            // Directory parsing waits for a complete page. Align those pages
            // so nearby UDF/CLPI reads reuse them instead of fetching overlapping
            // 1 MiB ranges. Streaming keeps its small progressive prefix.
            const int64_t alignment = s->ready ? 65536 : PAGE;
            const int64_t aligned = pos / alignment * alignment;
            auto r = request(s, 1, path, aligned, PAGE);
            if (!r || r->total <= pos || r->bytes.empty() ||
                static_cast<int64_t>(r->bytes.size()) > std::min<int64_t>(PAGE, r->total - aligned)) return done ? done : -1;
            while (!s->pages.empty() && s->page_bytes + r->bytes.size() > 8 * PAGE) {
                s->page_bytes -= s->pages.back().bytes.size(); s->pages.pop_back();
            }
            s->page_bytes += r->bytes.size();
            s->pages.push_front({path, aligned, r->total, std::move(r->bytes)});
            page = s->pages.begin();
            if (pos >= aligned + static_cast<int64_t>(page->bytes.size())) return -1;
        } else {
            s->hits++;
            s->pages.splice(s->pages.begin(), s->pages, page);
            page = s->pages.begin();
        }
        auto n = std::min<int64_t>(count - done, page->bytes.size() - (pos - page->at));
        std::memcpy(out + done, page->bytes.data() + (pos - page->at), static_cast<size_t>(n));
        done += n;
        if (at + done == page->total) break;
        if (s->cancelled()) return -1;
    }
    return done;
}
int blocks(void *v, void *out, int lba, int count) {
    if (lba < 0 || count <= 0) return 0;
    const auto n = remote_read(static_cast<Session *>(v), "", int64_t(lba) * 2048,
                               static_cast<uint8_t *>(out), int64_t(count) * 2048);
    return n < 0 ? 0 : static_cast<int>(n / 2048);
}
struct RemoteFile { Session *s; std::string path; int64_t length, pos = 0; };
BD_FILE_H *file_open(void *v, const char *path) {
#if defined(_WIN32)
    // Host validation uses libbluray's Windows path separator. Android's
    // upstream build already emits slash-separated relative disc paths.
    std::string normalized(path); std::replace(normalized.begin(), normalized.end(), '\\', '/');
    path = normalized.c_str();
#endif
    auto s = static_cast<Session *>(v);
    int64_t total = -1;
    if (s->metadata_cache_only) {
        auto page = std::find_if(s->pages.begin(), s->pages.end(),
            [&](const Page &p) { return p.path == path; });
        if (page != s->pages.end()) total = page->total;
    } else {
        auto r = request(s, 2, path, 0, 1);
        if (r) total = r->total;
    }
    if (total < 0) return nullptr;
    auto f = new BD_FILE_H{}; f->internal = new RemoteFile{s, path, total};
    f->close = [](BD_FILE_H *f) { delete static_cast<RemoteFile *>(f->internal); delete f; };
    f->tell = [](BD_FILE_H *f) { return static_cast<RemoteFile *>(f->internal)->pos; };
    f->seek = [](BD_FILE_H *f, int64_t at, int32_t origin) -> int64_t {
        auto r = static_cast<RemoteFile *>(f->internal);
        const auto base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? r->pos : origin == SEEK_END ? r->length : -1;
        if (base < 0 || at < -base || at > r->length - base) return -1;
        return r->pos = base + at;
    };
    f->read = [](BD_FILE_H *f, uint8_t *out, int64_t count) -> int64_t {
        auto r = static_cast<RemoteFile *>(f->internal);
        if (count < 0) return -1;
        auto n = remote_read(r->s, r->path.c_str(), r->pos, out, std::min(count, r->length - r->pos));
        if (n > 0) r->pos += n;
        return n;
    };
    return f;
}
struct RemoteDir { std::string entries; size_t at = 0; };
BD_DIR_H *dir_open(void *v, const char *path) {
#if defined(_WIN32)
    std::string normalized(path); std::replace(normalized.begin(), normalized.end(), '\\', '/');
    path = normalized.c_str();
#endif
    auto r = request(static_cast<Session *>(v), 3, path, 0, 0);
    if (!r) return nullptr;
    auto d = new BD_DIR_H{};
    d->internal = new RemoteDir{std::string(r->bytes.begin(), r->bytes.end())};
    d->close = [](BD_DIR_H *d) { delete static_cast<RemoteDir *>(d->internal); delete d; };
    d->read = [](BD_DIR_H *d, BD_DIRENT *entry) {
        auto r = static_cast<RemoteDir *>(d->internal);
        if (r->at >= r->entries.size()) return 1;
        auto end = r->entries.find('\n', r->at);
        if (end == std::string::npos) end = r->entries.size();
        const auto name = r->entries.substr(r->at, end - r->at); r->at = end + 1;
        if (name.empty() || name.size() >= sizeof(entry->d_name)) return -1;
        std::memcpy(entry->d_name, name.c_str(), name.size() + 1); return 0;
    };
    return d;
}
BD_FILE_H *clip(Session &s, const std::string &path) {
    auto it = s.clips.find(path);
    if (it != s.clips.end()) return it->second;
    auto f = bd_open_file_dec(s.bd, path.c_str());
    if (!f) return nullptr;
    if (s.clips.size() == 4) { auto old = s.clips.begin(); old->second->close(old->second); s.clips.erase(old); }
    s.clips[path] = f; return f;
}
using StreamInfo = mpv_stream_cb_info;
struct Stream {
    std::shared_ptr<Session> session;
    std::string path;
    int64_t pos = 0, length = 0;
    bool first = true;
    Cancel cancel;
};
int64_t stream_read(void *v, char *out, uint64_t count) {
    auto r = static_cast<Stream *>(v); auto s = r->session;
    std::lock_guard<std::mutex> lock(s->io);
    if (r->cancel.value || s->closed) return -1;
    if (r->pos == r->length || count == 0) return 0;
    s->reader = &r->cancel;
    const auto before = Clock::now();
    auto f = clip(*s, r->path);
    int64_t n = -1;
    if (f && f->seek(f, r->pos, SEEK_SET) == r->pos) {
        n = f->read(f, reinterpret_cast<uint8_t *>(out),
                    std::min<int64_t>(std::min<uint64_t>(count, r->first ? 65536 : PAGE), r->length - r->pos));
    }
    s->reader = nullptr;
    s->read_us += std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - before).count();
    if (n > 0) { r->first = false; r->pos += n; s->output += n; }
    // A premature zero is an IO failure, not a successful end of media.
    return n == 0 && r->pos < r->length ? -1 : n;
}
int open_stream(void *, char *uri, StreamInfo *info) {
    const std::string text(uri ? uri : ""), prefix("yingyu-disc://");
    if (text.compare(0, prefix.size(), prefix) != 0) return MPV_ERROR_LOADING_FAILED;
    const auto rest = text.substr(prefix.size());
    if (rest.size() != 48 || rest.substr(32, 6) != "/clip/" || rest.substr(43) != ".m2ts") return MPV_ERROR_LOADING_FAILED;
    const auto id = rest.substr(0, 32), name = rest.substr(38, 5);
    auto s = find_session(id.c_str());
    if (!s) return MPV_ERROR_LOADING_FAILED;
    auto r = std::make_unique<Stream>(); r->session = s; r->path = "BDMV/STREAM/" + name + ".m2ts";
    {
        std::lock_guard<std::mutex> lock(s->io);
        if (!s->ready || s->closed || !s->allowed.count(name)) return MPV_ERROR_LOADING_FAILED;
        auto f = clip(*s, r->path);
        if (!f || (r->length = f->seek(f, 0, SEEK_END)) <= 0) return MPV_ERROR_LOADING_FAILED;
    }
    info->cookie = r.release(); info->read_fn = stream_read;
    info->seek_fn = [](void *v, int64_t at) -> int64_t {
        auto r = static_cast<Stream *>(v);
        if (r->cancel.value || r->session->closed || at < 0 || at > r->length) return -1;
        // Exact byte contract: defer all physical IO until read. This is an
        // individual clip file, so no bd_seek access-point rounding occurs.
        r->first = true;
        return r->pos = at;
    };
    info->size_fn = [](void *v) { return static_cast<Stream *>(v)->length; };
    info->close_fn = [](void *v) { delete static_cast<Stream *>(v); };
    info->cancel_fn = [](void *v) {
        auto r = static_cast<Stream *>(v); r->cancel.value = true; r->session->wake.notify_all();
    };
    return 0;
}
void quiet(const char *) {}
} // namespace

EXPORT int yd_register(void *mpv) {
#if defined(_WIN32)
    auto library = GetModuleHandleA("libmpv-2.dll");
    auto symbol = library ? reinterpret_cast<void *>(GetProcAddress(library, "mpv_stream_cb_add_ro")) : nullptr;
#else
    // Keep this module reference: MPV owns callbacks until its player is destroyed.
    static void *library = dlopen("libmpv.so", RTLD_NOW | RTLD_LOCAL);
    auto symbol = library ? dlsym(library, "mpv_stream_cb_add_ro") : nullptr;
#endif
    using Add = decltype(&mpv_stream_cb_add_ro);
    return symbol && mpv ? reinterpret_cast<Add>(symbol)(static_cast<mpv_handle *>(mpv), "yingyu-disc", nullptr, open_stream) : -1;
}
EXPORT int yd_open(const char *id, int64_t port, void *post_function, int iso) {
    if (!id || !valid_id(id) || !post_function || !port) return -1;
    auto s = std::make_shared<Session>(id, port, reinterpret_cast<Post>(post_function));
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        if (sessions.count(id)) return -1;
        sessions[id] = s;
    }
    std::thread([s, iso] {
        std::lock_guard<std::mutex> lock(s->io);
        bd_set_debug_handler(quiet); bd_set_debug_mask(0);
        s->bd = bd_init();
        int status = -1; std::string result;
        if (!s->closed && s->bd && (iso ? bd_open_stream(s->bd, s.get(), blocks) : bd_open_files(s->bd, s.get(), dir_open, file_open))) {
            const auto info = bd_get_disc_info(s->bd);
            if (info && info->bluray_detected) {
                if (info->aacs_detected || info->bdplus_detected) status = -2;
                else { result = disc_titles(s->bd); status = result.empty() ? -1 : 0; }
            }
        }
        s->deadline = Clock::time_point::max();
        if (!s->closed) post(*s, {number(0), number(status), string(result.c_str())});
    }).detach();
    return 0;
}
EXPORT int yd_select(const char *id, const char *clips) {
    auto s = find_session(id); if (!s) return -1;
    std::lock_guard<std::mutex> lock(s->io);
    if (s->closed || !clips) return -1;
    std::set<std::string> allowed;
    std::string list(clips);
    for (size_t at = 0; at < list.size(); at += 6) {
        auto name = list.substr(at, 5);
        if (name.size() != 5 || name.find_first_not_of("0123456789") != std::string::npos ||
            (at + 5 < list.size() && list[at + 5] != ',')) return -1;
        allowed.insert(name);
    }
    if (allowed.empty() || allowed.size() > 4096) return -1;
    s->allowed = std::move(allowed); s->ready = true; return 0;
}
EXPORT int yd_select_index(const char *id, int playlist) {
    auto s = find_session(id);
    if (!s || playlist < 0 || playlist > 99999) return -1;
    std::thread([s, playlist] {
        std::lock_guard<std::mutex> lock(s->io);
        if (s->closed) return;
        std::string result = "[]";
        // Index creation must never add network waits. Reuse only metadata
        // pages obtained during normal title parsing, otherwise return [].
        s->metadata_cache_only = true;
        if (s->ready && s->bd)
            result = disc_seek_index(s->bd, uint32_t(playlist), s->allowed);
        s->metadata_cache_only = false;
        if (!s->closed)
            post(*s, {number(-1), number(0), string(result.c_str())});
    }).detach();
    return 0;
}
EXPORT void yd_reply(int64_t id, int status, int64_t total, const uint8_t *bytes, int length) {
    if (length < 0 || length > PAGE || (length && !bytes)) return;
    std::lock_guard<std::mutex> registry(registry_mutex);
    auto it = requests.find(id); if (it == requests.end()) return;
    auto r = it->second; auto s = r->session.lock();
    if (!s || s->closed) return;
    std::lock_guard<std::mutex> lock(r->mutex);
    if (r->done) return;
    r->status = status; r->total = total;
    if (length) r->bytes.assign(bytes, bytes + length);
    r->done = true; s->wake.notify_all();
}
EXPORT void yd_close(const char *id) {
    std::shared_ptr<Session> s;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        auto it = sessions.find(id ? id : ""); if (it == sessions.end()) return;
        s = it->second; s->closed = true; sessions.erase(it);
    }
    // Never wait for the IO lock or destroy BLURAY while a stream owns it.
    s->wake.notify_all();
}
EXPORT int64_t yd_stat(const char *id, int key) {
    auto s = find_session(id); if (!s) return 0;
    switch (key) {
        case 0: return s->output;
        case 1: return s->requests;
        case 2: return s->wait_us;
        case 3: return s->read_us;
        case 4: return s->hits;
        default: return 0;
    }
}
EXPORT void *yd_alloc(int length) { return length > 0 && length <= 4 * PAGE ? std::malloc(length) : nullptr; }
EXPORT void yd_free(void *memory) { std::free(memory); }
