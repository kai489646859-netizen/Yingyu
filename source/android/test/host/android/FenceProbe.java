package com.yingyu.probe;
import android.graphics.PixelFormat;
import android.hardware.HardwareBuffer;
import android.hardware.SyncFence;
import android.media.Image;
import android.media.ImageReader;
import android.opengl.*;
import android.os.Debug;
import java.io.IOException;

public class FenceProbe {
  // Exact pinned FlutterRenderer.waitOnFence implementation, without outer state.
  static void oldWait(Image image) {
    try { SyncFence fence = image.getFence(); fence.awaitForever(); }
    catch (IOException e) { }
  }
  static void fixedWait(Image image) { com.yingyu.player.ImageFenceWait.await(image); }
  public static void main(String[] args) throws Exception {
    boolean fixed = args[0].equals("fixed");
    EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
    int[] versions = new int[2];
    if (!EGL14.eglInitialize(display,versions,0,versions,1)) throw new AssertionError("EGL init");
    EGLConfig[] configs = new EGLConfig[1]; int[] count = new int[1];
    int[] attributes = {EGL14.EGL_RENDERABLE_TYPE,4,EGL14.EGL_SURFACE_TYPE,EGL14.EGL_WINDOW_BIT,EGL14.EGL_RED_SIZE,8,EGL14.EGL_GREEN_SIZE,8,EGL14.EGL_BLUE_SIZE,8,EGL14.EGL_ALPHA_SIZE,8,EGL14.EGL_NONE};
    if (!EGL14.eglChooseConfig(display,attributes,0,configs,0,1,count,0)||count[0]<1) throw new AssertionError("EGL config");
    EGLContext context=EGL14.eglCreateContext(display,configs[0],EGL14.EGL_NO_CONTEXT,new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION,2,EGL14.EGL_NONE},0);
    ImageReader reader=ImageReader.newInstance(32,32,PixelFormat.RGBA_8888,3,HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE|HardwareBuffer.USAGE_GPU_COLOR_OUTPUT);
    EGLSurface surface=EGL14.eglCreateWindowSurface(display,configs[0],reader.getSurface(),new int[]{EGL14.EGL_NONE},0);
    if (!EGL14.eglMakeCurrent(display,surface,surface,context)) throw new AssertionError("EGL current "+EGL14.eglGetError());
    int start=0,finish=0;
    for(int n=0;n<600;n++) {
      GLES20.glClearColor((n%2),0,0,1); GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
      if(!EGL14.eglSwapBuffers(display,surface)) throw new AssertionError("swap");
      Image image=null; long end=System.nanoTime()+1000000000L;
      while(image==null&&System.nanoTime()<end) {image=reader.acquireNextImage();if(image==null)Thread.sleep(1);}
      if(image==null) throw new AssertionError("image unavailable");
      try {if(fixed)fixedWait(image);else oldWait(image);} finally {image.close();}
      if(n==99)start=new java.io.File("/proc/self/fd").list().length;
      if(n==599)finish=new java.io.File("/proc/self/fd").list().length;
    }
    System.out.println("FENCE_PROBE mode="+args[0]+" frames=500 fd_start="+start+" fd_end="+finish+" delta="+(finish-start));
    EGL14.eglMakeCurrent(display,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_CONTEXT);
    EGL14.eglDestroySurface(display,surface);EGL14.eglDestroyContext(display,context);reader.close();EGL14.eglTerminate(display);
    if(finish-start>8) throw new AssertionError("FENCE_FD_GROWTH "+(finish-start));
  }
}

