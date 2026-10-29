package com.yingyu.player;

/** Scoped display scheduling hint. Does not change media clocks or pixel formats. */
final class PlaybackFrameRate {
    static final class Mode {
        final int id, width, height;
        final double hz;
        Mode(int id, int width, int height, double hz) {
            this.id = id; this.width = width; this.height = height; this.hz = hz;
        }
    }
    interface Port {
        Mode current();
        Mode[] modes();
        int preferredMode();
        float preferredRate();
        void prefer(int mode, float rate);
    }
    private final Port port;
    private long owner, retired;
    private boolean foreground = true, saved;
    private int previousMode, appliedMode;
    private float previousRate, appliedRate;
    private double demand;
    PlaybackFrameRate(Port port) { this.port = port; }

    static boolean seamless(Mode current, Mode candidate, float[] alternatives) {
        if (current == null || candidate == null || current.width != candidate.width ||
                current.height != candidate.height) return false;
        if (current.id == candidate.id) return true;
        for (float hz : alternatives) if (Math.abs(candidate.hz - hz) < .01) return true;
        return false;
    }
    static boolean preservesHdr(int[] current, int[] candidate) {
        for (int required : current) {
            boolean found = false;
            for (int supplied : candidate) if (required == supplied) found = true;
            if (!found) return false;
        }
        return true;
    }
    double requestedHz() { return saved ? appliedRate : 0; }
    double sourceRate() { return saved && foreground ? demand : 0; }

    // Prefer an integer number of display refreshes per source frame, and the
    // lower rate among equally suitable modes. Never change physical dimensions.
    static Mode choose(Mode current, Mode[] modes, double demand) {
        if (current == null || !Double.isFinite(demand) || demand <= 0) return null;
        Mode best = null, highest = null;
        double score = Double.POSITIVE_INFINITY;
        for (Mode mode : modes) {
            if (mode == null || mode.id <= 0 || mode.width != current.width ||
                    mode.height != current.height || !Double.isFinite(mode.hz) || mode.hz <= 0) continue;
            if (highest == null || mode.hz > highest.hz) highest = mode;
            if (mode.hz + .05 < demand) continue;
            double ratio = mode.hz / demand;
            double candidate = Math.abs(ratio - Math.rint(ratio));
            if (best == null || candidate < score - .0001 ||
                    (Math.abs(candidate - score) < .0001 && mode.hz < best.hz)) {
                best = mode; score = candidate;
            }
        }
        return best != null ? best : highest;
    }

    String update(long next, double fps, double speed, boolean active) {
        if (next <= 0 || next <= retired || next < owner) return "stale";
        if (next != owner) { restore(); owner = next; demand = 0; }
        if (!active || !Double.isFinite(fps) || fps < 1 || fps > 240 ||
                !Double.isFinite(speed) || speed <= 1 || speed > 3) {
            demand = 0; restore(); return "restored";
        }
        demand = fps * speed;
        return apply();
    }

    private String apply() {
        if (!foreground || demand <= 0) return "suspended";
        Mode mode = choose(port.current(), port.modes(), demand);
        if (mode == null) { restore(); return "unavailable"; }
        if (saved && appliedMode == mode.id && appliedRate == (float)mode.hz) return "unchanged";
        if (!saved) {
            previousMode = port.preferredMode(); previousRate = port.preferredRate(); saved = true;
        }
        appliedMode = mode.id; appliedRate = (float)mode.hz;
        port.prefer(appliedMode, appliedRate);
        return mode.hz + .05 < demand ? "capacity-limited" : "requested";
    }

    private void restore() {
        if (!saved) return;
        // Do not overwrite a setting changed independently since this lease.
        if (port.preferredMode() == appliedMode && port.preferredRate() == appliedRate) {
            port.prefer(previousMode, previousRate);
        }
        saved = false;
    }
    void foreground(boolean active) {
        foreground = active;
        if (active) apply(); else restore();
    }
    void release(long previous, boolean retire) {
        if (retire) retired = Math.max(retired, previous);
        if (previous != owner) return;
        demand = 0; restore();
    }
    void close() { release(owner, true); }
}
