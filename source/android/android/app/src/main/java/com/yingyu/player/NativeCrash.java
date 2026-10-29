package com.yingyu.player;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import io.flutter.plugin.common.MethodChannel;

/** One background read per process, of this package's latest native crash only. */
final class NativeCrash {
    private static final AtomicBoolean started = new AtomicBoolean();
    private static volatile Map<String, Object> cached;

    static void readAsync(Context context, MethodChannel.Result reply) {
        Map<String, Object> ready = cached;
        if (ready != null) { reply.success(ready); return; }
        if (!started.compareAndSet(false, true)) { reply.success(status("reading")); return; }
        Context app = context.getApplicationContext();
        Thread worker = new Thread(() -> {
            Map<String, Object> report;
            try { report = read(app); }
            catch (RuntimeException | LinkageError e) { report = status("unavailable"); }
            cached = report;
            Map<String, Object> result = report;
            new Handler(Looper.getMainLooper()).post(() -> {
                try { reply.success(result); }
                catch (RuntimeException ignored) { /* The old Flutter engine may have detached. */ }
            });
        }, "yingyu-crash-read");
        worker.setDaemon(true);
        try { worker.start(); }
        catch (RuntimeException e) { cached = status("unavailable"); reply.success(cached); }
    }

    static Map<String, Object> read(Context app) {
        if (Build.VERSION.SDK_INT < 31) return status("unsupported");
        ActivityManager manager = (ActivityManager)app.getSystemService(Context.ACTIVITY_SERVICE);
        if (manager == null) return status("unavailable");
        String name = app.getPackageName();
        for (ApplicationExitInfo info : manager.getHistoricalProcessExitReasons(name, 0, 8)) {
            if (!name.equals(info.getProcessName()) || info.getReason() != ApplicationExitInfo.REASON_CRASH_NATIVE) continue;
            Map<String, Object> result;
            try (InputStream input = info.getTraceInputStream()) {
                result = input == null ? status("unavailable") : NativeTombstone.parse(input, name);
                if ("available".equals(result.get("status")) && info.getStatus() > 0
                        && !Integer.valueOf(info.getStatus()).equals(result.get("signal"))) result = status("invalid");
            } catch (NativeTombstone.Limit e) { result = status(e.kind); }
            catch (IOException | RuntimeException e) { result = status("invalid"); }
            result.put("timestamp", info.getTimestamp());
            result.put("exitSignal", info.getStatus());
            return result;
        }
        return status("none");
    }

    private static Map<String, Object> status(String value) {
        Map<String, Object> result = new HashMap<>(); result.put("status", value); return result;
    }
}
