using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Richasy.MpvKernel.Core.Enums;

namespace Yingyu.Update;

public static class PlayerFeedback
{
    static readonly ConditionalWeakTable<object, State> States = new();
    public static void Configure(object overlay) => States.GetValue(overlay, x => new State(x));
    public static void Hold(object overlay, bool active)
    {
        Configure(overlay);
        States.GetValue(overlay, _ => throw new InvalidOperationException()).Held = active;
        if (active) Sync(overlay);
        else if (States.TryGetValue(overlay, out var state) && state.Session?.TryGetTarget(out var session) == true)
            MediaNotice.Ready(session);
    }
    internal static bool CanShowMediaNotice(object overlay) => States.TryGetValue(overlay, out var state)
        && !state.Held && state.LastStatus is MpvPlayerState.Playing or MpvPlayerState.Paused;
    public static void Sync(object overlay)
    {
        if (!States.TryGetValue(overlay, out var state) || !state.Held) return;
        Access.Get<DispatcherQueueTimer?>(overlay, "_actionFeedbackTimer")?.Stop();
        Access.Get<TextBlock>(overlay, "ActionFeedbackText").Text = "3倍速";
        Access.Get<Border>(overlay, "ActionFeedbackBorder").Visibility = Visibility.Visible;
    }
    public static void Bind(object session)
    {
        ResumeDeviceSync.CaptureMedia(session);
        var overlay = Access.Get<object?>(session, "_overlay");
        if (overlay == null) return;
        Configure(overlay);
        var state = States.GetValue(overlay, x => new State(x));
        state.Session = new WeakReference<object>(session);
        state.LastStatus = null;
        MediaNotice.Begin(session);
        PlayerMediaInfo.Bind(session);
        NativeDolby.Bind(session);
    }
    public static void KeepStartupVisible(object overlay, MpvPlayerState status)
    {
        if (States.TryGetValue(overlay, out var saved)) saved.LastStatus = status;
        if (status is MpvPlayerState.Playing or MpvPlayerState.Paused
            && saved?.Session?.TryGetTarget(out var media) == true) MediaNotice.Ready(media);
        // Initial pause/core-idle notifications may precede file-loaded/first
        // frame, especially on reopen. They are not a readiness signal.
        if (status is not (MpvPlayerState.Paused or MpvPlayerState.Playing)) return;
        try
        {
            if (!States.TryGetValue(overlay, out var state) || state.Session == null
                || !state.Session.TryGetTarget(out var session)
                || Access.Get<bool>(session, "_hasStartedPlayback")
                || Access.Get<bool>(session, "_startupTerminalFailure")
                || (bool)session.GetType().GetProperty("_isClosing", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic)!.GetValue(session)!
                || Access.Get<Microsoft.UI.Xaml.Controls.Button>(overlay, "RetryPlaybackButton").Visibility == Visibility.Visible) return;
            Access.Get<ProgressRing>(overlay, "PlaybackStatusRing").IsActive = true;
            Access.Get<TextBlock>(overlay, "PlaybackStatusText").Text = "正在加载…";
            Access.Get<Border>(overlay, "PlaybackStatusPanel").Visibility = Visibility.Visible;
        }
        catch (Exception error) { PlaybackTransport.Write("Warning", "Playback.Feedback", "加载状态同步未完成；异常类型=" + error.GetType().Name); }
    }
    public static void Ready(object session)
    {
        if(DolbyHdrFallback.IsFailed(session))return;
        MediaNotice.Ready(session);
        var overlay = Access.Get<object?>(session, "_overlay");
        if (overlay is not FrameworkElement element) return;
        int generation = Access.Get<int>(session, "_mediaGeneration");
        element.DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                if (generation != Access.Get<int>(session, "_mediaGeneration")
                    || !Access.Get<bool>(session, "_hasStartedPlayback")
                    || Access.Get<bool>(session, "_startupTerminalFailure")
                    || (bool)session.GetType().GetProperty("_isClosing", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic)!.GetValue(session)!
                    || !States.TryGetValue(overlay, out var state)
                    || state.LastStatus is not (MpvPlayerState.Playing or MpvPlayerState.Paused)
                    || Access.Get<Button>(overlay, "RetryPlaybackButton").Visibility == Visibility.Visible) return;
                Access.Get<Border>(overlay, "PlaybackStatusPanel").Visibility = Visibility.Collapsed;
                Access.Get<ProgressRing>(overlay, "PlaybackStatusRing").IsActive = false;
            }
            catch (Exception error) { PlaybackTransport.Write("Warning", "Playback.Feedback", "首帧提示同步未完成；异常类型=" + error.GetType().Name); }
        });
    }
    sealed class State
    {
        internal WeakReference<object>? Session;
        internal MpvPlayerState? LastStatus;
        internal bool Held;
        internal State(object overlay)
        {
            // WinUI's visual parents may not exist during InitializeComponent.
            ((FrameworkElement)overlay).Loaded += (_, _) =>
            {
                try { Attach(overlay); }
                catch (Exception error) { PlaybackTransport.Write("Warning", "Playback.Feedback", "提示层连接失败，保留播放会话：" + error.GetType().Name); }
            };
        }
        bool _attached;
        void Attach(object overlay)
        {
            if (_attached) return;
            var root = Access.Get<Grid>(overlay, "RootGrid");
            var layer = new Grid(); // No background: empty space remains click-through.
            Grid.SetRowSpan(layer, Math.Max(1, root.RowDefinitions.Count));
            Grid.SetColumnSpan(layer, Math.Max(1, root.ColumnDefinitions.Count));
            var panels = new[] { "ActionFeedbackBorder", "PlaybackStatusPanel" }
                .Select(name => Access.Get<Border>(overlay, name)).ToArray();
            var parents = panels.Select(panel => panel.Parent ?? VisualTreeHelper.GetParent(panel)).ToArray();
            if (parents.Any(parent => parent is not (Panel or Border or ContentControl or ContentPresenter)))
            {
                // An unexpected visual tree must never prevent ordinary playback.
                PlaybackTransport.Write("Warning", "Playback.Feedback", "提示层父容器结构不匹配，已保留原界面。 ");
                return;
            }
            for (int i = 0; i < panels.Length; i++)
            {
                var panel = panels[i];
                switch (parents[i])
                {
                    case Panel oldParent: oldParent.Children.Remove(panel); break;
                    case Border oldParent: oldParent.Child = null; break;
                    case ContentControl oldParent: oldParent.Content = null; break;
                    case ContentPresenter oldParent: oldParent.Content = null; break;
                }
                // The feedback canvas has one cell covering the complete viewport.
                Grid.SetRow(panel, 0); Grid.SetColumn(panel, 0);
                layer.Children.Add(panel);
            }
            root.Children.Add(layer);
            _attached = true;
        }
    }
}
