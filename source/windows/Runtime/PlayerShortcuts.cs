using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Yingyu.Update;

public static class PlayerShortcuts
{
    static readonly ConditionalWeakTable<object, State> States = new();
    public static void Configure(object overlay) => States.GetValue(overlay, x => new State(x));
    public static bool KeyDown(object overlay, KeyRoutedEventArgs e)
    {
        Configure(overlay);
        return States.GetValue(overlay, _ => throw new InvalidOperationException()).KeyDown(e);
    }
    public static void Disconnect(object overlay)
    {
        if (States.TryGetValue(overlay, out var state)) state.Detach();
    }

    sealed class State
    {
        readonly object _overlay;
        readonly FrameworkElement _element;
        readonly DispatcherQueueTimer _hold;
        readonly DispatcherQueueTimer _watch;
        bool _right;
        bool _boosted;
        double _savedSpeed;
        double _unmutedVolume = 100;
        IntPtr _foreground;
        readonly HashSet<VirtualKey> _held = new();
        readonly ConditionalWeakTable<KeyRoutedEventArgs, object> _processed = new();
        UIElement? _keyboardRoot;
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

        public State(object overlay)
        {
            _overlay = overlay;
            _element = (FrameworkElement)overlay;
            _hold = _element.DispatcherQueue.CreateTimer();
            _hold.Interval = TimeSpan.FromMilliseconds(350);
            _hold.IsRepeating = false;
            _hold.Tick += (_, _) =>
            {
                if (!DesktopTheme.Options.RightHoldBoost || !_right || (GetAsyncKeyState(0x27) & 0x8000) == 0 || GetForegroundWindow() != _foreground) return;
                if (!Access.Get<bool>(_overlay, "_isPlaying")) return;
                _savedSpeed = Access.Get<double>(_overlay, "_currentSpeed");
                _boosted = true;
                Speed(3);
                Feedback("3倍速");
                PlayerFeedback.Hold(_overlay, true);
            };
            _watch = _element.DispatcherQueue.CreateTimer();
            _watch.Interval = TimeSpan.FromMilliseconds(50);
            _watch.IsRepeating = true;
            _watch.Tick += (_, _) =>
            {
                if (!_right) return;
                if (GetForegroundWindow() != _foreground) Release(false);
                else if ((GetAsyncKeyState(0x27) & 0x8000) == 0) Release(true);
            };
            _element.Loaded += (_, _) => Attach();
            _element.Unloaded += (_, _) => Detach();
            _element.LostFocus += (_, _) =>
            {
                // LostFocus bubbles when focus moves between controls in the same
                // player. Do not cancel a held key for such internal transitions.
                var focused = Focused();
                if (!Within(focused, _keyboardRoot)) { Release(false); _held.Clear(); }
            };
        }

        DependencyObject? Focused()
        {
            // LostFocus can finish bubbling after closing detached the overlay.
            if (_keyboardRoot == null || !_element.IsLoaded || _element.XamlRoot is not { } root) return null;
            try { return FocusManager.GetFocusedElement(root) as DependencyObject; }
            catch (Exception error) when (error is ArgumentException || error is COMException)
            {
                PlaybackTransport.Write("Warning", "Playback.Input", "播放器焦点已离开有效窗口；已释放按键状态，未继续查询失效的XamlRoot。 ");
                return null;
            }
        }

        static bool Within(DependencyObject? child, DependencyObject? parent)
        {
            if (parent == null) return false;
            while (child != null)
            {
                if (ReferenceEquals(child, parent)) return true;
                child = VisualTreeHelper.GetParent(child);
            }
            return false;
        }
        void Attach()
        {
            Detach();
            // The interactive video panel is a sibling of the overlay. Keyboard
            // events from that panel never travel through the overlay itself.
            DependencyObject root = _element;
            while (VisualTreeHelper.GetParent(root) is DependencyObject parent) root = parent;
            _keyboardRoot = root as UIElement ?? _element;
            _keyboardRoot.PreviewKeyDown += Preview;
            _keyboardRoot.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(Bubble), true);
            _keyboardRoot.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler(Up), true);
        }
        internal void Detach()
        {
            Release(false);
            KeyboardVolumeFeedback.Hide(_overlay);
            _held.Clear();
            if (_keyboardRoot == null) return;
            _keyboardRoot.PreviewKeyDown -= Preview;
            _keyboardRoot.RemoveHandler(UIElement.KeyDownEvent, new KeyEventHandler(Bubble));
            _keyboardRoot.RemoveHandler(UIElement.KeyUpEvent, new KeyEventHandler(Up));
            _keyboardRoot = null;
        }
        void Preview(object sender, KeyRoutedEventArgs e) => KeyDown(e);
        void Bubble(object sender, KeyRoutedEventArgs e) => KeyDown(e);
        void Up(object sender, KeyRoutedEventArgs e)
        {
            if (_held.Remove(e.Key)) PlaybackTelemetry.Key(_overlay, (int)e.Key, true);
            if (e.Key == VirtualKey.Right && _right) { Release(true); e.Handled = true; }
        }

        bool IsInput(KeyRoutedEventArgs e)
        {
            if (Access.Get<bool>(_overlay, "_desktopDialogOpen")) return true;
            if (Access.Get<HashSet<object>>(_overlay, "_openControlFlyouts").Count != 0) return true;
            if (Access.Get<Border>(_overlay, "EpisodeDrawer").Visibility == Visibility.Visible) return true;
            var focused = Focused();
            // A focused slider owns its native navigation keys. Leave Handled
            // untouched so volume/position controls can process them; global
            // playback commands such as F and Escape remain available.
            bool sliderInput = (focused is Slider || e.OriginalSource is Slider)
                && e.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down
                    or VirtualKey.Home or VirtualKey.End or VirtualKey.PageUp or VirtualKey.PageDown;
            return sliderInput || focused is TextBox or PasswordBox or NumberBox or ComboBox
                || e.OriginalSource is TextBox or PasswordBox or NumberBox or ComboBox;
        }

        public bool KeyDown(KeyRoutedEventArgs e)
        {
            if (_keyboardRoot == null || !_element.IsLoaded || _element.XamlRoot == null) return true;
            if (_processed.TryGetValue(e, out _) || e.Handled) return true;
            // Stop the old player fallback as well, but leave Handled untouched
            // so editors, dialogs and menus retain their own keyboard behavior.
            if ((GetAsyncKeyState(0x11) & 0x8000) != 0 || (GetAsyncKeyState(0x12) & 0x8000) != 0) return true;
            if (e.Key == VirtualKey.Escape && !Access.Get<bool>(_overlay, "_desktopDialogOpen")
                && Access.Get<HashSet<object>>(_overlay, "_openControlFlyouts").Count == 0
                && Access.Get<Border>(_overlay, "EpisodeDrawer").Visibility == Visibility.Visible
                && Focused() is not ComboBox { IsDropDownOpen: true }
                && e.OriginalSource is not ComboBox { IsDropDownOpen: true })
            {
                _processed.Add(e, new object());
                _held.Add(VirtualKey.Escape);
                Release(false);
                Access.Call(_overlay, "CloseEpisodeDrawer");
                e.Handled = true;
                return true;
            }
            if (IsInput(e)) return true;
            var key = e.Key;
            var preferences = DesktopTheme.Options;
            if (!preferences.KeyboardVolumeKeys && key is VirtualKey.Up or VirtualKey.Down) return true;
            if (key == VirtualKey.Right)
            {
                _processed.Add(e, new object());
                PlaybackTelemetry.Key(_overlay, (int)key, false);
                if (!_right)
                {
                    _right = true;
                    _boosted = false;
                    _foreground = GetForegroundWindow();
                    if (preferences.RightHoldBoost) _hold.Start();
                    _watch.Start();
                }
                e.Handled = true;
                return true;
            }
            bool pauseBinding = (int)key == preferences.PauseKey || preferences.PauseKey == 32 && key == VirtualKey.K;
            bool fullScreenBinding = (int)key == preferences.FullScreenKey;
            bool muteBinding = (int)key == preferences.MuteKey;
            // Consume inactive command bindings so the original player fallback
            // cannot execute a second, conflicting shortcut after remapping.
            if ((int)key is 32 or 75 or 80 or 70 or 122 or 71 or 77 or 86
                && !pauseBinding && !fullScreenBinding && !muteBinding) return true;
            var command = pauseBinding ? VirtualKey.Space : fullScreenBinding ? VirtualKey.F : muteBinding ? VirtualKey.M : key;
            bool recognized = command is VirtualKey.Left or VirtualKey.Up or VirtualKey.Down or VirtualKey.M or VirtualKey.J or VirtualKey.L or VirtualKey.Back
                or VirtualKey.Space or VirtualKey.F or VirtualKey.Escape || (int)key is 219 or 221;
            if (!recognized) return false;
            _processed.Add(e, new object());
            bool singlePress = command is VirtualKey.M or VirtualKey.Back or VirtualKey.Space or VirtualKey.F or VirtualKey.Escape || (int)key is 219 or 221;
            // Recover if key-up was delivered to a popup/another window.
            if (!e.KeyStatus.WasKeyDown) _held.Remove(key);
            if (singlePress && !_held.Add(key)) { e.Handled = true; return true; }
            PlaybackTelemetry.Key(_overlay, (int)key, false);
            switch (command)
            {
                case VirtualKey.Left: Seek(-preferences.SeekStepSeconds); break;
                case VirtualKey.J: Seek(-10); break;
                case VirtualKey.L: Seek(10); break;
                case VirtualKey.Up: Volume(5); break;
                case VirtualKey.Down: Volume(-5); break;
                case VirtualKey.M:
                    var slider = Access.Get<Slider>(_overlay, "VolumeSlider");
                    if (slider.Value > 0) { _unmutedVolume = slider.Value; slider.Value = 0; }
                    else slider.Value = Math.Clamp(_unmutedVolume, slider.Minimum, slider.Maximum);
                    Feedback(slider.Value == 0 ? "已静音" : $"音量 {slider.Value:0}%");
                    break;
                case VirtualKey.Space: Raise("TogglePlayRequested", EventArgs.Empty); break;
                case VirtualKey.F: Raise("FullScreenRequested", EventArgs.Empty); break;
                case VirtualKey.Escape: Raise("ExitFullScreenRequested", EventArgs.Empty); break;
                case VirtualKey.Back: Release(false); Speed(1); Feedback("已恢复 1× 倍速"); break;
                default:
                    Release(false);
                    var speed = Math.Clamp(Access.Get<double>(_overlay, "_currentSpeed") + ((int)key == 221 ? .25 : -.25), .25, 3);
                    Speed(speed); Feedback($"倍速 {speed:0.##}×"); break;
            }
            if (key is not (VirtualKey.Up or VirtualKey.Down))
                Access.Call(_overlay, "ShowControlsTemporarily");
            e.Handled = true;
            return true;
        }

        void Release(bool tap)
        {
            if (!_right) return;
            PlaybackTelemetry.Key(_overlay, (int)VirtualKey.Right, true);
            _right = false;
            _hold.Stop();
            _watch.Stop();
            if (_boosted)
            {
                _boosted = false;
                PlayerFeedback.Hold(_overlay, false);
                Speed(_savedSpeed);
                Feedback($"恢复 {_savedSpeed:0.##}× 倍速");
            }
            else if (tap) Seek(DesktopTheme.Options.SeekStepSeconds);
        }

        void Seek(double seconds)
        {
            var slider = Access.Get<Slider>(_overlay, "PositionSlider");
            Raise("SeekRequested", Math.Clamp(slider.Value + seconds, 0, slider.Maximum));
            Feedback(seconds > 0 ? $"快进 {seconds:0} 秒" : $"快退 {-seconds:0} 秒");
            Access.Call(_overlay, "ShowControlsTemporarily");
        }
        void Volume(double delta)
        {
            var slider = Access.Get<Slider>(_overlay, "VolumeSlider");
            slider.Value = Math.Clamp(slider.Value + delta, slider.Minimum, slider.Maximum);
            KeyboardVolumeFeedback.Show(_overlay, slider.Value);
        }
        void Speed(double speed)
        {
            Access.Set(_overlay, "_currentSpeed", speed);
            Access.Get<Button>(_overlay, "SpeedButton").Content = Math.Abs(speed - 1) < .001 ? "倍速" : $"{speed:0.##}×";
            Access.Call(_overlay, "UpdateSpeedOptions");
            Raise("SpeedChanged", speed);
        }
        void Raise(string name, object value) => Access.Get<Delegate?>(_overlay, name)?.DynamicInvoke(_overlay, value);
        void Feedback(string text) => Access.Call(_overlay, "ShowActionFeedback", text, false);
    }
}
