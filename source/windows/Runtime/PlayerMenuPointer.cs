using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.Foundation;

namespace Yingyu.Update;

// Recheck the local pointer at the close deadline. Routed enter/exit booleans
// can be stale while native popups appear, resize or change hit-test ownership.
internal static class PlayerMenuPointer
{
    [StructLayout(LayoutKind.Sequential)] struct NativePoint { public int X,Y; }
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] static extern bool ScreenToClient(IntPtr window,ref NativePoint point);
    internal static Point? ScreenPosition()
        => GetCursorPos(out var point) ? new Point(point.X, point.Y) : null;

    internal static bool Contains(FrameworkElement? element)
        => element != null && PositionIn(element) is { } local
            && local.X >= 0 && local.Y >= 0 && local.X <= element.ActualWidth && local.Y <= element.ActualHeight;

    internal static Point? PositionIn(FrameworkElement element)
    {
        try
        {
            if (!element.IsLoaded || element.Visibility != Visibility.Visible || element.ActualWidth <= 0 || element.ActualHeight <= 0
                || element.XamlRoot is not { } root || root.RasterizationScale <= 0 || !GetCursorPos(out var point)) return null;
            var window = Microsoft.UI.Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId);
            if (!ScreenToClient(window, ref point)) return null;
            return root.Content.TransformToVisual(element).TransformPoint(
                new Point(point.X / root.RasterizationScale, point.Y / root.RasterizationScale));
        }
        catch (InvalidOperationException) { return null; }
        catch (COMException) { return null; }
    }
}
