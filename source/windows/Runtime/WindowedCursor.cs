using System.Runtime.InteropServices;
using System.Collections.Concurrent;
using Microsoft.UI;
using Microsoft.UI.Windowing;

namespace Yingyu.Update;

public static class WindowedCursor
{
    const int WmActivate = 0x0006;
    const int WmWindowPosChanging = 0x0046;
    const int WmClose = 0x0010;
    const int WmNcDestroy = 0x0082;
    const uint GaRoot = 2;
    const uint SwpNoSize = 0x0001, SwpNoMove = 0x0002, SwpHideWindow = 0x0080;
    const nuint SubclassId = 0x59594357;
    static readonly WindowSubclass Procedure = OnOwnerMessage;
    static readonly ConcurrentDictionary<nint, object> Watches = new();

    public static bool HandleVisibility(object session, bool visible)
    {
        if (Access.Get<object?>(session, "_window") is not { } player
            || Access.Get<object?>(session, "_cursorIdleShield") is not { } shield)
            return false;
        var window = (AppWindow)Access.Call(player, "GetWindow")!;
        var hwnd = Win32Interop.GetWindowFromWindowId(window.Id);
        if (visible || window.Presenter.Kind == AppWindowPresenterKind.FullScreen)
        {
            RemoveWatch(hwnd);
            return false; // The original fullscreen/show handler still owns its shield.
        }

        if (!TryGetBounds(hwnd, out _, out _, out _, out _)) return true;
        if (!Watches.ContainsKey(hwnd))
        {
            if (!SetWindowSubclass(hwnd, Procedure, SubclassId, 0)) return true;
            Watches[hwnd] = shield;
        }
        Access.Call(shield, "Show");
        if (!Access.Get<bool>(shield, "_isArmed")) RemoveWatch(hwnd);
        return true;
    }

    public static bool TryGetBounds(nint hwnd, out int left, out int top, out int right, out int bottom)
    {
        left = top = right = bottom = 0;
        if (hwnd == 0 || !GetClientRect(hwnd, out var client)) return false;
        left = client.Left;
        top = client.Top;
        right = client.Right;
        bottom = client.Bottom;
        var window = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(hwnd));
        if (window == null) return false;
        if (window.Presenter.Kind == AppWindowPresenterKind.FullScreen) return true;

        if (GetForegroundWindow() != hwnd || !GetCursorPos(out var pointer)
            || GetAncestor(WindowFromPoint(pointer), GaRoot) != hwnd
            || !ScreenToClient(hwnd, ref pointer)) return false;
        var titleBar = window.TitleBar;
        if (titleBar.ExtendsContentIntoTitleBar)
            top += titleBar.Height; // AppWindow and HWND coordinates are physical pixels.
        return pointer.X >= left && pointer.X < right && pointer.Y >= top && pointer.Y < bottom;
    }

    static object? RemoveWatch(nint hwnd)
    {
        if (!Watches.TryRemove(hwnd, out var shield)) return null;
        RemoveWindowSubclass(hwnd, Procedure, SubclassId);
        return shield;
    }

    public static void Unwatch(nint hwnd) => RemoveWatch(hwnd);

    static nint OnOwnerMessage(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        bool deactivate = message == WmActivate && (wParam & 0xffff) == 0;
        bool moveOrHide = false;
        if (message == WmWindowPosChanging && lParam != 0)
        {
            uint flags = Marshal.PtrToStructure<WindowPos>(lParam).Flags;
            moveOrHide = (flags & (SwpNoSize | SwpNoMove)) != (SwpNoSize | SwpNoMove)
                || (flags & SwpHideWindow) != 0;
        }
        bool closing = message is WmClose or WmNcDestroy;
        if ((deactivate || moveOrHide || closing)
            && RemoveWatch(hwnd) is { } shield)
        {
            try
            {
                if (Access.Get<bool>(shield, "_isArmed")) Access.Call(shield, "HideCore", !closing);
            }
            catch (Exception error)
            {
                PlaybackTransport.Write("Warning", "Playback.Cursor", "窗口变化时光标恢复失败：" + error.GetType().Name);
            }
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct WindowPos { public nint Window, InsertAfter; public int X, Y, Width, Height; public uint Flags; }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate nint WindowSubclass(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    [DllImport("user32.dll")] static extern bool GetClientRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern nint WindowFromPoint(Point point);
    [DllImport("user32.dll")] static extern nint GetAncestor(nint hwnd, uint flags);
    [DllImport("user32.dll")] static extern bool ScreenToClient(nint hwnd, ref Point point);
    [DllImport("comctl32.dll")] static extern bool SetWindowSubclass(nint hwnd, WindowSubclass callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] static extern bool RemoveWindowSubclass(nint hwnd, WindowSubclass callback, nuint id);
    [DllImport("comctl32.dll")] static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
}
