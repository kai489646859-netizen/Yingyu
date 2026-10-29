using System.Runtime.CompilerServices;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

public static class PlayerMenus
{
    static readonly ConditionalWeakTable<object, State> States = new();
    static readonly ConditionalWeakTable<ContentDialog, Flyout> Tools = new();
    public static void Configure(object overlay) => States.GetValue(overlay, x => new State(x));
    internal static void BindEpisodes(object overlay, Flyout flyout)
    { Configure(overlay); States.GetValue(overlay, _ => throw new InvalidOperationException()).BindEpisodes(flyout); }
    internal static void CloseTools(object overlay){if(States.TryGetValue(overlay,out var state))state.CloseTools();}
    public static async Task<ContentDialogResult> ShowTools(ContentDialog dialog, object session)
    {
        var overlay = Access.Get<object>(session, "_overlay");
        Configure(overlay);
        return await States.GetValue(overlay, _ => throw new InvalidOperationException()).ShowTools(dialog,session);
    }
    public static void HideTools(ContentDialog dialog)
    {
        if (Tools.TryGetValue(dialog, out var flyout)) flyout.Hide();
        else dialog.Hide();
    }

    sealed class State
    {
        readonly object _overlay;
        readonly FrameworkElement _element;
        readonly List<Menu> _menus = new();
        Menu? _tools;
        bool _attached,_subtitleTools;
        internal State(object overlay)
        {
            _overlay = overlay;
            _element = (FrameworkElement)overlay;
            _element.Loaded += (_, _) => Attach();
            _element.Unloaded += (_, _) => { foreach (var menu in _menus) menu.Close(); };
        }
        void Attach()
        {
            if (_attached) return;
            _attached = true;
            foreach (var name in new[] { "Speed", "AudioTrack", "SubtitleTrack" })
            {
                var button = Access.Get<Button>(_overlay, name + "Button");
                var flyout = Access.Get<Flyout>(_overlay, name + "Flyout");
                var menu = new Menu(this, button, () =>
                {
                    if (!flyout.IsOpen) flyout.ShowAt(button, new FlyoutShowOptions { ShowMode = FlyoutShowMode.Transient });
                }, flyout.Hide);
                if(name=="SubtitleTrack")flyout.Opened+=(_,_)=>
                {
                    var options=Access.Get<StackPanel>(_overlay,"SubtitleTrackOptionsPanel");
                    if(options.Children.OfType<Button>().Any(b=>b.Name=="SubtitleImportEntry"))return;
                    var load=new Button{Name="SubtitleImportEntry",Content="加载／重试外挂字幕…",HorizontalAlignment=HorizontalAlignment.Stretch};
                    load.Click+=(_,_)=>
                    {
                        flyout.Hide();_subtitleTools=true;
                        if(_tools is not null)Access.Call(_overlay,"DesktopTools_Click",_tools.Button,new RoutedEventArgs());
                    };
                    options.Children.Add(load);
                };
                menu.Bind(flyout);
                _menus.Add(menu);
            }
            var episode = Access.Get<Button>(_overlay, "EpisodeDrawerButton");
            var drawer = Access.Get<Border>(_overlay, "EpisodeDrawer");
            var episodes = new Menu(this, episode, () =>
            {
                if (drawer.Visibility != Visibility.Visible)
                    Access.Call(_overlay, "EpisodeDrawerButton_Click", episode, new RoutedEventArgs());
            }, () => { if (drawer.Visibility == Visibility.Visible) Access.Call(_overlay, "CloseEpisodeDrawer"); });
            episodes.Track(drawer);
            _menus.Add(episodes);
            var toolsButton = Descendants(_element).OfType<Button>().SingleOrDefault(b => b.Content is string label && label == "更多");
            if (toolsButton != null)
            {
                _tools = new Menu(this, toolsButton,
                    () => Access.Call(_overlay, "DesktopTools_Click", toolsButton, new RoutedEventArgs()), () => { });
                _menus.Add(_tools);
            }
            else PlaybackTransport.Write("Warning", "Playback.Menu", "更多按钮暂未找到，保留原点击入口。 ");
            // Existing volume hover remains responsible for its own popup.
            Access.Get<Flyout>(_overlay, "VolumeFlyout").Opened += (_, _) => CloseOthers(null);
        }
        void CloseOthers(Menu? active)
        {
            foreach (var menu in _menus) if (menu != active) menu.Close();
            if (active != null) Access.Get<Flyout>(_overlay, "VolumeFlyout").Hide();
        }
        internal void BindEpisodes(Flyout flyout)
        {
            Attach();
            _menus.Single(m => ReferenceEquals(m.Button, Access.Get<Button>(_overlay,"EpisodeDrawerButton"))).Bind(flyout);
        }
        internal void CloseTools()=>_tools?.Close();
        internal Task<ContentDialogResult> ShowTools(ContentDialog dialog,object session)
        {
            Attach();
            var result = new TaskCompletionSource<ContentDialogResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (dialog.Content is not UIElement content) return dialog.ShowAsync().AsTask();
            PlayerDesktopStyle.GroupTools(content);SubtitlePlacement.Tools(_overlay,content);
            dialog.Content = null;
            bool subtitlesFirst=_subtitleTools;_subtitleTools=false;
            content=AndroidPlayerTools.Build(session,_overlay,content,subtitlesFirst);
            if (_tools == null){dialog.Content=content;return dialog.ShowAsync().AsTask();}
            var flyout = new Flyout { Content = content, Placement = FlyoutPlacementMode.Top };
            NativeDolby.Popup(_overlay,flyout);
            PlayerDesktopStyle.StyleTools(flyout);
            Tools.Add(dialog, flyout);
            _tools.Bind(flyout);
            flyout.Closed += (_, _) =>
            {
                flyout.Content = null;
                Tools.Remove(dialog);
                result.TrySetResult(ContentDialogResult.None);
            };
            try
            {
                CloseOthers(_tools);
                flyout.ShowAt(_tools.Button, new FlyoutShowOptions { ShowMode = FlyoutShowMode.Transient });
                _tools.CloseSoon();
            }
            catch
            {
                _tools.Unbind();
                Tools.Remove(dialog);
                dialog.Content = content;
                return dialog.ShowAsync().AsTask();
            }
            return result.Task;
        }
        static IEnumerable<DependencyObject> Descendants(DependencyObject node)
        {
            yield return node;
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
                foreach (var child in Descendants(VisualTreeHelper.GetChild(node, i))) yield return child;
        }

        sealed class Menu
        {
            readonly State _state;
            readonly Action _open;
            Action _close;
            readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _timer;
            bool _buttonHover, _panelHover;
            FrameworkElement? _panel;
            Flyout? _flyout;
            internal Button Button { get; }
            internal Menu(State state, Button button, Action open, Action close)
            {
                _state = state; Button = button; _open = open; _close = close;
                _timer = button.DispatcherQueue.CreateTimer();
                _timer.IsRepeating = false;
                _timer.Interval = TimeSpan.FromMilliseconds(180);
                _timer.Tick += (_, _) =>
                {
                    // ComboBox has a separate popup; allow its choices to be
                    // selected without closing the containing tools panel.
                    if (_panel != null && Descendants(_panel).OfType<ComboBox>().Any(b => b.IsDropDownOpen))
                    { _timer.Start(); return; }
                    if (!_buttonHover && !_panelHover) Close();
                };
                button.PointerEntered += (_, e) =>
                {
                    if (e.Pointer.PointerDeviceType == PointerDeviceType.Touch || !button.IsEnabled) return;
                    _buttonHover = true; _timer.Stop();
                    _state.CloseOthers(this);
                    Access.Call(_state._overlay, "ShowControlsTemporarily");
                    _open();
                };
                button.PointerExited += (_, _) => { _buttonHover = false; CloseSoon(); };
            }
            internal void Bind(Flyout flyout)
            {
                Unbind();
                _flyout = flyout; _close = flyout.Hide;
                flyout.Opened += Opened;
                flyout.Closed += Closed;
            }
            internal void Unbind()
            {
                if (_flyout != null) { _flyout.Opened -= Opened; _flyout.Closed -= Closed; _flyout = null; }
                Untrack();
            }
            void Opened(object? sender, object args)
            {
                _state.CloseOthers(this);
                DependencyObject? node = _flyout!.Content as DependencyObject;
                while (node != null)
                {
                    if (node is FlyoutPresenter presenter) { Track(presenter); break; }
                    node = VisualTreeHelper.GetParent(node);
                }
                CloseSoon();
            }
            void Closed(object? sender, object args)
            {
                _timer.Stop(); _panelHover = false; Untrack();
            }
            internal void Track(FrameworkElement panel)
            {
                Untrack(); _panel = panel;
                panel.PointerEntered += Enter;
                panel.PointerExited += Exit;
            }
            void Untrack()
            {
                if (_panel == null) return;
                _panel.PointerEntered -= Enter; _panel.PointerExited -= Exit; _panel = null;
            }
            void Enter(object sender, PointerRoutedEventArgs e) { _panelHover = true; _timer.Stop(); }
            void Exit(object sender, PointerRoutedEventArgs e)
            {
                if (_panel != null)
                {
                    var point = e.GetCurrentPoint(_panel).Position;
                    if (point.X >= 0 && point.Y >= 0 && point.X <= _panel.ActualWidth && point.Y <= _panel.ActualHeight) return;
                }
                _panelHover = false; CloseSoon();
            }
            internal void CloseSoon() { _timer.Stop(); if (!_buttonHover && !_panelHover) _timer.Start(); }
            internal void Close() { _timer.Stop(); _panelHover = false; _close(); }
        }
    }
}
