using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Hosting;
using Windows.Graphics;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

public static class PlayerPresentation
{
    // Both presenters use actual HWND client pixels. Do not mix outer-window
    // dimensions with client dimensions or convert physical pixels through XAML DPI.
    public static void UpdateWindow(object window)
    {
        ColorDiagnostics.WindowChanged(window);
        var handle = (IntPtr)window.GetType().GetProperty("Handle")!.GetValue(window)!;
        if (handle == IntPtr.Zero || !GetClientRect(handle, out var rect)) return;
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) return;
        var source = Access.Get<DesktopWindowXamlSource>(window, "_xamlSource");
        // MoveAndResize also notifies the native child hierarchy. Media, decoder,
        // current time, pause state and network/cache ownership are never replaced.
        source.SiteBridge.MoveAndResize(new RectInt32(0, 0, width, height));
    }

    public static void Configure(object session)
    {
        var client = Access.Get<MpvClient?>(session, "_mpvClient");
        if (client == null) return;
        foreach (var (key, value) in new (string, string)[]
        {
            ("keepaspect", "yes"), ("keepaspect-window", "no"),
            ("video-aspect-override", "no"), ("video-aspect-method", "container"),
            ("video-unscaled", "no"), ("panscan", "0"), ("video-zoom", "0"),
            ("video-scale-x", "1"), ("video-scale-y", "1"),
            ("video-pan-x", "0"), ("video-pan-y", "0"),
            ("video-align-x", "0"), ("video-align-y", "0"),
            ("video-crop", "0x0+0+0"), ("monitoraspect", "0"), ("monitorpixelaspect", "1")
        })
            if (PlaybackTransport.Set(client, key, value) < 0)
                PlaybackTransport.Write("Warning", "Playback.Presentation", "显示参数未被接受：" + key);
        PlaybackTransport.Write("Info", "Playback.Presentation", "窗口/全屏共用片源显示比例与完整画面适配；切换只调整客户区，不重载媒体。 ");
    }
    [StructLayout(LayoutKind.Sequential)] struct Rect { internal int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out Rect rect);
}
