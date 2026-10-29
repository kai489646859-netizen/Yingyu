package com.yingyu.player;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Debug;
import android.os.PowerManager;
import android.os.Process;
import android.os.SystemClock;
import java.util.HashMap;

/** On-demand counters only: no receiver, thread, polling service or media reads. */
final class ResourceDiagnostics {
    static HashMap<String, Object> sample(Context context) {
        HashMap<String, Object> v = new HashMap<>();
        v.put("elapsedMs", SystemClock.elapsedRealtime());
        v.put("cpuMs", Process.getElapsedCpuTime());
        Runtime r = Runtime.getRuntime();
        v.put("javaHeapBytes", r.totalMemory() - r.freeMemory());
        v.put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize());
        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        if (power != null) {
            v.put("powerSave", power.isPowerSaveMode() ? 1 : 0);
            if (Build.VERSION.SDK_INT >= 29) v.put("thermal", power.getCurrentThermalStatus());
        }
        Intent battery = context.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        if (battery != null) {
            int level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
            if (level >= 0 && scale > 0) v.put("batteryPercent", 100.0 * level / scale);
            int temp = battery.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Integer.MIN_VALUE);
            if (temp != Integer.MIN_VALUE) v.put("batteryTempC", temp / 10.0);
            v.put("plugged", battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1));
        }
        return v;
    }
}
