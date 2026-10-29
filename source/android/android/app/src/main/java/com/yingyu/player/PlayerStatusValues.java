package com.yingyu.player;

/** Pure value handling for the on-demand player status snapshot. */
final class PlayerStatusValues {
    static Integer batteryPercent(int level, int scale) {
        if (level < 0 || scale <= 0 || level > scale) return null;
        return (int)Math.round(level * 100.0 / scale);
    }

    // BatteryManager's documented status constants. Keep Android IO in the bridge.
    static Boolean charging(int status) {
        if (status == 2 || status == 5) return true;
        if (status == 3 || status == 4) return false;
        return null;
    }

    static String network(boolean active, boolean known, boolean vpn, boolean wifi,
                          boolean cellular, boolean ethernet, boolean bluetooth) {
        if (!active) return "disconnected";
        if (!known) return "unknown";
        if (vpn) return "vpn";
        if (wifi) return "wifi";
        if (cellular) return "cellular";
        if (ethernet) return "ethernet";
        if (bluetooth) return "bluetooth";
        return "connected";
    }

    static final class ReceiveRate {
        private long bytes = -1, at = -1;
        private final java.util.ArrayDeque<long[]> window = new java.util.ArrayDeque<>();

        void reset() { bytes = at = -1; window.clear(); }

        Double sample(long nextBytes, long elapsedMillis) {
            if (nextBytes < 0 || elapsedMillis < 0) { reset(); return null; }
            long previousBytes = bytes, previousAt = at;
            bytes = nextBytes;
            at = elapsedMillis;
            long elapsed = elapsedMillis - previousAt;
            if (previousBytes < 0 || previousAt < 0 || nextBytes < previousBytes
                    || elapsed <= 0 || elapsed > 5000) {
                window.clear();
                window.add(new long[]{nextBytes, elapsedMillis});
                return null;
            }
            window.add(new long[]{nextBytes, elapsedMillis});
            // A trailing ~3-second measured average absorbs burst download gaps.
            // Keep a boundary point and at most four snapshots. No invented floor
            // or indefinite last-positive hold: three idle seconds return zero.
            while (window.size() > 2) {
                var points = window.iterator();
                points.next();
                if (points.next()[1] > elapsedMillis - 3000 && window.size() <= 4) break;
                window.removeFirst();
            }
            long[] first = window.getFirst();
            return (nextBytes - first[0]) * 1000.0 / (elapsedMillis - first[1]);
        }
    }
}
