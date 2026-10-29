using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Yingyu.Update;

// Keyboard-only feedback is a sibling of the chrome, not a flyout or a focusable
// control. Its own timeout never changes the controls' existing visibility/timer.
public static class KeyboardVolumeFeedback
{
    static readonly ConditionalWeakTable<object, State> States = new();
    public static void Show(object overlay, double value)
        => States.GetValue(overlay, x => new State(x)).Show(value);
    public static void Hide(object overlay)
    {
        if (States.TryGetValue(overlay, out var state)) state.Hide();
    }

    sealed class State
    {
        readonly FrameworkElement _overlay;
        readonly Grid _layer = new() { IsHitTestVisible = false };
        readonly TextBlock _text = new()
        {
            FontSize = 24, Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)),
            TextAlignment = TextAlignment.Center
        };
        readonly Border _panel;
        readonly DispatcherQueueTimer _timer;
        Grid? _root;

        internal State(object overlay)
        {
            _overlay = (FrameworkElement)overlay;
            _panel = new Border
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0), Padding = new Thickness(24, 12, 24, 12),
                CornerRadius = new CornerRadius(10), IsHitTestVisible = false,
                Background = new SolidColorBrush(Color.FromArgb(102, 40, 40, 40)),
                Visibility = Visibility.Collapsed, Child = _text
            };
            _layer.Children.Add(_panel);
            _timer = _overlay.DispatcherQueue.CreateTimer();
            _timer.IsRepeating = false;
            _timer.Interval = TimeSpan.FromSeconds(2);
            _timer.Tick += (_, _) => _panel.Visibility = Visibility.Collapsed;
            _overlay.Unloaded += (_, _) => Hide();
        }

        internal void Show(double value)
        {
            if (!_overlay.IsLoaded) return;
            if (_root == null)
            {
                _root = Access.Get<Grid>(_overlay, "RootGrid");
                Grid.SetRowSpan(_layer, Math.Max(1, _root.RowDefinitions.Count));
                Grid.SetColumnSpan(_layer, Math.Max(1, _root.ColumnDefinitions.Count));
                _root.Children.Add(_layer);
            }
            _text.Text = $"音量 {value:0}%";
            _panel.Visibility = Visibility.Visible;
            _timer.Stop();
            _timer.Start();
        }

        internal void Hide()
        {
            _timer.Stop();
            _panel.Visibility = Visibility.Collapsed;
            _root?.Children.Remove(_layer);
            _root = null;
        }
    }
}
