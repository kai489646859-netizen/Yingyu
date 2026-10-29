using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace Yingyu.Update;

public static class PlaybackUi
{
    static readonly ConditionalWeakTable<object, object> Attached = new();
    // Only initial centering uses this policy. Manual resizing, full screen,
    // mini player, presenter and media configuration are untouched.
    public static bool CenterWindow(object value)
    {
        try
        {
            if (value is not AppWindow window) return false;
            var display = DisplayArea.GetFromWindowId(window.Id, DisplayAreaFallback.Primary);
            var work = display.WorkArea;
            if (work.Width <= 0 || work.Height <= 0) return false;
            var bounds = display.OuterBounds;
            if (bounds.Width <= 0 || bounds.Height <= 0) return false;
            // The original ConfigureTitleBar runs just after this centering
            // call. Apply its existing content-extension flag before measuring
            // the frame so the later call cannot change the fitted client size.
            if (AppWindowTitleBar.IsCustomizationSupported()) window.TitleBar.ExtendsContentIntoTitleBar = true;
            // Match the fullscreen display's viewport shape, using client pixels
            // rather than the former fixed 1280:760 outer-frame shape. mpv keeps
            // the original source aspect and therefore the same relative fit.
            var handle = Microsoft.UI.Win32Interop.GetWindowFromWindowId(window.Id);
            if (handle == IntPtr.Zero || !GetClientRect(handle, out var client)) return false;
            int frameWidth = Math.Max(0, window.Size.Width - (client.Right - client.Left));
            int frameHeight = Math.Max(0, window.Size.Height - (client.Bottom - client.Top));
            double aspect = (double)bounds.Width / bounds.Height;
            int clientWidth = Math.Max(Math.Min(1280, work.Width), (int)Math.Round(work.Width * .75)) - frameWidth;
            int clientHeight = (int)Math.Round(clientWidth / aspect);
            int heightLimit = Math.Max(Math.Min(760, work.Height), (int)Math.Round(work.Height * .90)) - frameHeight;
            if (clientHeight > heightLimit) { clientHeight = heightLimit; clientWidth = (int)Math.Round(clientHeight * aspect); }
            int width = Math.Clamp(clientWidth + frameWidth, 1, work.Width);
            int height = Math.Clamp(clientHeight + frameHeight, 1, work.Height);
            window.MoveAndResize(new RectInt32(work.X + (work.Width - width) / 2, work.Y + (work.Height - height) / 2, width, height)); return true;
        }
        catch (Exception error)
        {
            PlaybackTransport.Write("Warning", "Playback.Presentation", "默认窗口调整未完成，保留原尺寸策略；异常类型=" + error.GetType().Name); return false;
        }
    }
    [StructLayout(LayoutKind.Sequential)] struct ClientRect { internal int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out ClientRect rect);
    public static void Configure(object overlay)
    {
        PlayerDesktopStyle.Configure(overlay);
        try
        {
            if (overlay is not FrameworkElement element || Attached.TryGetValue(overlay, out _)) return;
            DesktopInputBehavior.Apply(element);Attached.Add(overlay, new object()); element.Loaded += (_, _) => ClearTextTooltips(element);
            if (element.IsLoaded) ClearTextTooltips(element);
        }
        catch (Exception error) { PlaybackTransport.Write("Warning", "Playback.Presentation", "按钮提示调整未完成；异常类型=" + error.GetType().Name); }
    }
    static void ClearTextTooltips(FrameworkElement element)
    {
        try
        {
            foreach (var button in UiElements.Descendants(element).OfType<Button>())
            {
                bool text = button.Content is string label && !string.IsNullOrWhiteSpace(label)
                    || button.Content is TextBlock block && !string.IsNullOrWhiteSpace(block.Text)
                    || button.Content is FrameworkElement content && UiElements.Descendants(content).OfType<TextBlock>().Any(t => t.Visibility == Visibility.Visible && !string.IsNullOrWhiteSpace(t.Text));
                if (text) ToolTipService.SetToolTip(button, null);
            }
            // The original quality label is a TextBlock inside a badge rather
            // than a Button. Clear its tooltip and the badge's attached tooltip.
            var quality = Access.Get<TextBlock>(element, "QualityLabel");
            for (DependencyObject? item = quality; item != null && !ReferenceEquals(item, element); item = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(item))
                ToolTipService.SetToolTip(item, null);
        }
        catch (Exception error) { PlaybackTransport.Write("Warning", "Playback.Presentation", "文字按钮提示检查未完成；异常类型=" + error.GetType().Name); }
    }
}
