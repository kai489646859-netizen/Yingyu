package com.yingyu.player;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Handler;
import android.os.Looper;
import java.util.HashMap;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.EventChannel;

/** Event-driven, player-page scoped default route observation. No network IO. */
final class PlaybackNetworkBridge implements EventChannel.StreamHandler {
    private final ConnectivityManager manager;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final EventChannel channel;
    private ConnectivityManager.NetworkCallback callback;
    private EventChannel.EventSink sink;
    private Network current;
    private NetworkCapabilities capabilities;
    private long route;
    private boolean blocked;

    PlaybackNetworkBridge(Context context, FlutterEngine engine) {
        manager = (ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE);
        channel = new EventChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/playback-network");
        channel.setStreamHandler(this);
    }
    @Override public void onListen(Object args, EventChannel.EventSink events) {
        stop();
        sink = events;
        ConnectivityManager.NetworkCallback next = new ConnectivityManager.NetworkCallback() {
            private boolean active() { return callback == this; }
            @Override public void onAvailable(Network network) {
                if (!active()) return;
                if (!network.equals(current)) { current = network; route++; }
                capabilities = null;
                blocked = false;
                // Android 8+ supplies capabilities next; no racy synchronous query.
            }
            @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) {
                if (!active() || !network.equals(current)) return;
                capabilities = caps;
                emit();
            }
            @Override public void onBlockedStatusChanged(Network network, boolean value) {
                if (!active() || !network.equals(current)) return;
                blocked = value;
                emit();
            }
            @Override public void onLost(Network network) {
                if (!active() || !network.equals(current)) return;
                current = null; capabilities = null; route++;
                emit();
            }
        };
        callback = next;
        try {
            manager.registerDefaultNetworkCallback(next, main);
            if (manager.getActiveNetwork() == null) emit();
        } catch (RuntimeException error) {
            stop();
            events.error("network_observation", "暂时无法监听网络切换", null);
        }
    }
    private void emit() {
        if (sink == null) return;
        HashMap<String, Object> state = new HashMap<>();
        state.put("route", route);
        state.put("available", current != null && capabilities != null && !blocked);
        String kind = "unknown";
        if (capabilities != null) {
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) kind = "mobile";
            else if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) kind = "wifi";
            else if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) kind = "metered";
            else kind = "other";
        }
        state.put("kind", kind);
        sink.success(state);
    }
    @Override public void onCancel(Object args) { stop(); }
    private void stop() {
        ConnectivityManager.NetworkCallback old = callback;
        callback = null; sink = null; current = null; capabilities = null;
        if (old != null) {
            try { manager.unregisterNetworkCallback(old); } catch (RuntimeException ignored) {}
        }
    }
    void close() { stop(); channel.setStreamHandler(null); }
}
