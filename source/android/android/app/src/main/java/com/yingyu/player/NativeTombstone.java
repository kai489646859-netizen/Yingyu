package com.yingyu.player;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** Bounded, streaming projection of AOSP tombstone.proto. Never exports raw traces. */
final class NativeTombstone {
    static final int MAX_BYTES = 32 * 1024 * 1024;
    static final int MAX_FRAMES = 64;
    static final int MAX_THREADS = 256;
    private static final String[] ARCH = {"arm", "arm64", "x86", "x86_64"};

    static final class Limit extends IOException {
        final String kind;
        Limit(String kind) { super(kind); this.kind = kind; }
    }

    private static final class Cursor {
        final InputStream input;
        final long deadline;
        final byte[] scratch = new byte[8192];
        long at;
        Cursor(InputStream input, long deadline) { this.input = input; this.deadline = deadline; }
        void check(long count) throws IOException {
            if (count < 0 || count > MAX_BYTES - at) throw new Limit("too_large");
            if (System.nanoTime() > deadline) throw new Limit("expired");
        }
        int one(boolean eof) throws IOException {
            check(1);
            int value = input.read();
            if (value < 0) {
                if (eof) return -1;
                throw new IOException("truncated");
            }
            at++;
            return value;
        }
        long varint(long end) throws IOException {
            long value = 0;
            for (int i = 0; i < 10; i++) {
                if (at >= end) throw new IOException("truncated varint");
                int b = one(false);
                if (i == 9 && b > 1) throw new IOException("varint overflow");
                value |= (long)(b & 127) << (i * 7);
                if ((b & 128) == 0) return value;
            }
            throw new IOException("bad varint");
        }
        int tag(long end, boolean top) throws IOException {
            if (at == end) return 0;
            if (at > end) throw new IOException("message boundary");
            int b = one(top);
            if (b < 0) return 0;
            long value = b & 127;
            int i = 1;
            while ((b & 128) != 0) {
                if (i == 5 || at >= end) throw new IOException("bad tag");
                b = one(false); value |= (long)(b & 127) << (7 * i++);
            }
            if (value == 0 || value > 0xffffffffL || (value >>> 3) == 0) throw new IOException("bad tag");
            return (int)value;
        }
        long message(long parent) throws IOException {
            long length = varint(parent);
            check(length);
            if (length > parent - at) throw new IOException("message boundary");
            return at + length;
        }
        void to(long end) throws IOException {
            check(end - at);
            while (at < end) {
                check(end - at);
                // File streams may seek beyond EOF. Read/discard to verify the
                // declared bytes exist, while retaining no memory or log data.
                int n = input.read(scratch, 0, (int)Math.min(scratch.length, end - at));
                if (n < 0) throw new IOException("truncated skipped field");
                if (n == 0) one(false); else at += n;
            }
        }
        String text(long parent, int limit) throws IOException {
            long end = message(parent);
            int length = (int)(end - at);
            if (length > limit) { to(end); return ""; }
            byte[] data = new byte[length];
            int used = 0;
            while (used < length) {
                check(length - used);
                int n = input.read(data, used, length - used);
                if (n < 0) throw new IOException("truncated string");
                if (n == 0) { data[used++] = (byte)one(false); } else { used += n; at += n; }
            }
            return new String(data, StandardCharsets.UTF_8);
        }
        void skip(int tag, long end) throws IOException {
            switch (tag & 7) {
                case 0: varint(end); break;
                case 1: if (8 > end - at) throw new IOException("fixed64"); to(at + 8); break;
                case 2: to(message(end)); break;
                case 5: if (4 > end - at) throw new IOException("fixed32"); to(at + 4); break;
                default: throw new IOException("unsupported wire type");
            }
        }
    }

    private static final class Frames {
        long id;
        int count;
        final List<Map<String, Object>> values = new ArrayList<>();
    }

    static Map<String, Object> parse(InputStream input, String process) throws IOException {
        return parse(input, process, System.nanoTime() + 2_000_000_000L);
    }

    static Map<String, Object> parse(InputStream input, String process, long deadline) throws IOException {
        Cursor c = new Cursor(input, deadline);
        long end = MAX_BYTES + 1L, tid = 0;
        int arch = 0, signal = 0, threadCount = 0, commandCount = 0;
        boolean ownProcess = false, threadsTruncated = false;
        String abort = "other";
        Map<Long, Frames> threads = new HashMap<>();
        int tag;
        while ((tag = c.tag(end, true)) != 0) {
            if (tag == 8) arch = (int)c.varint(end);
            else if (tag == 48) tid = c.varint(end);
            else if (tag == 74) {
                if (commandCount++ == 0) ownProcess = process.equals(c.text(end, 128));
                else c.to(c.message(end));
            } else if (tag == 82) {
                long sub = c.message(end); int inner;
                while ((inner = c.tag(sub, false)) != 0) {
                    if (inner == 8) signal = (int)c.varint(sub); else c.skip(inner, sub);
                }
            } else if (tag == 114) abort = abortKind(c.text(end, 16384));
            else if (tag == 130) {
                long sub = c.message(end);
                if (threadCount++ >= MAX_THREADS) { threadsTruncated = true; c.to(sub); continue; }
                long key = 0; Frames frames = null; int inner;
                while ((inner = c.tag(sub, false)) != 0) {
                    if (inner == 8) key = c.varint(sub);
                    else if (inner == 18) frames = thread(c, c.message(sub));
                    else c.skip(inner, sub);
                }
                if (key > 0 && frames != null && frames.id == key) threads.put(key, frames);
            } else c.skip(tag, end);
        }
        Map<String, Object> result = new HashMap<>();
        Frames frames = threads.get(tid);
        if (!ownProcess) result.put("status", "wrong_process");
        else if (signal < 1 || signal > 127 || frames == null || frames.values.isEmpty()) result.put("status", "invalid");
        else {
            result.put("status", "available");
            result.put("arch", arch >= 0 && arch < ARCH.length ? ARCH[arch] : "unknown");
            result.put("signal", signal);
            result.put("abortKind", abort);
            result.put("frames", frames.values);
            result.put("framesTruncated", frames.count > MAX_FRAMES);
            result.put("threadsTruncated", threadsTruncated);
        }
        return result;
    }

    private static Frames thread(Cursor c, long end) throws IOException {
        Frames frames = new Frames(); int tag;
        while ((tag = c.tag(end, false)) != 0) {
            if (tag == 8) frames.id = c.varint(end);
            else if (tag == 34) {
                long sub = c.message(end); int index = frames.count++;
                if (index >= MAX_FRAMES) c.to(sub); else frames.values.add(frame(c, sub, index));
            } else c.skip(tag, end);
        }
        return frames;
    }

    private static Map<String, Object> frame(Cursor c, long end, int index) throws IOException {
        long pc = 0; String library = "unknown", build = ""; int tag;
        while ((tag = c.tag(end, false)) != 0) {
            if (tag == 8) pc = c.varint(end);
            else if (tag == 50) {
                String path = c.text(end, 4096);
                String name = path.substring(path.lastIndexOf('/') + 1);
                if (name.matches("lib[A-Za-z0-9_.+-]{1,90}\\.so(?:\\.[0-9]+)*")) library = name;
            } else if (tag == 66) {
                String value = c.text(end, 128);
                if (value.matches("[0-9a-fA-F]{16,128}")) build = value.toLowerCase(Locale.ROOT);
            } else c.skip(tag, end);
        }
        Map<String, Object> result = new HashMap<>();
        result.put("index", index); result.put("library", library);
        result.put("pc", Long.toUnsignedString(pc, 16)); result.put("buildId", build);
        return result;
    }

    private static String abortKind(String text) {
        String lower = text.toLowerCase(Locale.ROOT);
        if (lower.contains("assert")) return "assertion";
        if (lower.contains("double free")) return "double_free";
        if (lower.contains("scudo")) return "allocator";
        if (lower.contains("fdsan")) return "fd_sanitizer";
        if (lower.contains("fortify")) return "fortify";
        if (lower.contains("jni detected")) return "jni";
        if (lower.contains("out of memory")) return "allocation_failure";
        if (lower.contains("terminate") || lower.contains("libc++abi")) return "cpp_terminate";
        return "other";
    }
}
