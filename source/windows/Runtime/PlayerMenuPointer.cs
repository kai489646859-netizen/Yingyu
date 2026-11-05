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
    {
        try
        {
            if(element is not {IsLoaded:true,Visibility:Visibility.Visible} || element.ActualWidth<=0 || element.ActualHeight<=0 || element.XamlRoot is not {} root || root.RasterizationScale<=0 || !GetCursorPos(out var p))return false;
            var window=Microsoft.UI.Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId);
            if(!ScreenToClient(window,ref p))return false;
            var local=root.Content.TransformToVisual(element).TransformPoint(new Point(p.X/root.RasterizationScale,p.Y/root.RasterizationScale));
            return local.X>=0&&local.Y>=0&&local.X<=element.ActualWidth&&local.Y<=element.ActualHeight;
        }
        catch(InvalidOperationException){return false;}
        catch(COMException){return false;}
    }
}
