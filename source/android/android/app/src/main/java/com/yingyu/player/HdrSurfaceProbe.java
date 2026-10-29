package com.yingyu.player;

import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.view.Surface;
import java.util.function.IntSupplier;

/** Checks only the new HDR window on a worker. Never replaces the live MPV VO. */
final class HdrSurfaceProbe {
    static String inspect(Surface window, String transfer) {
        return inspect(window, transfer, () -> 0);
    }
    static String inspect(Surface window, String transfer, IntSupplier dataSpace) {
        if (window == null || !window.isValid()) return "surface-unavailable";
        if (!transfer.equals("pq") && !transfer.equals("hlg")) return "transfer-invalid";
        if (!EGL14.eglGetCurrentContext().equals(EGL14.EGL_NO_CONTEXT)) return "worker-context-busy";
        // Use the same native helper as the MPV context, before detaching the
        // healthy output. EGL extension support alone cannot establish this.
        String nativeStatus = dataSpaceStatus(dataSpace.getAsInt());
        if (!nativeStatus.equals("ready")) return nativeStatus;
        EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        EGLContext context = EGL14.EGL_NO_CONTEXT;
        EGLSurface surface = EGL14.EGL_NO_SURFACE;
        try {
            int[] version = new int[2];
            if (display.equals(EGL14.EGL_NO_DISPLAY) ||
                    !EGL14.eglInitialize(display, version, 0, version, 1)) return "egl-display";
            String extensions = EGL14.eglQueryString(display, EGL14.EGL_EXTENSIONS);
            if (!extension(extensions, "EGL_KHR_gl_colorspace")) return "egl-colorspace";
            if (!extension(extensions, transfer.equals("pq") ?
                    "EGL_EXT_gl_colorspace_bt2020_pq" : "EGL_EXT_gl_colorspace_bt2020_hlg")) return "egl-hdr-transfer";
            int[] attributes = {EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                    EGL14.EGL_RED_SIZE, 10, EGL14.EGL_GREEN_SIZE, 10,
                    EGL14.EGL_BLUE_SIZE, 10, EGL14.EGL_ALPHA_SIZE, 2, EGL14.EGL_NONE};
            int[] count = new int[1];
            if (!EGL14.eglChooseConfig(display, attributes, 0, null, 0, 0, count, 0) ||
                    count[0] <= 0 || count[0] > 256) return "rgb10-config";
            EGLConfig[] configs = new EGLConfig[count[0]];
            if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0,
                    configs.length, count, 0)) return "rgb10-config";
            EGLConfig config = null;
            for (int i = 0; i < count[0] && i < configs.length; i++) {
                if (bits(display, configs[i], EGL14.EGL_RED_SIZE) == 10 &&
                        bits(display, configs[i], EGL14.EGL_GREEN_SIZE) == 10 &&
                        bits(display, configs[i], EGL14.EGL_BLUE_SIZE) == 10 &&
                        bits(display, configs[i], EGL14.EGL_ALPHA_SIZE) == 2) {
                    config = configs[i]; break;
                }
            }
            if (config == null) return "rgb10-config";
            if (!EGL14.eglBindAPI(EGL14.EGL_OPENGL_ES_API)) return "egl-api";
            context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
                    new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
            if (context == null || context.equals(EGL14.EGL_NO_CONTEXT)) return "egl-context";
            if (!window.isValid()) return "surface-unavailable";
            int colorspace = transfer.equals("pq") ? 0x3340 : 0x3540;
            surface = EGL14.eglCreateWindowSurface(display, config, window,
                    new int[]{0x309d, colorspace, EGL14.EGL_NONE}, 0);
            if (surface == null || surface.equals(EGL14.EGL_NO_SURFACE)) return "egl-window";
            int[] actual = new int[1];
            if (!EGL14.eglQuerySurface(display, surface, 0x309d, actual, 0) ||
                    actual[0] != colorspace) return "surface-colorspace";
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) return "egl-current";
            return "ready";
        } finally {
            // The display is shared with the live MPV context: never terminate
            // it here. This worker owns only its own temporary context/surface.
            if (context != null && !context.equals(EGL14.EGL_NO_CONTEXT)) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            }
            if (surface != null && !surface.equals(EGL14.EGL_NO_SURFACE))
                EGL14.eglDestroySurface(display, surface);
            if (context != null && !context.equals(EGL14.EGL_NO_CONTEXT))
                EGL14.eglDestroyContext(display, context);
            EGL14.eglReleaseThread();
        }
    }

    private static int bits(EGLDisplay display, EGLConfig config, int attribute) {
        int[] value = new int[1];
        return EGL14.eglGetConfigAttrib(display, config, attribute, value, 0) ? value[0] : -1;
    }
    static String dataSpaceStatus(int result) {
        switch (result) {
            case 0: return "ready";
            case 1: return "dataspace-library";
            case 2: return "dataspace-symbols";
            case 3: return "dataspace-set";
            case 4: return "dataspace-readback";
            case 7: return "buffer-format";
            default: return "surface-unavailable";
        }
    }
    static boolean extension(String list, String name) {
        return list != null && (" " + list + " ").contains(" " + name + " ");
    }
}
