package com.yingyu.player;

import java.util.HashSet;
import java.util.Set;

/** Android ActivityInfo values; independent of player sessions and audio focus. */
final class OrientationController {
    static final int UNSPECIFIED = -1, PORTRAIT = 1, SENSOR_LANDSCAPE = 6;
    private final Set<Long> players = new HashSet<>();
    boolean hasPlayers() { return !players.isEmpty(); }
    void update(long owner, boolean active) {
        if (active) players.add(owner); else players.remove(owner);
    }
    int requested(float shortestDisplayDp) {
        if (!players.isEmpty()) return SENSOR_LANDSCAPE;
        return shortestDisplayDp > 0 && shortestDisplayDp < 600 ? PORTRAIT : UNSPECIFIED;
    }
}
