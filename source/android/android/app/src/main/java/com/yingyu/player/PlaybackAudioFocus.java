package com.yingyu.player;

import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import java.util.function.Consumer;

/** Each focus registration owns its callbacks. Late abandoned callbacks cannot
 * pause a later film. Gain restores ducking but never requests playback. */
final class PlaybackAudioFocus {
    private final AudioManager audio;
    private final Consumer<String> signal;
    private AudioFocusRequest request;
    private long generation;
    private boolean granted;
    private int lastChange;

    PlaybackAudioFocus(AudioManager audio, Consumer<String> signal) {
        this.audio = audio;
        this.signal = signal;
    }

    boolean acquire() {
        if (granted) return true;
        release();
        long owner = ++generation;
        request = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setOnAudioFocusChangeListener(change -> changed(owner, change)).build();
        granted = audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        if (!granted) release();
        return granted;
    }

    private void changed(long owner, int change) {
        if (owner != generation || request == null || change == lastChange) return;
        lastChange = change;
        switch (change) {
            case AudioManager.AUDIOFOCUS_GAIN:
                granted = true;
                signal.accept("gain");
                break;
            case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
                signal.accept("duck");
                break;
            case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                granted = false;
                signal.accept("transient");
                break;
            case AudioManager.AUDIOFOCUS_LOSS:
                granted = false;
                signal.accept("loss");
                break;
            default:
                break;
        }
    }

    void release() {
        ++generation;
        granted = false;
        lastChange = 0;
        AudioFocusRequest old = request;
        request = null;
        if (old != null) audio.abandonAudioFocusRequest(old);
    }
}
