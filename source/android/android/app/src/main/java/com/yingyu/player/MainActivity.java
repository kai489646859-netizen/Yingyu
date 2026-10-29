package com.yingyu.player;

import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.os.Bundle;
import android.content.res.Configuration;
import android.util.DisplayMetrics;
import android.provider.Settings;
import android.view.WindowManager;
import android.view.Display;
import androidx.annotation.NonNull;
import java.util.HashMap;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** Android device integration uses AudioManager's documented focus and route APIs. */
public class MainActivity extends FlutterActivity {
    private AudioManager audio;
    private PlaybackAudioFocus playbackFocus;
    private MethodChannel channel;
    private boolean watching;
    private Float brightnessBeforeGesture;
    private DiscBridge discBridge;
    private LogExportBridge logExport;
    private SubtitleImportBridge subtitleImport;
    private TranslationBridge translation;
    private PlayerStatusBridge playerStatus;
    private PlaybackFrameRateBridge frameRate;
    private NativeHdrBridge nativeHdr;
    private MethodChannel orientationChannel;
    private final OrientationController orientation = new OrientationController();
    private Integer rotationAnimationBeforeExit;
    private Long rotationExitOwner;
    private boolean phoneDisplay() {
        DisplayMetrics metrics = new DisplayMetrics();
        getWindowManager().getDefaultDisplay().getRealMetrics(metrics);
        float shortest = Math.min(metrics.widthPixels, metrics.heightPixels) / metrics.density;
        return shortest > 0 && shortest < 600;
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        applyOrientation();
    }
    @SuppressWarnings("deprecation")
    private void applyOrientation() {
        DisplayMetrics metrics = new DisplayMetrics();
        // Full display metrics avoid classifying a landscape phone or split-screen tablet by window width.
        getWindowManager().getDefaultDisplay().getRealMetrics(metrics);
        float shortest = Math.min(metrics.widthPixels, metrics.heightPixels) / metrics.density;
        int requested = orientation.requested(shortest);
        if (getRequestedOrientation() != requested) setRequestedOrientation(requested);
    }
    @Override public void onConfigurationChanged(@NonNull Configuration config) {
        super.onConfigurationChanged(config);
        applyOrientation();
    }
    private final BroadcastReceiver noisy = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { interrupt("耳机已断开"); }
    };
    private final AudioDeviceCallback devices = new AudioDeviceCallback() {
        @Override public void onAudioDevicesAdded(AudioDeviceInfo[] added) {
            if (nativeHdr != null) nativeHdr.changed("audio");
        }
        @Override public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) {
            if (nativeHdr != null) nativeHdr.changed("audio");
            for (AudioDeviceInfo device : removed) {
                if (device.isSink()) { interrupt("音频输出设备已断开"); return; }
            }
        }
    };
    private void interrupt(String reason) {
        if (watching && channel != null) runOnUiThread(() -> channel.invokeMethod("interruption", reason));
    }
    @Override public void configureFlutterEngine(@NonNull FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        orientationChannel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/orientation");
        orientationChannel.setMethodCallHandler((call, result) -> {
            if (call.method.equals("finishExit")) {
                Number finishingOwner = call.argument("owner");
                if (rotationAnimationBeforeExit != null && !orientation.hasPlayers()
                        && finishingOwner != null && rotationExitOwner != null
                        && finishingOwner.longValue() == rotationExitOwner.longValue()) {
                    WindowManager.LayoutParams attributes = getWindow().getAttributes();
                    attributes.rotationAnimation = rotationAnimationBeforeExit;
                    getWindow().setAttributes(attributes);
                    rotationAnimationBeforeExit = null;
                    rotationExitOwner = null;
                }
                result.success(null);
                return;
            }
            if (!call.method.equals("player")) { result.notImplemented(); return; }
            Number owner = call.argument("owner");
            Boolean active = call.argument("active");
            if (owner == null || active == null) { result.error("orientation", "缺少播放页面标识", null); return; }
            try {
                orientation.update(owner.longValue(), active);
                // Only the release transition: retain each device's direction
                // policy, but do not animate a landscape browser underneath it.
                if (!active && !orientation.hasPlayers()) {
                    WindowManager.LayoutParams attributes = getWindow().getAttributes();
                    if (rotationAnimationBeforeExit == null) rotationAnimationBeforeExit = attributes.rotationAnimation;
                    rotationExitOwner = owner.longValue();
                    attributes.rotationAnimation = WindowManager.LayoutParams.ROTATION_ANIMATION_JUMPCUT;
                    getWindow().setAttributes(attributes);
                } else if (active && rotationAnimationBeforeExit != null) {
                    WindowManager.LayoutParams attributes = getWindow().getAttributes();
                    attributes.rotationAnimation = rotationAnimationBeforeExit;
                    getWindow().setAttributes(attributes);
                    rotationAnimationBeforeExit = null;
                    rotationExitOwner = null;
                }
                applyOrientation();
                HashMap<String, Object> policy = new HashMap<>();
                policy.put("phone", phoneDisplay());
                result.success(policy);
            } catch (RuntimeException error) { result.error("orientation", "屏幕方向设置失败", null); }
        });
        translation = new TranslationBridge(this, engine);
        playerStatus = new PlayerStatusBridge(this, engine);
        frameRate = new PlaybackFrameRateBridge(getWindow());
        nativeHdr = new NativeHdrBridge(this, engine);
        discBridge = new DiscBridge(engine);
        logExport = new LogExportBridge(this, engine);
        subtitleImport = new SubtitleImportBridge(this, engine);
        audio = (AudioManager) getSystemService(AUDIO_SERVICE);
        playbackFocus = new PlaybackAudioFocus(audio, kind -> {
            if (watching && channel != null) channel.invokeMethod("audioFocus", kind);
        });
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/device");
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "previousExit": result.success(ProcessExit.read(this)); break;
                    case "anrTrace": AnrTrace.readAsync(getApplicationContext(), result); break;
                    case "nativeCrashTrace": NativeCrash.readAsync(getApplicationContext(), result); break;
                    case "playbackRate": {
                        Number owner = call.argument("owner");
                        Number fps = call.argument("fps"), speed = call.argument("speed");
                        boolean active = watching && Boolean.TRUE.equals(call.argument("active"));
                        result.success(frameRate.update(owner == null ? 0 : owner.longValue(),
                                fps == null ? 0 : fps.doubleValue(), speed == null ? 1 : speed.doubleValue(),
                                active, Boolean.TRUE.equals(call.argument("retire"))));
                        break;
                    }
                    case "displayRates": {
                        // Read-only values: the app's refresh rate can differ
                        // from the physical mode under Android frame-rate overrides.
                        HashMap<String, Object> rates = new HashMap<>();
                        Display display = getWindow().getDecorView().getDisplay();
                        if (display != null) {
                            Display.Mode mode = display.getMode();
                            rates.put("appHz", (double)display.getRefreshRate());
                            rates.put("modeHz", (double)mode.getRefreshRate());
                            float maximum = mode.getRefreshRate();
                            for (Display.Mode supported : display.getSupportedModes()) {
                                if (supported.getPhysicalWidth() == mode.getPhysicalWidth()
                                        && supported.getPhysicalHeight() == mode.getPhysicalHeight()) {
                                    maximum = Math.max(maximum, supported.getRefreshRate());
                                }
                            }
                            rates.put("maximumHz", (double)maximum);
                        }
                        result.success(rates); break;
                    }
                    case "playbackNetwork": {
                        ConnectivityManager connectivity = (ConnectivityManager)getSystemService(CONNECTIVITY_SERVICE);
                        Network active = connectivity.getActiveNetwork();
                        NetworkCapabilities capabilities = active == null ? null : connectivity.getNetworkCapabilities(active);
                        String state = capabilities == null ? "unknown"
                            : capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ? "mobile"
                            : !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ? "metered"
                            : "unmetered";
                        // Inspect only the active route, never a SIM or a Wi-Fi
                        // icon. VPNs that may use metered data require consent.
                        result.success(state); break;
                    }
                    case "resourceDiagnostics":
                        result.success(ResourceDiagnostics.sample(this)); break;
                    case "memory": {
                        ActivityManager.MemoryInfo info = new ActivityManager.MemoryInfo();
                        ((ActivityManager)getSystemService(ACTIVITY_SERVICE)).getMemoryInfo(info);
                        HashMap<String, Object> values = new HashMap<>();
                        values.put("total", info.totalMem); values.put("available", info.availMem);
                        result.success(values); break;
                    }
                    case "focus":
                        watching = true;
                        result.success(playbackFocus.acquire()); break;
                    case "release":
                        watching = false;
                        if (frameRate != null) frameRate.close();
                        playbackFocus.release();
                        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                        // A video that never changed window brightness must not
                        // issue a brightness override/reset while leaving.
                        if (brightnessBeforeGesture != null) {
                            setBrightness(brightnessBeforeGesture);
                            brightnessBeforeGesture = null;
                        }
                        result.success(null); break;
                    case "awake":
                        if (Boolean.TRUE.equals(call.arguments)) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                        result.success(null); break;
                    case "levels": {
                        HashMap<String, Object> levels = new HashMap<>();
                        levels.put("volume", (double)audio.getStreamVolume(AudioManager.STREAM_MUSIC) / Math.max(1, audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)));
                        float brightness = getWindow().getAttributes().screenBrightness;
                        int systemBrightness = Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, 128);
                        levels.put("windowBrightness", (double)brightness);
                        levels.put("systemBrightness", systemBrightness);
                        levels.put("automaticBrightness", Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS_MODE, 0) == Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC);
                        if (brightness < 0) brightness = systemBrightness / 255f;
                        levels.put("brightness", (double)brightness);
                        result.success(levels); break;
                    }
                    case "brightness":
                        if (brightnessBeforeGesture == null) brightnessBeforeGesture = getWindow().getAttributes().screenBrightness;
                        setBrightness(((Number)call.arguments).floatValue()); result.success(null); break;
                    case "volume":
                        double value = Math.max(0, Math.min(1, ((Number)call.arguments).doubleValue()));
                        audio.setStreamVolume(AudioManager.STREAM_MUSIC, (int)Math.round(value * audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)), 0);
                        result.success(null); break;
                    default: result.notImplemented();
                }
            } catch (Exception exception) { result.error("device", "设备操作失败", null); }
        });
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(noisy, new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY));
        audio.registerAudioDeviceCallback(devices, null);
    }
    private void setBrightness(float value) {
        WindowManager.LayoutParams attributes = getWindow().getAttributes();
        attributes.screenBrightness = value < 0 ? -1 : Math.max(0.02f, Math.min(1f, value));
        getWindow().setAttributes(attributes);
    }
    @Override protected void onResume() {
        super.onResume();
        if (frameRate != null) frameRate.foreground(true);
    }
    @Override protected void onPause() {
        if (frameRate != null) frameRate.foreground(false);
        if (playerStatus != null) playerStatus.reset();
        interrupt("已暂停"); super.onPause();
    }
    @Override public void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == LogExportBridge.REQUEST && logExport != null) logExport.result(result, data);
        if (request == SubtitleImportBridge.REQUEST && subtitleImport != null) subtitleImport.result(result, data);
    }
    @Override protected void onDestroy() {
        if (frameRate != null) frameRate.close();
        if (orientationChannel != null) { orientationChannel.setMethodCallHandler(null); orientationChannel = null; }
        if (translation != null) translation.destroy();
        if (playerStatus != null) playerStatus.destroy();
        if (nativeHdr != null) nativeHdr.close();
        if (logExport != null) logExport.destroy();
        if (subtitleImport != null) subtitleImport.destroy();
        if (discBridge != null) discBridge.destroy();
        if (audio != null) { playbackFocus.release(); audio.unregisterAudioDeviceCallback(devices); }
        if (channel != null) { unregisterReceiver(noisy); channel.setMethodCallHandler(null); channel = null; }
        super.onDestroy();
    }
}
