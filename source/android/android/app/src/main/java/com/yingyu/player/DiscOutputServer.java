package com.yingyu.player;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

/** A private loopback clip view. Media bytes never travel through a Flutter
 * method-channel response. The source still owns the serial JNI worker. */
final class DiscOutputServer implements AutoCloseable {
    interface Source {
        long size(String path, Request request) throws Exception;
        byte[] read(String path, long offset, int length, Request request) throws Exception;
        void cancel(Request request);
        void failed();
    }
    static final class Request {
        final Socket socket;
        final String path;
        volatile boolean cancelled;
        Request(Socket socket, String path) { this.socket = socket; this.path = path; }
    }
    private final Source source;
    private final String prefix;
    private final Set<String> clips;
    private final ServerSocket server;
    private final Thread acceptor;
    private final ExecutorService workers = new ThreadPoolExecutor(2, 2, 0L,
        TimeUnit.MILLISECONDS, new ArrayBlockingQueue<>(8), r -> {
            Thread t = new Thread(r, "yingyu-disc-output"); t.setDaemon(true); return t;
        });
    private final Set<Socket> sockets = ConcurrentHashMap.newKeySet();
    private final Set<Request> active = ConcurrentHashMap.newKeySet();
    private final Map<String, Long> lengths = new ConcurrentHashMap<>();
    private final ExecutorService parsers = new ThreadPoolExecutor(2, 2, 0L,
        TimeUnit.MILLISECONDS, new ArrayBlockingQueue<>(8), r -> {
            Thread t = new Thread(r, "yingyu-disc-headers"); t.setDaemon(true); return t;
        });
    private final AtomicLong bytes = new AtomicLong(), reads = new AtomicLong(),
        readNanos = new AtomicLong(), writeNanos = new AtomicLong(), requests = new AtomicLong();
    private volatile boolean closed, failed;

    DiscOutputServer(String id, Collection<String> allowed, Source source) throws IOException {
        if (id == null || !id.matches("[A-Za-z0-9_-]{1,128}") || allowed == null || allowed.isEmpty() || allowed.size() > 4096)
            throw new IOException("原盘输出会话无效");
        this.source = source; prefix = "/" + id + "/clip/";
        clips = new HashSet<>(allowed);
        for (String clip : clips) if (!clip.matches("[0-9]{5}")) throw new IOException("原盘输出片段无效");
        server = new ServerSocket();
        server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 8);
        acceptor = new Thread(this::accept, "yingyu-disc-listen");
        acceptor.setDaemon(true); acceptor.start();
    }
    String base() { return "http://127.0.0.1:" + server.getLocalPort() + prefix.substring(0, prefix.length() - 6); }
    Map<String, Object> status() {
        Map<String, Object> out = new HashMap<>();
        out.put("bytes", bytes.get()); out.put("reads", reads.get());
        out.put("readMs", readNanos.get() / 1_000_000); out.put("writeMs", writeNanos.get() / 1_000_000);
        out.put("requests", requests.get()); out.put("active", active.size()); out.put("failed", failed);
        return out;
    }
    private void accept() {
        while (!closed) {
            Socket socket = null;
            try {
                socket = server.accept(); socket.setSoTimeout(15_000); socket.setTcpNoDelay(true);
                sockets.add(socket); final Socket client = socket;
                parsers.execute(() -> serve(client));
            } catch (IOException | RejectedExecutionException error) {
                if (socket != null) { sockets.remove(socket); closeSocket(socket); }
                if (closed) break;
            }
        }
    }
    private static void closeSocket(Socket socket) { try { socket.close(); } catch (IOException ignored) {} }
    private void cancel(Request request) {
        request.cancelled = true;
        closeSocket(request.socket);
        source.cancel(request);
    }
    private static String line(InputStream input, int[] budget) throws IOException {
        ByteArrayOutputStream value = new ByteArrayOutputStream();
        int previous = -1;
        while (--budget[0] >= 0) {
            int b = input.read();
            if (b < 0) throw new EOFException();
            if (b == '\n') {
                if (previous != '\r') throw new IOException("Invalid HTTP line");
                byte[] text = value.toByteArray();
                return new String(text, 0, text.length - 1, StandardCharsets.US_ASCII);
            }
            if (b > 127 || (b < 32 && b != '\r' && b != '\t')) throw new IOException("Invalid HTTP header");
            value.write(b); previous = b;
        }
        throw new IOException("HTTP header too large");
    }
    static long[] range(String value, long size) {
        if (size <= 0) return null;
        if (value == null) return new long[]{0, size - 1};
        if (!value.matches("bytes=[0-9]*-[0-9]*")) return null;
        String[] pair = value.substring(6).split("-", -1);
        try {
            if (pair[0].isEmpty()) {
                long count = Long.parseLong(pair[1]);
                return count <= 0 ? null : new long[]{Math.max(0, size - count), size - 1};
            }
            long start = Long.parseLong(pair[0]), end = pair[1].isEmpty() ? size - 1 : Long.parseLong(pair[1]);
            return start >= size || end < start ? null : new long[]{start, Math.min(size - 1, end)};
        } catch (NumberFormatException error) { return null; }
    }
    private static void headers(OutputStream output, int status, long count, String range) throws IOException {
        String value = "HTTP/1.1 " + status + " " + (status == 206 ? "Partial Content" : status == 200 ? "OK" : "Error") + "\r\n"
            + "Connection: close\r\nAccept-Ranges: bytes\r\nContent-Type: video/mp2t\r\nContent-Length: " + count + "\r\n"
            + (range == null ? "" : "Content-Range: " + range + "\r\n") + "\r\n";
        output.write(value.getBytes(StandardCharsets.US_ASCII)); output.flush();
    }
    private void serve(Socket socket) {
        Request request = null;
        boolean submitted = false;
        try {
            InputStream input = new BufferedInputStream(socket.getInputStream(), 4096);
            OutputStream output = socket.getOutputStream();
            int[] budget = {16 * 1024};
            String[] first = line(input, budget).split(" ", -1);
            if (first.length != 3 || !(first[2].equals("HTTP/1.1") || first[2].equals("HTTP/1.0"))) {
                headers(output, 400, 0, null); return;
            }
            String method = first[0], target = first[1], wanted = null;
            boolean duplicate = false;
            while (true) {
                String field = line(input, budget); if (field.isEmpty()) break;
                int at = field.indexOf(':'); if (at <= 0) throw new IOException("Invalid header");
                if (field.substring(0, at).equalsIgnoreCase("Range")) {
                    duplicate |= wanted != null; wanted = field.substring(at + 1).trim();
                }
            }
            if (closed || !(method.equals("GET") || method.equals("HEAD")) ||
                !target.startsWith(prefix) || target.length() != prefix.length() + 10 || !target.endsWith(".m2ts") ||
                !clips.contains(target.substring(prefix.length(), prefix.length() + 5))) {
                headers(output, 404, 0, null); return;
            }
            if (duplicate) { headers(output, 400, 0, null); return; }
            String path = "BDMV/STREAM/" + target.substring(prefix.length());
            Long knownSize = lengths.get(path);
            if (knownSize != null && range(wanted, knownSize) == null) {
                headers(output, 416, 0, "bytes */" + knownSize); return;
            }
            request = new Request(socket, path);
            synchronized (active) {
                if (method.equals("GET")) for (Request old : active) if (old.path.equals(path)) cancel(old);
                active.add(request);
            }
            requests.incrementAndGet();
            final Request transfer = request;
            final String requested = wanted;
            workers.execute(() -> transfer(transfer, method, requested));
            submitted = true;
        } catch (Exception error) {
            try { headers(socket.getOutputStream(), 502, 0, null); } catch (IOException ignored) {}
        } finally {
            if (!submitted) {
                if (request != null) { active.remove(request); cancel(request); }
                sockets.remove(socket); closeSocket(socket);
            }
        }
    }
    private void transfer(Request request, String method, String wanted) {
        Socket socket = request.socket;
        boolean sent = false, reading = false;
        try {
            OutputStream output = socket.getOutputStream();
            if (closed || request.cancelled) return;
            if (failed) { headers(output, 502, 0, null); return; }
            reading = true;
            long size = source.size(request.path, request);
            reading = false;
            lengths.put(request.path, size);
            long[] span = range(wanted, size);
            if (span == null) { headers(output, 416, 0, "bytes */" + Math.max(0, size)); return; }
            headers(output, wanted == null ? 200 : 206, span[1] - span[0] + 1,
                wanted == null ? null : "bytes " + span[0] + "-" + span[1] + "/" + size);
            sent = true;
            if (method.equals("HEAD")) return;
            for (long offset = span[0]; offset <= span[1] && !closed && !request.cancelled;) {
                // Probes/seeks often need only a small prefix. Publish the first
                // fixed JNI read before fetching the remaining three; sustained
                // sequential output still uses 1 MiB batches afterwards.
                int batch = offset == span[0] ? 256 * 1024 : 1024 * 1024;
                int count = (int)Math.min(batch, span[1] - offset + 1);
                long began = System.nanoTime();
                reading = true;
                byte[] data;
                try { data = source.read(request.path, offset, count, request); }
                finally { readNanos.addAndGet(System.nanoTime() - began); }
                if (data == null || data.length != count) throw new EOFException("原盘片段提前结束");
                reading = false;
                if (closed || request.cancelled) break;
                began = System.nanoTime();
                output.write(data); output.flush();
                writeNanos.addAndGet(System.nanoTime() - began);
                reads.incrementAndGet(); bytes.addAndGet(data.length); offset += data.length;
            }
        } catch (Exception error) {
            // An abandoned output socket is a normal seek/probe. A source read
            // failure is terminal and must remain visible through the control plane.
            if (reading && !closed && !request.cancelled) {
                failed = true; source.failed();
            }
            if (!sent) try { headers(socket.getOutputStream(), 502, 0, null); } catch (IOException ignored) {}
        } finally {
            active.remove(request); cancel(request);
            sockets.remove(socket); closeSocket(socket);
        }
    }
    @Override public void close() {
        closed = true;
        try { server.close(); } catch (IOException ignored) {}
        for (Request request : active) cancel(request);
        for (Socket socket : sockets) closeSocket(socket);
        parsers.shutdownNow();
        workers.shutdownNow();
    }
}
