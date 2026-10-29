package com.yingyu.player;

import android.os.Handler;
import android.os.Looper;
import androidx.annotation.Keep;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** VideoLAN disc parsing only; media decoding stays in the existing MPV engine. */
@Keep
public final class DiscBridge {
    private static final int PAGE = 1024 * 1024;
    private static final Pattern RANGE = Pattern.compile("bytes (\\d+)-(\\d+)/(\\d+)");
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final MethodChannel channel;
    private volatile String activeId;
    private volatile boolean cancelled;
    private volatile boolean destroyed;
    private volatile HttpURLConnection connection;
    private volatile DiscOutputServer output;
    private volatile DiscOutputServer.Request outputRead;
    private final Object outputGate = new Object();
    private volatile String outputFailure;
    private long nativeHandle;
    private long deadline;
    private String base;
    private String ioError;
    private boolean loaded;
    private final Map<String, Long> sizes = new HashMap<>();
    private final java.util.Set<String> cancelledIds = java.util.concurrent.ConcurrentHashMap.newKeySet();
    // At most 8 MiB for both ISO filesystem metadata and media-sector lookups.
    private final LinkedHashMap<String, byte[]> pages = new LinkedHashMap<String, byte[]>(32, .75f, true) {
        @Override protected boolean removeEldestEntry(Map.Entry<String, byte[]> entry) { return size() > 8; }
    };

    public DiscBridge(FlutterEngine engine) {
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/disc");
        channel.setMethodCallHandler((call, result) -> {
            String id = call.argument("id");
            if ("outputStatus".equals(call.method)) {
                DiscOutputServer current = output;
                Map<String, Object> status = current != null && id != null && id.equals(activeId)
                    ? current.status() : new HashMap<>();
                if (id != null && id.equals(activeId) && outputFailure != null) status.put("error", outputFailure);
                result.success(status); return;
            }
            if ("close".equals(call.method)) {
                if (id != null) cancelledIds.add(id);
                if (id != null && id.equals(activeId)) cancel();
            }
            worker.execute(() -> {
                try {
                    Object value = null;
                    if ("open".equals(call.method)) {
                        closeNative();
                        if (destroyed || id == null || cancelledIds.contains(id)) throw new IOException("原盘读取已取消");
                        if (!loaded) { System.loadLibrary("yingyu_disc"); loaded = true; }
                        activeId = id; cancelled = false; ioError = null; outputFailure = null;
                        base = call.argument("base");
                        URI uri = URI.create(base);
                        if (!"http".equals(uri.getScheme()) || !"127.0.0.1".equals(uri.getHost()) || uri.getUserInfo() != null) {
                            throw new IOException("原盘本机读取入口无效");
                        }
                        deadline = System.nanoTime() + 120_000_000_000L;
                        nativeHandle = nativeOpen(Boolean.TRUE.equals(call.argument("iso")));
                        check();
                        if (nativeHandle == -1) { nativeHandle = 0; throw new IOException("原盘包含 AACS／BD+ 加密，当前读取组件不能解密"); }
                        if (nativeHandle == 0) throw new IOException(ioError != null ? ioError : "未找到可读取的蓝光 UDF／BDMV 结构");
                        String titles = nativeTitles(nativeHandle);
                        check();
                        if (titles == null || "[]".equals(titles)) throw new IOException(ioError != null ? ioError : "原盘没有有效播放列表，或列表数量超过限制");
                        ioError = null;
                        deadline = Long.MAX_VALUE;
                        value = titles;
                    } else if ("close".equals(call.method)) {
                        if (id != null && id.equals(activeId)) closeNative();
                        if (id != null) cancelledIds.remove(id);
                    } else {
                        if (id == null || !id.equals(activeId) || !isOpenHandle(nativeHandle)) throw new IOException("原盘会话已关闭");
                        check();
                        if ("output".equals(call.method)) {
                            if (output == null) output = startOutput(id, call.argument("clips"));
                            final String address = output.base();
                            main.post(() -> result.success(address)); return;
                        }
                        String path = call.argument("path");
                        if (path == null || !path.matches("BDMV/STREAM/[0-9]{5}\\.m2ts")) throw new IOException("原盘片段路径无效");
                        ioError = null;
                        if ("size".equals(call.method)) {
                            long length = nativeSize(nativeHandle, path);
                            if (length <= 0) throw new IOException(ioError != null ? ioError : "无法读取原盘片段长度");
                            value = length;
                        } else if ("read".equals(call.method)) {
                            Number at = call.argument("offset"), count = call.argument("length");
                            byte[] data = readClip(path, at.longValue(), count.intValue());
                            if (data == null) throw new IOException(ioError != null ? ioError : "原盘片段读取失败");
                            value = data;
                        } else { main.post(result::notImplemented); return; }
                    }
                    final Object delivered = value;
                    main.post(() -> result.success(delivered));
                } catch (Throwable error) {
                    if ("open".equals(call.method)) closeNative();
                    String message = error instanceof IOException ? error.getMessage() : "原盘组件操作失败：" + error.getClass().getSimpleName();
                    main.post(() -> result.error("disc", message, null));
                }
            });
        });
    }
    private void check() throws IOException {
        if (destroyed || cancelled || (activeId != null && cancelledIds.contains(activeId))) throw new IOException("原盘读取已取消");
        if (outputRead != null && outputRead.cancelled) throw new IOException("原盘旧位置读取已取消");
        if (System.nanoTime() > deadline) throw new IOException("原盘目录／播放列表解析超过 120 秒");
    }
    private DiscOutputServer startOutput(String id, java.util.List<String> clips) throws IOException {
        return new DiscOutputServer(id, clips, new DiscOutputServer.Source() {
            private <T> T execute(DiscOutputServer.Request request, java.util.concurrent.Callable<T> read) throws Exception {
                return worker.submit(() -> {
                    if (!id.equals(activeId) || request.cancelled || !isOpenHandle(nativeHandle))
                        throw new IOException("原盘会话已关闭");
                    synchronized (outputGate) { outputRead = request; }
                    try { check(); ioError = null; return read.call(); }
                    finally { synchronized (outputGate) { if (outputRead == request) outputRead = null; } }
                }).get();
            }
            public long size(String path, DiscOutputServer.Request request) throws Exception {
                return execute(request, () -> {
                    long value = nativeSize(nativeHandle, path);
                    if (value <= 0) throw new IOException("无法读取原盘片段长度");
                    return value;
                });
            }
            public byte[] read(String path, long offset, int length, DiscOutputServer.Request request) throws Exception {
                return execute(request, () -> readClip(path, offset, length));
            }
            public void cancel(DiscOutputServer.Request request) {
                synchronized (outputGate) {
                    if (outputRead == request) {
                        HttpURLConnection current = connection;
                        if (current != null) current.disconnect();
                    }
                }
            }
            public void failed() {
                if (id.equals(activeId)) outputFailure = "原盘后台读取失败，请重试";
            }
        });
    }
    private byte[] readClip(String path, long offset, int length) throws IOException {
        if (offset < 0 || length <= 0 || length > PAGE || offset > Long.MAX_VALUE - length) {
            throw new IOException("原盘片段读取范围无效");
        }
        // Preserve the fixed JNI ABI and its 256 KiB maximum. At high rates,
        // batch up to four existing reads into one background output write.
        if (length <= 256 * 1024) return nativeRead(nativeHandle, path, offset, length);
        byte[] result = new byte[length];
        for (int written = 0; written < length;) {
            check();
            int count = Math.min(256 * 1024, length - written);
            byte[] chunk = nativeRead(nativeHandle, path, offset + written, count);
            if (chunk == null || chunk.length != count) {
                throw new IOException(ioError != null ? ioError : "原盘片段提前结束");
            }
            System.arraycopy(chunk, 0, result, written, count);
            written += count;
        }
        check();
        return result;
    }
    private byte[] fetch(String path, long offset) throws IOException {
        check();
        HttpURLConnection c = (HttpURLConnection)new URL(base + "/input?path=" + URLEncoder.encode(path, "UTF-8")).openConnection();
        connection = c;
        c.setConnectTimeout(30_000); c.setReadTimeout(30_000); c.setInstanceFollowRedirects(false);
        c.setRequestProperty("Range", "bytes=" + offset + "-" + (offset + PAGE - 1));
        try {
            check();
            int status = c.getResponseCode();
            if (status == 404) { sizes.put(path, -1L); return null; }
            if (status != 206) throw new IOException("原盘随机读取需要 HTTP 206，实际为 HTTP " + status);
            Matcher m = RANGE.matcher(String.valueOf(c.getHeaderField("Content-Range")));
            if (!m.matches()) throw new IOException("原盘响应缺少有效 Content-Range");
            long begin = Long.parseLong(m.group(1)), end = Long.parseLong(m.group(2)), total = Long.parseLong(m.group(3));
            if (begin != offset || end < begin || end - begin >= PAGE || total <= end) throw new IOException("原盘响应的字节范围不匹配");
            Long old = sizes.put(path, total);
            if (old != null && old != total) throw new IOException("原盘资源长度发生变化，请重新打开");
            int expected = (int)(end - begin + 1);
            byte[] data = new byte[expected];
            try (InputStream input = c.getInputStream()) {
                int at = 0;
                while (at < expected) { check(); int n = input.read(data, at, expected - at); if (n < 0) throw new IOException("原盘响应提前结束"); at += n; }
            }
            return data;
        } catch (IOException e) {
            ioError = "原盘网络读取失败：" + (e.getMessage() != null && e.getMessage().startsWith("原盘") ? e.getMessage() : e.getClass().getSimpleName());
            throw e;
        } finally { c.disconnect(); connection = null; }
    }
    @Keep public byte[] readRemote(String path, long offset, int length) throws IOException {
        check();
        if (offset < 0 || length < 0 || length > PAGE) throw new IOException("原盘读取范围无效");
        ByteArrayOutputStream out = new ByteArrayOutputStream(length);
        while (out.size() < length) {
            long pos = offset + out.size();
            Long total = sizes.get(path);
            if (total != null && (total < 0 || pos >= total)) break;
            long pageAt = pos / PAGE * PAGE;
            String key = path + ":" + pageAt;
            byte[] page = pages.get(key);
            if (page == null) { page = fetch(path, pageAt); if (page == null) break; pages.put(key, page); }
            int start = (int)(pos - pageAt), n = Math.min(length - out.size(), page.length - start);
            if (n <= 0) throw new IOException("原盘响应不足以满足范围读取");
            out.write(page, start, n);
        }
        return out.toByteArray();
    }
    @Keep public long remoteSize(String path) throws IOException {
        if (!sizes.containsKey(path)) readRemote(path, 0, 1);
        return sizes.getOrDefault(path, -1L);
    }
    @Keep public String listRemote(String path) throws IOException {
        check();
        HttpURLConnection c = (HttpURLConnection)new URL(base + "/list?path=" + URLEncoder.encode(path, "UTF-8")).openConnection();
        connection = c; c.setConnectTimeout(30_000); c.setReadTimeout(30_000); c.setInstanceFollowRedirects(false);
        try {
            int status = c.getResponseCode();
            if (status == 404) return null;
            if (status != 200) throw new IOException("原盘目录读取返回 HTTP " + status);
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            try (InputStream in = c.getInputStream()) {
                byte[] buffer = new byte[8192]; int n;
                while ((n = in.read(buffer)) >= 0) { check(); if (output.size() + n > 128 * 1024) throw new IOException("原盘目录条目过多"); output.write(buffer, 0, n); }
            }
            return output.toString("UTF-8");
        } finally { c.disconnect(); connection = null; }
    }
    private static boolean isOpenHandle(long handle) {
        // JNI jlong is signed, but Android's tagged heap pointers can set its
        // high bit. Preserve all pointer bits; only our two sentinels are invalid.
        return handle != 0 && handle != -1;
    }
    private void closeNative() {
        DiscOutputServer old = output; output = null;
        if (old != null) old.close();
        if (isOpenHandle(nativeHandle)) nativeClose(nativeHandle);
        nativeHandle = 0; pages.clear(); sizes.clear();
    }
    private void cancel() {
        cancelled = true;
        DiscOutputServer current = output; if (current != null) current.close();
        HttpURLConnection c = connection; if (c != null) c.disconnect();
    }
    public void destroy() { destroyed = true; cancel(); channel.setMethodCallHandler(null); worker.execute(this::closeNative); worker.shutdown(); }
    private native long nativeOpen(boolean iso);
    private native String nativeTitles(long handle);
    private native long nativeSize(long handle, String path);
    private native byte[] nativeRead(long handle, String path, long offset, int length);
    private native void nativeClose(long handle);
}
