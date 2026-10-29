package com.yingyu.player;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;

public final class DiscBridgeHostTest {
    static final long TAGGED = 0xB400000012340000L;
    static final List<String> cases = new ArrayList<>();
    static int passed, failed;
    interface Checked { void run() throws Exception; }
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    static Object await(CompletableFuture<Object> future) throws Exception { return future.get(3, TimeUnit.SECONDS); }
    static void expectError(CompletableFuture<Object> future, String message) throws Exception {
        try { await(future); throw new AssertionError("Expected rejection: " + message); }
        catch (ExecutionException error) { check(error.getCause().getMessage().contains(message), error.getCause().toString()); }
    }
    static String quote(String text) { return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r") + "\""; }
    static void test(String name, Checked body) {
        SyntheticNative.reset();
        try {
            body.run(); passed++;
            cases.add("{\"name\":" + quote(name) + ",\"passed\":true}");
        } catch (Throwable error) {
            failed++;
            cases.add("{\"name\":" + quote(name) + ",\"passed\":false,\"detail\":" + quote(error.toString()) + "}");
        }
    }
    static final class Fixture implements AutoCloseable {
        final DiscBridge bridge = new DiscBridge(new FlutterEngine());
        final MethodChannel channel = MethodChannel.latest;
        boolean destroyed;
        CompletableFuture<Object> open(String id, long handle) {
            SyntheticNative.nextHandle = handle;
            return channel.call("open", Map.of("id", id, "iso", true, "base", "http://127.0.0.1:12345/synthetic"));
        }
        CompletableFuture<Object> size(String id) { return channel.call("size", Map.of("id", id, "path", "BDMV/STREAM/00001.m2ts")); }
        CompletableFuture<Object> read(String id) {
            return read(id, 16);
        }
        CompletableFuture<Object> read(String id, int length) {
            return channel.call("read", Map.of("id", id, "path", "BDMV/STREAM/00001.m2ts", "offset", 8_589_934_592L, "length", length));
        }
        CompletableFuture<Object> stop(String id) { return channel.call("close", Map.of("id", id)); }
        public void close() throws Exception {
            if (destroyed) return;
            destroyed = true; bridge.destroy();
            Field field = DiscBridge.class.getDeclaredField("worker"); field.setAccessible(true);
            check(((ExecutorService)field.get(bridge)).awaitTermination(3, TimeUnit.SECONDS), "bridge worker did not stop");
        }
    }
    static void readCycle(long handle) throws Exception {
        try (Fixture f = new Fixture()) {
            check(await(f.open("a", handle)).toString().contains("playlist"), "title parsing failed");
            check(await(f.size("a")).equals(9_663_676_416L), "64-bit clip length changed");
            byte[] expected = new byte[16]; for (int i = 0; i < 16; i++) expected[i] = (byte)i;
            check(Arrays.equals((byte[])await(f.read("a")), expected), "clip bytes changed");
            await(f.stop("a")); await(f.stop("a"));
            check(SyntheticNative.closed.equals(List.of(handle)), "close must release exact handle once");
            expectError(f.read("a"), "会话已关闭");
            check(SyntheticNative.reads == 1, "read reached JNI after close");
        }
    }
    public static void main(String[] args) {
        System.setOut(new java.io.PrintStream(System.out, true, java.nio.charset.StandardCharsets.UTF_8));
        test("positive handle: titles, large offset read, close", () -> readCycle(0x12340000L));
        test("32-bit unsigned pointer in jlong", () -> readCycle(0xF2340000L));
        test("Android tagged negative handle: titles, clip, close", () -> readCycle(TAGGED));
        test("high-bit negative handle remains opaque", () -> readCycle(Long.MIN_VALUE + 4096));
        test("destroy releases a tagged handle", () -> {
            try (Fixture f = new Fixture()) {
                await(f.open("a", TAGGED)); f.close();
                check(SyntheticNative.closed.equals(List.of(TAGGED)), "destroy leaked the tagged handle");
            }
        });
        test("title failure releases a tagged handle", () -> {
            try (Fixture f = new Fixture()) {
                SyntheticNative.failTitles = true;
                expectError(f.open("a", TAGGED), "没有有效播放列表");
                check(SyntheticNative.closed.equals(List.of(TAGGED)), "failed open leaked the tagged handle");
            }
        });
        test("null and encrypted sentinel never reach close JNI", () -> {
            try (Fixture f = new Fixture()) {
                expectError(f.open("a", 0), "未找到可读取");
                expectError(f.open("b", -1), "AACS");
                check(SyntheticNative.closed.isEmpty(), "attempted to free a sentinel");
            }
        });
        test("stale session calls cannot read or close the current disc", () -> {
            try (Fixture f = new Fixture()) {
                await(f.open("new", TAGGED));
                expectError(f.size("old"), "会话已关闭");
                await(f.stop("old"));
                check(await(f.size("new")).equals(9_663_676_416L), "stale close affected current disc");
                check(SyntheticNative.sizes == 1, "stale read reached JNI");
            }
        });
        test("replacement closes the old tagged session once", () -> {
            try (Fixture f = new Fixture()) {
                await(f.open("old", TAGGED)); await(f.open("new", 0x67890000L));
                check(SyntheticNative.closed.equals(List.of(TAGGED)), "old disc was not released");
                await(f.stop("old")); await(f.size("new")); await(f.stop("new"));
                check(SyntheticNative.live.isEmpty() && SyntheticNative.closed.size() == 2, "replacement leaked a disc");
            }
        });
        test("cancel during title parsing releases the tagged session", () -> {
            try (Fixture f = new Fixture()) {
                SyntheticNative.titlesEntered = new CountDownLatch(1);
                SyntheticNative.titlesRelease = new CountDownLatch(1);
                CompletableFuture<Object> opening = f.open("a", TAGGED);
                check(SyntheticNative.titlesEntered.await(3, TimeUnit.SECONDS), "title gate was not reached");
                CompletableFuture<Object> closing = f.stop("a");
                SyntheticNative.titlesRelease.countDown();
                expectError(opening, "已取消"); await(closing);
                check(SyntheticNative.closed.equals(List.of(TAGGED)), "cancel leaked the tagged handle");
            }
        });
        test("one MiB delivery preserves four bounded JNI reads and exact bytes", () -> {
            try (Fixture f = new Fixture()) {
                await(f.open("a", TAGGED));
                byte[] bytes = (byte[])await(f.read("a", 1024 * 1024));
                check(bytes.length == 1024 * 1024 && SyntheticNative.reads == 4, "unexpected batch size");
                for (int i = 0; i < bytes.length; i++) check(bytes[i] == (byte)(i % 251), "batch byte order changed");
            }
        });
        test("oversized batch is rejected without JNI reads", () -> {
            try (Fixture f = new Fixture()) {
                await(f.open("a", TAGGED));
                expectError(f.read("a", 1024 * 1024 + 1), "范围无效");
                check(SyntheticNative.reads == 0, "invalid range reached JNI");
            }
        });
        test("truncated JNI chunk stops batch without inventing bytes", () -> {
            try (Fixture f = new Fixture()) {
                await(f.open("a", TAGGED)); SyntheticNative.shortReadAt = 2;
                expectError(f.read("a", 1024 * 1024), "提前结束");
                check(SyntheticNative.reads == 2, "read past failure");
            }
        });
        test("cancellation interrupts a batch between JNI chunks", () -> {
            try (Fixture f = new Fixture()) {
                await(f.open("a", TAGGED));
                SyntheticNative.readEntered = new CountDownLatch(1); SyntheticNative.readRelease = new CountDownLatch(1);
                CompletableFuture<Object> reading = f.read("a", 1024 * 1024);
                check(SyntheticNative.readEntered.await(3, TimeUnit.SECONDS), "read gate not reached");
                CompletableFuture<Object> closing = f.stop("a");
                SyntheticNative.readRelease.countDown(); expectError(reading, "已取消"); await(closing);
                check(SyntheticNative.reads == 1, "read past cancellation");
                check(SyntheticNative.closed.equals(List.of(TAGGED)), "cancel leaked handle");
            }
        });
        DiscOutputHostCases.run();
        System.out.println("{\"passed\":" + passed + ",\"failed\":" + failed + ",\"cases\":[" + String.join(",", cases) + "]}");
        if (failed != 0) System.exit(1);
    }
}
