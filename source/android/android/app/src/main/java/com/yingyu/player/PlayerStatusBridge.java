package com.yingyu.player;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.TrafficStats;
import android.os.BatteryManager;
import android.os.Process;
import android.os.SystemClock;
import java.util.HashMap;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** One local snapshot per visible-player request; no receiver, timer or network IO. */
final class PlayerStatusBridge {
    private final Context context;
    private final MethodChannel channel;
    private final PlayerStatusValues.ReceiveRate receive = new PlayerStatusValues.ReceiveRate();
    private String previousNetwork;

    PlayerStatusBridge(Context context, FlutterEngine engine) {
        this.context = context.getApplicationContext();
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/player-status");
        channel.setMethodCallHandler((call, result) -> {
            if (call.method.equals("reset")) { reset(); result.success(null); }
            else if (call.method.equals("sample")) result.success(sample());
            else if (call.method.equals("rate")) result.success(rate());
            else result.notImplemented();
        });
    }

    private HashMap<String, Object> sample() {
        HashMap<String, Object> values = rate();
        /* Visible-only connection and battery details remain below. */
        String network = "unknown";
        try {
            ConnectivityManager manager = (ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (manager != null) {
                Network active = manager.getActiveNetwork();
                NetworkCapabilities caps = active == null ? null : manager.getNetworkCapabilities(active);
                network = PlayerStatusValues.network(active != null, caps != null,
                    caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
                    caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
                    caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
                    caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),
                    caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH));
            }
        } catch (RuntimeException unavailable) { /* Unknown is not disconnected. */ }
        if (previousNetwork != null && !previousNetwork.equals(network)) {
            receive.reset();
            values.put("rxBytesPerSecond", null);
        }
        previousNetwork = network;
        values.put("network", network);
        Integer battery = null;
        Boolean charging = null;
        try {
            Intent intent = context.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (intent != null) {
                battery = PlayerStatusValues.batteryPercent(
                    intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1),
                    intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1));
                charging = PlayerStatusValues.charging(intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1));
            }
        } catch (RuntimeException unavailable) { /* Retain null. */ }
        values.put("batteryPercent", battery);
        values.put("charging", charging);
        return values;
    }

    private HashMap<String, Object> rate() {
        HashMap<String, Object> values = new HashMap<>();
        values.put("wallTimeMs", System.currentTimeMillis());
        try {
            values.put("rxBytesPerSecond", receive.sample(
                TrafficStats.getUidRxBytes(Process.myUid()), SystemClock.elapsedRealtime()));
        } catch (RuntimeException unavailable) {
            receive.reset();
            values.put("rxBytesPerSecond", null);
        }
        return values;
    }

    void reset() { receive.reset(); previousNetwork = null; }
    void destroy() { channel.setMethodCallHandler(null); reset(); }
}
