#include <jni.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <sstream>
#include <string>
extern "C" {
#include "libbluray/bluray.h"
#include "file/filesystem.h"
#include "util/log_control.h"
}

// All calls, including callbacks, run on DiscBridge's serial worker. No JNI
// pointers or BLURAY handles cross worker threads. The Java side owns I/O.
struct Disc {
    JNIEnv *env;
    jobject owner;
    jmethodID read, size, list;
    BLURAY *bd = nullptr;
    std::map<std::string, BD_FILE_H *> files;
    ~Disc() {
        for (auto &entry : files) entry.second->close(entry.second);
        if (bd) bd_close(bd);
        env->DeleteGlobalRef(owner);
    }
};
static void quiet(const char *) {}
static bool exception(Disc *d) {
    if (!d->env->ExceptionCheck()) return false;
    d->env->ExceptionClear(); // Java remembers the bounded, sanitized I/O error.
    return true;
}
#include "disc_metadata.h"
static int64_t remote_read(Disc *d, const char *path, int64_t pos, uint8_t *out, int64_t count) {
    int64_t done = 0;
    while (done < count) {
        const int step = (int)std::min<int64_t>(count - done, 256 * 1024);
        jstring name = d->env->NewStringUTF(path);
        auto data = (jbyteArray)d->env->CallObjectMethod(d->owner, d->read, name, (jlong)(pos + done), (jint)step);
        d->env->DeleteLocalRef(name);
        if (exception(d) || !data) return -1;
        int n = d->env->GetArrayLength(data);
        if (n > step) { d->env->DeleteLocalRef(data); return -1; }
        d->env->GetByteArrayRegion(data, 0, n, (jbyte *)(out + done));
        d->env->DeleteLocalRef(data);
        done += n;
        if (n < step) break;
    }
    return done;
}
static int blocks(void *handle, void *buf, int lba, int count) {
    if (lba < 0 || count <= 0) return 0;
    auto n = remote_read((Disc *)handle, "", (int64_t)lba * 2048, (uint8_t *)buf, (int64_t)count * 2048);
    return n < 0 ? 0 : (int)(n / 2048);
}
struct RemoteFile { Disc *disc; std::string path; int64_t size, pos = 0; };
static BD_FILE_H *file_open(void *handle, const char *path) {
    Disc *d = (Disc *)handle;
    jstring name = d->env->NewStringUTF(path);
    jlong size = d->env->CallLongMethod(d->owner, d->size, name);
    d->env->DeleteLocalRef(name);
    if (exception(d) || size < 0) return nullptr;
    auto f = new BD_FILE_H{};
    f->internal = new RemoteFile{d, path, size};
    f->close = [](BD_FILE_H *f) { delete (RemoteFile *)f->internal; delete f; };
    f->tell = [](BD_FILE_H *f) { return ((RemoteFile *)f->internal)->pos; };
    f->seek = [](BD_FILE_H *f, int64_t offset, int32_t origin) -> int64_t {
        auto r = (RemoteFile *)f->internal;
        const int64_t base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? r->pos : origin == SEEK_END ? r->size : -1;
        if (base < 0 || offset < -base || offset > r->size - base) return -1;
        return r->pos = base + offset;
    };
    f->read = [](BD_FILE_H *f, uint8_t *out, int64_t count) -> int64_t {
        auto r = (RemoteFile *)f->internal;
        if (count < 0) return -1;
        auto n = remote_read(r->disc, r->path.c_str(), r->pos, out, std::min(count, r->size - r->pos));
        if (n > 0) r->pos += n;
        return n;
    };
    return f;
}
struct RemoteDir { std::string entries; size_t at = 0; };
static BD_DIR_H *dir_open(void *handle, const char *path) {
    Disc *d = (Disc *)handle;
    jstring name = d->env->NewStringUTF(path);
    auto value = (jstring)d->env->CallObjectMethod(d->owner, d->list, name);
    d->env->DeleteLocalRef(name);
    if (exception(d) || !value) return nullptr;
    const char *text = d->env->GetStringUTFChars(value, nullptr);
    auto state = new RemoteDir{std::string(text)};
    d->env->ReleaseStringUTFChars(value, text);
    d->env->DeleteLocalRef(value);
    auto dir = new BD_DIR_H{};
    dir->internal = state;
    dir->close = [](BD_DIR_H *v) { delete (RemoteDir *)v->internal; delete v; };
    dir->read = [](BD_DIR_H *v, BD_DIRENT *entry) {
        auto s = (RemoteDir *)v->internal;
        if (s->at >= s->entries.size()) return 1;
        auto end = s->entries.find('\n', s->at);
        if (end == std::string::npos) end = s->entries.size();
        auto name = s->entries.substr(s->at, end - s->at); s->at = end + 1;
        if (name.empty() || name.size() >= sizeof(entry->d_name)) return -1;
        std::memcpy(entry->d_name, name.c_str(), name.size() + 1);
        return 0;
    };
    return dir;
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_yingyu_player_DiscBridge_nativeOpen(JNIEnv *env, jobject owner, jboolean iso) {
    bd_set_debug_handler(quiet); bd_set_debug_mask(0);
    auto d = new Disc{}; d->env = env; d->owner = env->NewGlobalRef(owner);
    auto klass = env->GetObjectClass(owner);
    d->read = env->GetMethodID(klass, "readRemote", "(Ljava/lang/String;JI)[B");
    d->size = env->GetMethodID(klass, "remoteSize", "(Ljava/lang/String;)J");
    d->list = env->GetMethodID(klass, "listRemote", "(Ljava/lang/String;)Ljava/lang/String;");
    env->DeleteLocalRef(klass);
    d->bd = bd_init();
    if (!d->bd || !(iso ? bd_open_stream(d->bd, d, blocks) : bd_open_files(d->bd, d, dir_open, file_open))) {
        delete d; return 0;
    }
    const auto info = bd_get_disc_info(d->bd);
    if (!info || !info->bluray_detected) { delete d; return 0; }
    if (info->aacs_detected || info->bdplus_detected) { delete d; return -1; }
    return (jlong)d;
}
extern "C" JNIEXPORT jstring JNICALL
Java_com_yingyu_player_DiscBridge_nativeTitles(JNIEnv *env, jobject, jlong handle) {
    auto d = (Disc *)handle; d->env = env;
    const auto result = disc_titles(d->bd);
    return result.empty() ? nullptr : env->NewStringUTF(result.c_str());
}

static BD_FILE_H *clip(Disc *d, const std::string &path) {
    if (path.size() != 22 || path.substr(0, 12) != "BDMV/STREAM/" || path.substr(17) != ".m2ts") return nullptr;
    for (int i = 12; i < 17; i++) if (path[i] < '0' || path[i] > '9') return nullptr;
    auto found = d->files.find(path);
    if (found != d->files.end()) return found->second;
    auto f = bd_open_file_dec(d->bd, path.c_str());
    if (!f) return nullptr;
    if (d->files.size() >= 4) { auto old = d->files.begin(); old->second->close(old->second); d->files.erase(old); }
    d->files[path] = f; return f;
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_yingyu_player_DiscBridge_nativeSize(JNIEnv *env, jobject, jlong handle, jstring path) {
    auto d = (Disc *)handle; d->env = env;
    const char *name = env->GetStringUTFChars(path, nullptr); auto f = clip(d, name); env->ReleaseStringUTFChars(path, name);
    if (!f) return -1;
    auto pos = f->tell(f); auto size = f->seek(f, 0, SEEK_END); f->seek(f, pos, SEEK_SET); return size;
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_yingyu_player_DiscBridge_nativeRead(JNIEnv *env, jobject, jlong handle, jstring path, jlong offset, jint length) {
    if (length <= 0 || length > 256 * 1024 || offset < 0) return nullptr;
    auto d = (Disc *)handle; d->env = env;
    const char *name = env->GetStringUTFChars(path, nullptr); auto f = clip(d, name); env->ReleaseStringUTFChars(path, name);
    if (!f || f->seek(f, offset, SEEK_SET) != offset) return nullptr;
    auto buf = new uint8_t[length]; auto n = f->read(f, buf, length);
    jbyteArray result = nullptr;
    if (n >= 0 && n <= length) { result = env->NewByteArray((jsize)n); env->SetByteArrayRegion(result, 0, (jsize)n, (jbyte *)buf); }
    delete[] buf; return result;
}
extern "C" JNIEXPORT void JNICALL
Java_com_yingyu_player_DiscBridge_nativeClose(JNIEnv *env, jobject, jlong handle) {
    auto d = (Disc *)handle; if (d) { d->env = env; delete d; }
}
