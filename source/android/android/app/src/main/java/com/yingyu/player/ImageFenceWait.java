package com.yingyu.player;

import android.annotation.TargetApi;
import android.hardware.SyncFence;
import android.media.Image;
import java.io.IOException;

/** Same Flutter image wait, with deterministic release of the duplicated fence. */
public final class ImageFenceWait {
    private ImageFenceWait() { }

    @TargetApi(33)
    public static void await(Image image) {
        try (SyncFence fence = image.getFence()) {
            fence.awaitForever();
        } catch (IOException ignored) {
            // Preserve Flutter's existing getFence IO-failure behavior.
        }
    }
}
