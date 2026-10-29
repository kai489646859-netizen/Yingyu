package com.yingyu.player;

import java.net.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import static com.yingyu.player.DiscBridgeHostTest.*;

final class DiscOutputHostCases {
    static final long OFFSET = 8_589_934_592L;
    static final int MIB = 1024 * 1024;
    static String start(Fixture f) throws Exception {
        await(f.open("a", TAGGED));
        return (String)await(f.channel.call("output", Map.of("id", "a", "clips", List.of("00001"))));
    }
    static HttpURLConnection request(String base, String method, String range, String clip) throws Exception {
        HttpURLConnection c = (HttpURLConnection)URI.create(base + "/clip/" + clip).toURL().openConnection();
        c.setConnectTimeout(2000); c.setReadTimeout(2000); c.setRequestMethod(method);
        if (range != null) c.setRequestProperty("Range", range);
        return c;
    }
    static Map<?, ?> status(Fixture f) throws Exception {
        return (Map<?, ?>)await(f.channel.call("outputStatus", Map.of("id", "a")));
    }
    static byte[] read(HttpURLConnection c) throws Exception {
        try { check(c.getResponseCode() == 206, "expected 206"); return c.getInputStream().readAllBytes(); }
        finally { c.disconnect(); }
    }
    static void data(byte[] bytes, int count) {
        check(bytes.length == count, "wrong delivered length: " + bytes.length);
        for (int i = 0; i < count; i++) check(bytes[i] == (byte)(i % 251), "wrong byte at " + i);
    }
    static void until(Callable<Boolean> predicate) throws Exception {
        for (int i = 0; i < 150; i++) { if (predicate.call()) return; Thread.sleep(5); }
        check(predicate.call(), "condition did not complete");
    }
    static void run() {
        test("first probe bytes are delivered without waiting for the rest of a 1 MiB batch", () -> {
            CountDownLatch tail = new CountDownLatch(1);
            DiscOutputServer.Source source = new DiscOutputServer.Source() {
                public long size(String p, DiscOutputServer.Request r) { return 2L * MIB; }
                public byte[] read(String p, long at, int n, DiscOutputServer.Request r) throws Exception {
                    if (at + n > 256 * 1024) check(tail.await(3, TimeUnit.SECONDS), "tail was never released");
                    byte[] data = new byte[n]; Arrays.fill(data, (byte)37); return data;
                }
                public void cancel(DiscOutputServer.Request r) { tail.countDown(); }
                public void failed() { }
            };
            try (DiscOutputServer server = new DiscOutputServer("prefix", List.of("00001"), source)) {
                HttpURLConnection c = request(server.base(), "GET", "bytes=0-", "00001.m2ts");
                c.setReadTimeout(700);
                try {
                    check(c.getResponseCode() == 206, "headers missing");
                    byte[] prefix = c.getInputStream().readNBytes(256 * 1024);
                    check(prefix.length == 256 * 1024 && tail.getCount() == 1, "first bytes waited for unrelated tail");
                    for (byte b : prefix) check(b == 37, "first bytes changed");
                    tail.countDown();
                    check(c.getInputStream().readAllBytes().length == 2 * MIB - prefix.length, "remaining bytes lost");
                } finally { tail.countDown(); c.disconnect(); }
            }
        });
        test("background HTTP delivers 1 MiB through real bridge and four bounded JNI calls", () -> {
            try (Fixture f = new Fixture()) {
                String base = start(f);
                data(read(request(base, "GET", "bytes=" + OFFSET + "-" + (OFFSET + MIB - 1), "00001.m2ts")), MIB);
                check(SyntheticNative.reads == 4, "native batch count changed");
                until(() -> ((Number)status(f).get("bytes")).longValue() == MIB);
                check(!Boolean.TRUE.equals(status(f).get("failed")), "successful body marked failed");
            }
        });
        test("background HEAD preserves large content length without media reads", () -> {
            try (Fixture f = new Fixture()) {
                HttpURLConnection c = request(start(f), "HEAD", null, "00001.m2ts");
                try {
                    check(c.getResponseCode() == 200 && c.getContentLengthLong() == 9_663_676_416L, "64-bit length changed");
                    check(c.getInputStream().read() == -1 && SyntheticNative.reads == 0, "HEAD read media");
                } finally { c.disconnect(); }
            }
        });
        test("background route rejects wrong session, clip and methods before JNI", () -> {
            try (Fixture f = new Fixture()) {
                String base = start(f);
                for (String clip : List.of("00002.m2ts", "../00001.m2ts", "00001.m2ts?x=1")) {
                    HttpURLConnection c = request(base, "GET", null, clip);
                    check(c.getResponseCode() == 404, "unsafe clip accepted"); c.disconnect();
                }
                HttpURLConnection c = request(base.replace("/a", "/wrong"), "GET", null, "00001.m2ts");
                check(c.getResponseCode() == 404, "wrong session accepted"); c.disconnect();
                c = request(base, "POST", null, "00001.m2ts");
                check(c.getResponseCode() == 404, "POST accepted"); c.disconnect();
                check(SyntheticNative.reads == 0 && SyntheticNative.sizes == 0, "rejected request reached JNI");
            }
        });
        test("invalid and multi-ranges return 416 without body reads", () -> {
            try (Fixture f = new Fixture()) {
                String base = start(f);
                for (String range : List.of("bytes=5-3", "bytes=0-1,8-9", "bytes=-0", "bytes=99999999999-", "bytes=9223372036854775808-")) {
                    HttpURLConnection c = request(base, "GET", range, "00001.m2ts");
                    check(c.getResponseCode() == 416, "invalid range accepted");
                    check("bytes */9663676416".equals(c.getHeaderField("Content-Range")), "missing actual length");
                    c.disconnect();
                }
                check(SyntheticNative.reads == 0, "invalid range read bytes");
            }
        });
        test("range parser preserves EOF, suffix and 64-bit boundaries", () -> {
            check(Arrays.equals(DiscOutputServer.range("bytes=-4", 10), new long[]{6, 9}), "suffix changed");
            check(Arrays.equals(DiscOutputServer.range("bytes=8-100", 10), new long[]{8, 9}), "EOF not clamped");
            check(Arrays.equals(DiscOutputServer.range("bytes=8589934592-", 9663676416L), new long[]{8589934592L, 9663676415L}), "64-bit offset truncated");
            check(DiscOutputServer.range("bytes=10-", 10) == null && DiscOutputServer.range("bytes=-", 10) == null, "invalid boundary accepted");
        });
        test("control status remains responsive while native read is blocked", () -> {
            try (Fixture f = new Fixture()) {
                String base = start(f);
                SyntheticNative.readEntered = new CountDownLatch(1); SyntheticNative.readRelease = new CountDownLatch(1);
                HttpURLConnection c = request(base, "GET", "bytes=" + OFFSET + "-" + (OFFSET + MIB - 1), "00001.m2ts");
                try {
                    check(c.getResponseCode() == 206, "headers missing");
                    check(SyntheticNative.readEntered.await(2, TimeUnit.SECONDS), "not reading");
                    Object value = f.channel.call("outputStatus", Map.of("id", "a")).get(300, TimeUnit.MILLISECONDS);
                    check(((Number)((Map<?, ?>)value).get("active")).intValue() == 1, "active status missing");
                } finally { SyntheticNative.readRelease.countDown(); c.disconnect(); }
            }
        });
        test("superseded GET cancels old read without poisoning the replacement", () -> {
            try (Fixture f = new Fixture()) {
                String base = start(f);
                SyntheticNative.readEntered = new CountDownLatch(1); SyntheticNative.readRelease = new CountDownLatch(1);
                HttpURLConnection old = request(base, "GET", "bytes=" + OFFSET + "-" + (OFFSET + MIB - 1), "00001.m2ts");
                HttpURLConnection next = request(base, "GET", "bytes=" + OFFSET + "-" + (OFFSET + 15), "00001.m2ts");
                try {
                    check(old.getResponseCode() == 206, "old headers missing");
                    check(SyntheticNative.readEntered.await(2, TimeUnit.SECONDS), "not reading old range");
                    CompletableFuture<byte[]> incoming = CompletableFuture.supplyAsync(() -> {
                        try { return read(next); } catch (Exception e) { throw new CompletionException(e); }
                    });
                    until(() -> ((Number)status(f).get("requests")).intValue() == 2);
                    SyntheticNative.readRelease.countDown();
                    data(incoming.get(2, TimeUnit.SECONDS), 16);
                    check(SyntheticNative.reads == 2, "old batch continued after replacement");
                    check(!Boolean.TRUE.equals(status(f).get("failed")), "seek marked as media failure");
                } finally { SyntheticNative.readRelease.countDown(); old.disconnect(); next.disconnect(); }
            }
        });
        test("real truncated source stays failed in output status", () -> {
            try (Fixture f = new Fixture()) {
                String base = start(f); SyntheticNative.shortReadAt = 2;
                HttpURLConnection c = request(base, "GET", "bytes=" + OFFSET + "-" + (OFFSET + MIB - 1), "00001.m2ts");
                try {
                    check(c.getResponseCode() == 206, "headers missing");
                    byte[] body = c.getInputStream().readAllBytes();
                    check(body.length < MIB, "failure concealed with invented bytes");
                    until(() -> Boolean.TRUE.equals(status(f).get("failed")));
                    check(status(f).get("error") != null, "missing visible source failure");
                    int reads = SyntheticNative.reads;
                    HttpURLConnection retry = request(base, "GET", "bytes=" + OFFSET + "-" + (OFFSET + 15), "00001.m2ts");
                    try { check(retry.getResponseCode() == 502, "terminal failure silently retried"); }
                    finally { retry.disconnect(); }
                    check(SyntheticNative.reads == reads, "failed output read the source again");
                } finally { c.disconnect(); }
            }
        });
        test("close shuts down the private output listener and retains opaque ownership", () -> {
            try (Fixture f = new Fixture()) {
                String base = start(f); await(f.stop("a"));
                HttpURLConnection c = request(base, "HEAD", null, "00001.m2ts");
                try { c.getResponseCode(); throw new AssertionError("closed server accepted a request"); }
                catch (IOException expected) {} finally { c.disconnect(); }
                check(SyntheticNative.closed.equals(List.of(TAGGED)), "native handle leaked");
                check(status(f).isEmpty(), "closed output kept statistics as an active session");
            }
        });
        test("replacement headers bypass two stalled output writers", () -> {
            DiscOutputServer.Source source = new DiscOutputServer.Source() {
                public long size(String path, DiscOutputServer.Request request) { return 32L * MIB; }
                public byte[] read(String path, long offset, int count, DiscOutputServer.Request request) {
                    byte[] data = new byte[count]; Arrays.fill(data, (byte)90); return data;
                }
                public void cancel(DiscOutputServer.Request request) {}
                public void failed() { throw new AssertionError("cancelled writer marked as source failure"); }
            };
            try (DiscOutputServer server = new DiscOutputServer("stall", List.of("00001", "00002"), source)) {
                URI base = URI.create(server.base());
                try (Socket first = new Socket(); Socket second = new Socket()) {
                    int clip = 1;
                    for (Socket socket : List.of(first, second)) {
                        socket.setReceiveBufferSize(1024);
                        socket.connect(new InetSocketAddress(base.getHost(), base.getPort()), 2000);
                        socket.getOutputStream().write(("GET /stall/clip/0000" + clip++ + ".m2ts HTTP/1.1\r\nHost: localhost\r\n\r\n").getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                        socket.getOutputStream().flush();
                    }
                    until(() -> ((Number)server.status().get("active")).intValue() == 2);
                    // No body is consumed on either socket; a new seek must
                    // cancel its predecessor before waiting for a writer.
                    byte[] next = read(request(server.base(), "GET", "bytes=0-15", "00001.m2ts"));
                    check(next.length == 16 && next[0] == 90, "replacement was blocked by stale writers");
                    check(!Boolean.TRUE.equals(server.status().get("failed")), "backpressure became source failure");
                }
            }
        });
        test("stale session cannot open or inspect another output listener", () -> {
            try (Fixture f = new Fixture()) {
                String base = start(f);
                expectError(f.channel.call("output", Map.of("id", "old", "clips", List.of("00001"))), "会话已关闭");
                check(((Map<?, ?>)await(f.channel.call("outputStatus", Map.of("id", "old")))).isEmpty(), "stale output status exposed");
                data(read(request(base, "GET", "bytes=" + OFFSET + "-" + (OFFSET + 15), "00001.m2ts")), 16);
            }
        });
    }
}
