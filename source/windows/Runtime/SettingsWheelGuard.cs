using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Yingyu.Update;

// WinUI ComboBox changes its selection in the native class handler before
// ordinary routed handlers run. Intercept only queued wheel messages on this
// application's settings UI thread, before that handler can save a value.
// No global mouse/keyboard hook, input recording or player HWND is involved.
public static class SettingsWheelGuard
{
    static readonly ConditionalWeakTable<object, State> States = new();
    static readonly Dictionary<IntPtr, State> ActiveHooks = new();
    public static void Enable(object page)
    {
        try { States.GetValue(page, p => new State(p)).Enable(); }
        catch (Exception error) { Report(error); }
    }
    public static void Disable(object page)
    {
        try { if (States.TryGetValue(page, out var state)) state.Disable(); }
        catch (Exception error) { Report(error); }
    }
    static void Report(Exception error) => PlaybackTransport.Write("Warning", "Settings", "设置滚轮保护未完成；异常类型=" + error.GetType().Name);
    sealed class State
    {
        readonly FrameworkElement _page;
        readonly Grid _settings;
        readonly ScrollViewer _scroll;
        readonly HookProc _callback;
        IntPtr _hook, _window;
        bool _enabled, _scrollPending, _reported;
        int _generation;
        double _target;
        internal State(object page)
        {
            _page = (FrameworkElement)page;
            _settings = Access.Get<Grid>(page, "SettingsView");
            _scroll = Access.Get<ScrollViewer>(page, "SettingsContentScrollViewer");
            _callback = Message;
            _settings.Loaded += (_, _) => { if (_enabled) SettingsWheelGuard.Enable(_page); };
            _settings.Unloaded += (_, _) => Disable();
            _settings.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) =>
            {
                if (_settings.Visibility != Visibility.Visible) Disable();
            });
            _page.Unloaded += (_, _) => Disable();
        }
        internal void Enable()
        {
            _enabled = true;
            if (_hook != IntPtr.Zero || !_page.IsLoaded || !_settings.IsLoaded || _settings.Visibility != Visibility.Visible || _settings.XamlRoot == null) return;
            _window = Microsoft.UI.Win32Interop.GetWindowFromWindowId(_settings.XamlRoot.ContentIslandEnvironment.AppWindowId);
            if (_window == IntPtr.Zero || !_settings.DispatcherQueue.HasThreadAccess) return;
            // A nonzero thread ID is required: never install a desktop-wide hook.
            uint thread = GetCurrentThreadId();
            if (thread == 0) return;
            _hook = SetWindowsHookExW(3, _callback, IntPtr.Zero, thread);
            if (_hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            ActiveHooks.Add(_hook, this);
        }
        internal void Disable()
        {
            _enabled = false; _generation++; _scrollPending = false;
            if (_hook == IntPtr.Zero) return;
            var hook = _hook;
            if (UnhookWindowsHookEx(hook)) { _hook = IntPtr.Zero; ActiveHooks.Remove(hook); }
            // Keep the callback rooted if Windows has not removed the hook.
        }
        IntPtr Message(int code, nuint removed, IntPtr data)
        {
            try
            {
                if (code >= 0 && removed == 1 && data != IntPtr.Zero && _enabled)
                {
                    uint id = unchecked((uint)Marshal.ReadInt32(data, IntPtr.Size));
                    if (id is 0x020A or 0x024E)
                    {
                        var message = Marshal.PtrToStructure<NativeMessage>(data);
                        if (RouteWheel(message)) Marshal.WriteInt32(data, IntPtr.Size, 0); // WM_NULL
                    }
                }
            }
            catch (Exception error) { if (!_reported) { _reported = true; Report(error); } }
            return CallNextHookEx(_hook, code, removed, data);
        }
        bool RouteWheel(NativeMessage message)
        {
            if (!_settings.IsLoaded || _settings.Visibility != Visibility.Visible || _settings.XamlRoot is not { } root
                || !_scroll.IsLoaded || (message.Window != _window && !IsChild(_window, message.Window))) return false;
            var point = message.Point;
            if (!ScreenToClient(_window, ref point) || root.RasterizationScale <= 0) return false;
            var position = new Point(point.X / root.RasterizationScale, point.Y / root.RasterizationScale);
            var elements = VisualTreeHelper.FindElementsInHostCoordinates(position, root.Content).ToArray();
            FrameworkElement? option = null;
            foreach (var hit in elements)
            {
                DependencyObject? current = hit;
                FrameworkElement? candidate = null;
                bool inside = false;
                while (current != null)
                {
                    if (current is ComboBox { IsDropDownOpen: true }) return false; // preserve popup list scrolling
                    if (current is ComboBox or NumberBox or Slider) candidate ??= (FrameworkElement)current;
                    if (ReferenceEquals(current, _settings)) { inside = true; break; }
                    current = VisualTreeHelper.GetParent(current);
                }
                if (inside && candidate != null) { option = candidate; break; }
            }
            if (option == null) return false;
            short delta = unchecked((short)((message.WParam >> 16) & 0xFFFF));
            if (delta == 0) return true;
            uint lines = 3;
            SystemParametersInfoW(0x0068, 0, ref lines, 0);
            double amount = lines == uint.MaxValue ? _scroll.ViewportHeight * .9 : Math.Min(lines, 100) * 20d;
            _target = Math.Clamp((_scrollPending ? _target : _scroll.VerticalOffset) - delta / 120d * amount, 0, _scroll.ScrollableHeight);
            if (_scrollPending) return true;
            int generation = _generation;
            _scrollPending = true;
            if (_settings.DispatcherQueue.TryEnqueue(() =>
            {
                try
                {
                    if (_enabled && generation == _generation && _settings.IsLoaded && _settings.Visibility == Visibility.Visible && _scroll.IsLoaded)
                        _scroll.ChangeView(null, _target, null, true);
                }
                catch (Exception error) { if (!_reported) { _reported = true; Report(error); } }
                finally { if (generation == _generation) _scrollPending = false; }
            })) return true;
            _scrollPending = false; return false;
        }
    }
    [StructLayout(LayoutKind.Sequential)] struct NativePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct NativeMessage
    {
        public IntPtr Window; public uint Id; public nuint WParam; public IntPtr LParam;
        public uint Time; public NativePoint Point; public uint Private;
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate IntPtr HookProc(int code, nuint removed, IntPtr data);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookExW(int type, HookProc callback, IntPtr module, uint thread);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, nuint removed, IntPtr data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool ScreenToClient(IntPtr window, ref NativePoint point);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool SystemParametersInfoW(uint action, uint parameter, ref uint value, uint flags);
}
