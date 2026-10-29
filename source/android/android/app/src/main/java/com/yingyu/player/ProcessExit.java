package com.yingyu.player;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.os.Build;
import java.util.HashMap;
import java.util.Map;

/** Read only the app's latest main-process exit. No trace, description or PII. */
final class ProcessExit {
    static Map<String, Object> read(Context context) {
        Map<String, Object> result = new HashMap<>();
        result.put("supported", Build.VERSION.SDK_INT >= 30);
        if (Build.VERSION.SDK_INT < 30) return result;
        ActivityManager manager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        if (manager == null) return result;
        for (ApplicationExitInfo info : manager.getHistoricalProcessExitReasons(context.getPackageName(), 0, 8)) {
            if (!context.getPackageName().equals(info.getProcessName())) continue;
            result.put("timestamp", info.getTimestamp());
            result.put("reason", info.getReason());
            result.put("status", info.getStatus());
            result.put("pssKb", info.getPss());
            break;
        }
        return result;
    }
}
