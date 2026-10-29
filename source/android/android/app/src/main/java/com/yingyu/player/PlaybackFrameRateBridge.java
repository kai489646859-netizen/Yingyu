package com.yingyu.player;

import android.view.Display;
import android.view.Window;
import android.view.WindowManager;
import android.os.Build;
import java.util.HashMap;
import java.util.ArrayList;

final class PlaybackFrameRateBridge {
    private final PlaybackFrameRate policy;
    PlaybackFrameRateBridge(Window window) {
        policy = new PlaybackFrameRate(new PlaybackFrameRate.Port() {
            Display display() { return window.getDecorView().getDisplay(); }
            PlaybackFrameRate.Mode convert(Display.Mode mode) {
                return new PlaybackFrameRate.Mode(mode.getModeId(), mode.getPhysicalWidth(),
                        mode.getPhysicalHeight(), mode.getRefreshRate());
            }
            public PlaybackFrameRate.Mode current() {
                Display d = display(); return d == null ? null : convert(d.getMode());
            }
            public PlaybackFrameRate.Mode[] modes() {
                Display d = display(); if (d == null) return new PlaybackFrameRate.Mode[0];
                Display.Mode mode = d.getMode();
                PlaybackFrameRate.Mode current = convert(mode);
                float[] alternatives = Build.VERSION.SDK_INT >= 31 ? mode.getAlternativeRefreshRates() : new float[0];
                ArrayList<PlaybackFrameRate.Mode> result = new ArrayList<>();
                for (Display.Mode source : d.getSupportedModes()) {
                    PlaybackFrameRate.Mode candidate = convert(source);
                    boolean hdr = Build.VERSION.SDK_INT < 34 || PlaybackFrameRate.preservesHdr(
                            mode.getSupportedHdrTypes(), source.getSupportedHdrTypes());
                    if (hdr && PlaybackFrameRate.seamless(current, candidate, alternatives)) result.add(candidate);
                }
                return result.toArray(new PlaybackFrameRate.Mode[0]);
            }
            public int preferredMode() { return window.getAttributes().preferredDisplayModeId; }
            public float preferredRate() { return window.getAttributes().preferredRefreshRate; }
            public void prefer(int mode, float rate) {
                WindowManager.LayoutParams value = window.getAttributes();
                value.preferredDisplayModeId = mode; value.preferredRefreshRate = rate;
                window.setAttributes(value);
            }
        });
    }
    HashMap<String, Object> update(long owner, double fps, double speed, boolean active, boolean retire) {
        HashMap<String, Object> result = new HashMap<>();
        try {
            if (retire) { policy.release(owner, true); result.put("status", "retired"); }
            else result.put("status", policy.update(owner, fps, speed, active));
        } catch (RuntimeException failure) {
            try { policy.release(owner, false); } catch (RuntimeException ignored) { }
            result.put("status", "unavailable");
        }
        result.put("requestedHz", policy.requestedHz());
        com.alexmercerind.media_kit_video.VideoOutput.setPlaybackRate((float)policy.sourceRate());
        return result;
    }
    void foreground(boolean active) {
        try {
            policy.foreground(active);
            com.alexmercerind.media_kit_video.VideoOutput.setPlaybackRate((float)policy.sourceRate());
        } catch (RuntimeException ignored) { }
    }
    void close() { try {
        policy.close();
        com.alexmercerind.media_kit_video.VideoOutput.setPlaybackRate(0);
    } catch (RuntimeException ignored) { } }
}
