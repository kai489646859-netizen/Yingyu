package com.yingyu.player;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Fake opaque JNI values only. These numbers are never dereferenced. */
final class SyntheticNative {
    static long nextHandle;
    static final Set<Long> live = new HashSet<>();
    static final List<Long> closed = new ArrayList<>();
    static int reads, sizes;
    static boolean failTitles;
    static CountDownLatch titlesEntered, titlesRelease;
    static CountDownLatch readEntered, readRelease;
    static int shortReadAt;
    static DiscBridge loopbackBridge;
    static long loopbackSize;
    static void reset() {
        live.clear(); closed.clear(); reads = sizes = 0; failTitles = false;
        titlesEntered = titlesRelease = null;
        readEntered = readRelease = null; shortReadAt = -1;
        loopbackBridge = null; loopbackSize = 0;
    }
    static void load() {}
    static long open(boolean iso) {
        if (nextHandle != 0 && nextHandle != -1) live.add(nextHandle);
        return nextHandle;
    }
    static void valid(long handle) {
        if (!live.contains(handle)) throw new AssertionError("Native handle bits changed or resource already closed");
    }
    static String titles(long handle) {
        valid(handle);
        if (titlesEntered != null) titlesEntered.countDown();
        if (titlesRelease != null) {
            try {
                if (!titlesRelease.await(3, TimeUnit.SECONDS)) throw new AssertionError("test gate timed out");
            } catch (InterruptedException error) { throw new AssertionError(error); }
        }
        return failTitles ? null : "[{\"playlist\":1,\"duration\":90000,\"clips\":[{\"id\":\"00001\",\"in\":0,\"out\":90000}]}]";
    }
    static long size(long handle, String path) { valid(handle); sizes++; return loopbackBridge == null ? 9_663_676_416L : loopbackSize; }
    static byte[] read(long handle, String path, long offset, int length) {
        valid(handle); reads++;
        if (loopbackBridge != null) {
            try { return loopbackBridge.readRemote("", offset, length); }
            catch (java.io.IOException error) { throw new RuntimeException(error); }
        }
        if (!path.equals("BDMV/STREAM/00001.m2ts") || offset < 8_589_934_592L || offset >= 8_589_934_592L + 1024 * 1024) throw new AssertionError("clip or 64-bit offset changed");
        if (length <= 0 || length > 256 * 1024) throw new AssertionError("fixed native read limit exceeded");
        if (readEntered != null && reads == 1) {
            readEntered.countDown();
            try { if (!readRelease.await(3, TimeUnit.SECONDS)) throw new AssertionError("read gate timeout"); }
            catch (InterruptedException e) { throw new AssertionError(e); }
        }
        if (reads == shortReadAt) length--;
        byte[] result = new byte[length];
        for (int i = 0; i < length; i++) result[i] = (byte)((offset - 8_589_934_592L + i) % 251);
        return result;
    }
    static void close(long handle) {
        valid(handle); live.remove(handle); closed.add(handle);
    }
}
