package com.yingyu.player;

import android.app.Activity;
import android.content.Context;
import android.hardware.display.DisplayManager;
import android.graphics.PixelFormat;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;

/** Local capability snapshots and a separate opt-in HDR SurfaceView. No player,
 * focus request, media query, system setting or Java global reference is made. */
final class NativeHdrBridge {
    private final Activity activity;
    private final MethodChannel channel;
    private final DisplayManager displays;
    private final HashSet<Long> watchers = new HashSet<>();
    private final HashMap<Integer, HdrView> views = new HashMap<>();
    private volatile boolean closed;
    private final AtomicBoolean probing = new AtomicBoolean();
    private final ExecutorService probes = Executors.newSingleThreadExecutor(task -> {
        Thread worker = new Thread(task, "yingyu-hdr-window");
        worker.setDaemon(true); return worker;
    });
    private final DisplayManager.DisplayListener listener = new DisplayManager.DisplayListener() {
        @Override public void onDisplayAdded(int id) { changed("display"); }
        @Override public void onDisplayRemoved(int id) { changed("display"); }
        @Override public void onDisplayChanged(int id) { changed("display"); }
    };
    NativeHdrBridge(Activity activity, FlutterEngine engine) {
        this.activity = activity;
        displays = (DisplayManager)activity.getSystemService(Context.DISPLAY_SERVICE);
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/native_hdr");
        channel.setMethodCallHandler((call, result) -> {
            if (closed) { result.success(null); return; }
            if (call.method.equals("capabilities")) {
                result.success(snapshot(activity.getWindow().getDecorView())); return;
            }
            Number owner = call.argument("owner");
            if (owner == null || owner.longValue() <= 0) {
                result.error("output", "缺少播放输出标识", null); return;
            }
            if (call.method.equals("watch")) {
                if (watchers.isEmpty()) displays.registerDisplayListener(listener, new Handler(Looper.getMainLooper()));
                watchers.add(owner.longValue()); result.success(snapshot(activity.getWindow().getDecorView()));
            } else if (call.method.equals("probe")) {
                Number token = call.argument("token");
                String transfer = call.argument("transfer");
                HdrView selected = null;
                for (HdrView view : views.values())
                    if (!view.disposed && view.owner == owner.longValue() &&
                            token != null && token.longValue() > 0 && view.token == token.longValue()) selected = view;
                if (selected == null || !watchers.contains(owner.longValue()) ||
                        !("pq".equals(transfer) || "hlg".equals(transfer))) {
                    result.success(probeResult("surface-unavailable")); return;
                }
                if (!probing.compareAndSet(false, true)) {
                    result.success(probeResult("probe-busy")); return;
                }
                final HdrView target = selected;
                final long expectedToken = token.longValue();
                final Surface surface = target.view.getHolder().getSurface();
                probes.execute(() -> {
                    String status;
                    try {
                        status = closed || target.disposed || target.token != expectedToken
                                ? "surface-unavailable" : HdrSurfaceProbe.inspect(surface, transfer,
                                    () -> checkDataSpace(expectedToken, "pq".equals(transfer) ? 1 : 2));
                    } catch (RuntimeException | LinkageError error) { status = "egl-exception"; }
                    finally { probing.set(false); }
                    final String outcome = status;
                    new Handler(Looper.getMainLooper()).post(() -> {
                        if (!closed) result.success(probeResult(target.disposed ||
                                target.token != expectedToken ? "surface-unavailable" : outcome));
                    });
                });
            } else if (call.method.equals("stop")) {
                watchers.remove(owner.longValue());
                // The Dart output transaction has detached first. Release
                // registry ownership now, even if Flutter disposal is late.
                for (HdrView view : new ArrayList<>(views.values()))
                    if (view.owner == owner.longValue()) view.dispose();
                if (watchers.isEmpty()) displays.unregisterDisplayListener(listener);
                result.success(null);
            } else result.notImplemented();
        });
        engine.getPlatformViewsController().getRegistry().registerViewFactory(
            "yingyu/native_hdr_surface", new PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                @Override public PlatformView create(Context context, int id, Object arguments) {
                    if (closed || !(arguments instanceof Map)) throw new IllegalStateException("HDR view unavailable");
                    Object value = ((Map<?, ?>)arguments).get("owner");
                    if (!(value instanceof Number) || ((Number)value).longValue() <= 0)
                        throw new IllegalArgumentException("Invalid HDR owner");
                    HdrView view = new HdrView(context, id, ((Number)value).longValue());
                    views.put(id, view); return view;
                }
            });
    }
    private static HashMap<String,Object> probeResult(String status) {
        HashMap<String,Object> result = new HashMap<>(); result.put("status",status); return result;
    }
    void changed(String kind) {
        if (closed || watchers.isEmpty()) return;
        HashMap<String,Object> value = snapshot(activity.getWindow().getDecorView());
        value.put("kind", kind);
        for (Long owner : new ArrayList<>(watchers)) {
            HashMap<String,Object> event = new HashMap<>(value); event.put("owner", owner);
            channel.invokeMethod("changed", event);
        }
    }
    @SuppressWarnings("deprecation")
    private HashMap<String,Object> snapshot(View view) {
        HashMap<String,Object> result = new HashMap<>();
        result.put("sdk", Build.VERSION.SDK_INT);
        Display display = view.getDisplay();
        ArrayList<Integer> hdr = new ArrayList<>();
        if (display != null) {
            result.put("display", display.getDisplayId());
            result.put("mode", display.getMode().getModeId());
            int[] types = Build.VERSION.SDK_INT >= 34 ? display.getMode().getSupportedHdrTypes()
                                                      : display.getHdrCapabilities().getSupportedHdrTypes();
            if (display.isHdr()) for (int type : types) if (!hdr.contains(type)) hdr.add(type);
        }
        // A declared desired peak is a mapping hint, not a measured/calibrated
        // screen brightness. Invalid/unknown values stay absent (native auto).
        if (display != null && hdr.contains(2)) {
            float peak = display.getHdrCapabilities().getDesiredMaxLuminance();
            if (Float.isFinite(peak) && peak >= 80 && peak <= 10000)
                result.put("hdrMaxLuminance", (double)peak);
        }
        result.put("hdrTypes", hdr);
        // These are the system's anticipated media routes, not this AO's
        // routed-device/clock. Names, addresses and IDs never leave Java.
        ArrayList<Integer> routes = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                AudioManager audio = (AudioManager)activity.getSystemService(Context.AUDIO_SERVICE);
                AudioAttributes attributes = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build();
                for (AudioDeviceInfo device : audio.getAudioDevicesForAttributes(attributes))
                    if (device.isSink() && !routes.contains(device.getType())) routes.add(device.getType());
            } catch (RuntimeException ignored) { /* Unknown remains unknown. */ }
        }
        result.put("anticipatedAudioTypes", routes);
        return result;
    }
    void close() {
        if (closed) return;
        closed = true;
        probes.shutdown();
        displays.unregisterDisplayListener(listener); watchers.clear();
        for (HdrView view : new ArrayList<>(views.values())) view.dispose();
        views.clear(); channel.setMethodCallHandler(null);
    }
    // Loaded only on creation of the optional HDR view, never for Dolby/SDR.
    private static void loadNative() { System.loadLibrary("mpv"); }
    private static native long registerSurface(Surface surface);
    private static native void unregisterSurface(long token);
    private static native int checkDataSpace(long token, int transfer);

    private final class HdrView implements PlatformView, SurfaceHolder.Callback {
        final SurfaceView view;
        final int id;
        final long owner;
        volatile long token;
        private long retiredToken;
        volatile boolean disposed;
        HdrView(Context context, int id, long owner) {
            this.id = id; this.owner = owner;
            view = new SurfaceView(context);
            view.setFocusable(false); view.setClickable(false);
            view.getHolder().setFormat(PixelFormat.RGBA_1010102);
            view.getHolder().addCallback(this);
        }
        @Override public View getView() { return view; }
        private void notifySurface() {
            if (closed) return;
            HashMap<String,Object> event = snapshot(view);
            event.put("owner", owner); event.put("token", token);
            if (token == 0 && retiredToken > 0) event.put("retiredToken", retiredToken);
            event.put("width", view.getWidth()); event.put("height", view.getHeight());
            channel.invokeMethod("surface", event);
        }
        @Override public void surfaceCreated(SurfaceHolder holder) {
            if (disposed) return;
            try { loadNative(); token = registerSurface(holder.getSurface()); }
            catch (LinkageError | RuntimeException ignored) { token = 0; }
            notifySurface();
        }
        @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
            if (!disposed) notifySurface();
        }
        @Override public void surfaceDestroyed(SurfaceHolder holder) { release(); notifySurface(); }
        private void release() {
            if (token == 0) return;
            retiredToken = token;
            unregisterSurface(token); token = 0;
        }
        @Override public void dispose() {
            if (disposed) return;
            disposed = true;
            // Hide the platform layer immediately. Flutter owns its parent
            // and will remove it; a failed renderer must not cover that route.
            view.setVisibility(View.GONE);
            release(); view.getHolder().removeCallback(this);
            notifySurface(); views.remove(id);
        }
    }
}
