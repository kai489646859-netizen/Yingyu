package com.yingyu.player;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Fixed memory, explicit size ceiling; streams are closed by their owner. */
final class SubtitleCopy {
    static final long MAX = 64L * 1024 * 1024;
    static long copy(InputStream in, OutputStream out, long limit) throws IOException {
        byte[] buffer = new byte[32768];
        long total = 0;
        int count;
        while ((count = in.read(buffer)) != -1) {
            if (Thread.currentThread().isInterrupted()) throw new IOException("Cancelled");
            if (count == 0) throw new IOException("Empty read");
            total += count;
            if (total > limit) throw new IOException("Size limit");
            out.write(buffer, 0, count);
        }
        if (total == 0) throw new IOException("Empty subtitle");
        out.flush();
        return total;
    }
}
