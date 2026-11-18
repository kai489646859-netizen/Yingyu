using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;
using Microsoft.UI.Input;

namespace Yingyu.Update;

public static class PlayerHover
{
    static readonly ConditionalWeakTable<object, State> States = new();
    public static void Configure(object overlay) => States.GetValue(overlay, x => new State(x));
    public static bool KeepVisible(object overlay) => States.TryGetValue(overlay, out var state) && state.InBottomBand;

    internal static HashSet<object> ActiveFlyouts(object overlay)
    {
        var flyouts = Access.Get<HashSet<object>>(overlay, "_openControlFlyouts");
        flyouts.RemoveWhere(static item => item is FlyoutBase { IsOpen: false });
        return flyouts;
    }

    public static bool PrepareIdleCheck(object overlay)
        => States.TryGetValue(overlay, out var state) && state.PrepareIdleCheck();

    sealed class State
    {
        readonly object _overlay;
        readonly Grid _root;
        readonly Slider _position;
        readonly Button _volume;
        readonly Flyout _flyout;
        readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _close;
        UIElement? _pointerRoot;
        bool _buttonHover, _popupHover;
        FrameworkElement? _popupPanel;
        public bool InBottomBand { get; private set; }
        public State(object overlay)
        {
            _overlay = overlay;
            Access.Get<Microsoft.UI.Dispatching.DispatcherQueueTimer>(overlay,"_autoHideTimer").Interval=TimeSpan.FromSeconds(3.5);
            _root = Access.Get<Grid>(overlay, "RootGrid");
            _position = Access.Get<Slider>(overlay, "PositionSlider");
            _volume = Access.Get<Button>(overlay, "VolumeButton");
            _flyout = Access.Get<Flyout>(overlay, "VolumeFlyout");
            var chrome = Access.Get<Grid>(overlay, "ChromeLayer");
            chrome.Background ??= new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            _close = _root.DispatcherQueue.CreateTimer();
            _close.IsRepeating = false;
            _close.Interval = TimeSpan.FromMilliseconds(180);
            _close.Tick += (_, _) => { if (PlayerSliderInput.VolumeDragging(_overlay)) { _close.Start(); return; } if (PlayerMenuPointer.Contains(_volume) || PlayerMenuPointer.Contains(_popupPanel)) { _close.Start(); return; } _flyout.Hide(); };
            ((FrameworkElement)overlay).Loaded += (_, _) => AttachPointerRoot();
            _volume.PointerEntered += (_, e) =>
            {
                if (e.Pointer.PointerDeviceType == PointerDeviceType.Touch) return;
                _buttonHover = true;
                _close.Stop();
                Access.Call(_overlay, "ShowControlsTemporarily");
                if (!_flyout.IsOpen) _flyout.ShowAt(_volume, new FlyoutShowOptions { ShowMode = FlyoutShowMode.Transient });
            };
            _volume.PointerExited += (_, _) => { _buttonHover = false; CloseSoon(); };
            // Track the presenter, including its padding, so moving between the button
            // and the existing slider does not close the popup while it is being used.
            _flyout.Opened += (_, _) =>
            {
                DependencyObject node = _flyout.Content;
                while (VisualTreeHelper.GetParent(node) is DependencyObject parent)
                {
                    node = parent;
                    if (node is FlyoutPresenter presenter)
                    {
                        _popupPanel=presenter;
                        presenter.PointerEntered -= PopupEnter;
                        presenter.PointerExited -= PopupExit;
                        presenter.PointerEntered += PopupEnter;
                        presenter.PointerExited += PopupExit;
                        break;
                    }
                }
            };
            _flyout.Closing += (_, e) =>
            {
                if (PlayerSliderInput.VolumeDragging(_overlay)) e.Cancel = true;
            };
            _flyout.Closed += (_, _) => { _popupPanel=null; _popupHover = false; _close.Stop(); };
            ((FrameworkElement)overlay).Unloaded += (_, _) =>
            { PlayerSliderInput.CancelVolumeDrag(_overlay); DetachPointerRoot(); InBottomBand = false; _buttonHover = false; _popupPanel=null; _popupHover = false; _close.Stop(); _flyout.Hide(); };
            if (((FrameworkElement)overlay).IsLoaded) AttachPointerRoot();
        }
        void AttachPointerRoot()
        {
            DetachPointerRoot();
            // The video panel is a sibling of the overlay. Observe the shared
            // player visual root so leaving the controls for video is not lost.
            DependencyObject root = (FrameworkElement)_overlay;
            while (VisualTreeHelper.GetParent(root) is DependencyObject parent)
                root = parent;
            _pointerRoot = root as UIElement ?? _root;
            _pointerRoot.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(Move), true);
            _pointerRoot.AddHandler(UIElement.PointerExitedEvent, new PointerEventHandler(ExitRoot), true);
        }
        void DetachPointerRoot()
        {
            if (_pointerRoot == null) return;
            _pointerRoot.RemoveHandler(UIElement.PointerMovedEvent, new PointerEventHandler(Move));
            _pointerRoot.RemoveHandler(UIElement.PointerExitedEvent, new PointerEventHandler(ExitRoot));
            _pointerRoot = null;
        }
        void PopupEnter(object sender, PointerRoutedEventArgs e) { _popupHover = true; _close.Start(); }
        void PopupExit(object sender, PointerRoutedEventArgs e) { _popupHover = false; CloseSoon(); }
        void CloseSoon() { _close.Stop(); if (!_buttonHover && !_popupHover) _close.Start(); }
        void Move(object sender, PointerRoutedEventArgs e)
        {
            if (!((FrameworkElement)_overlay).IsLoaded || e.Pointer.PointerDeviceType == PointerDeviceType.Touch) return;
            Point p = e.GetCurrentPoint(_root).Position;
            bool within = IsInBottomBand(p);
            bool changed = within != InBottomBand;
            InBottomBand = within;
            if (RefreshHover(e) || changed)
                Access.Call(_overlay, "ShowControlsTemporarily");
            // Use the original coordinate check and hide timer. If the
            // overlay already received this event, the unchanged point is a no-op.
            Access.Call(_overlay, "RootGrid_PointerMoved", sender, e);
        }
        public bool PrepareIdleCheck()
        {
            if (!_root.IsLoaded || Access.Get<bool>(_overlay, "_updateDisconnected")
                || !Access.Get<bool>(_overlay, "_controlsVisible") || !PlayerFeedback.CanIdleHide(_overlay)) return false;

            // Layout changes, pointer capture and native popups can suppress exit events.
            if (InBottomBand)
                InBottomBand = PlayerMenuPointer.PositionIn(_root) is { } point
                    && IsInBottomBand(point);
            Access.Get<HashSet<FrameworkElement>>(_overlay, "_hoveredControlRegions")
                .RemoveWhere(static region => !IsVisible(region) || !PlayerMenuPointer.Contains(region));
            if (!Access.Get<bool>(_overlay, "_isSeeking") && Access.Get<bool>(_overlay, "_seekHovering")
                && (!IsVisible(_position) || !PlayerMenuPointer.Contains(_position)))
                Access.Call(_overlay, "HideSeekPreview");
            ActiveFlyouts(_overlay);
            return true;
        }

        bool IsInBottomBand(Point point)
        {
            double top = _position.TransformToVisual(_root).TransformPoint(new Point()).Y;
            return _position.ActualHeight > 0 && top > 0 && point.X >= 0 && point.X <= _root.ActualWidth
                && point.Y >= top && point.Y <= _root.ActualHeight;
        }

        bool RefreshHover(PointerRoutedEventArgs e)
        {
            // A collapsed feedback panel or a transition to the sibling video
            // can omit PointerExited. Clear only regions no longer under the
            // actual pointer; never clear drag, dialog or open-flyout guards.
            var regions = Access.Get<HashSet<FrameworkElement>>(_overlay, "_hoveredControlRegions");
            bool changed = regions.RemoveWhere(region => !Contains(region, e)) != 0;
            if (!Access.Get<bool>(_overlay, "_isSeeking") && Access.Get<bool>(_overlay, "_seekHovering")
                && !Contains(_position, e))
            {
                Access.Call(_overlay, "HideSeekPreview");
                changed = true;
            }
            return changed;
        }
        static bool Contains(FrameworkElement element, PointerRoutedEventArgs e)
        {
            if (!element.IsLoaded || element.ActualWidth <= 0 || element.ActualHeight <= 0) return false;
            if (!IsVisible(element)) return false;
            Point p = e.GetCurrentPoint(element).Position;
            return p.X >= 0 && p.Y >= 0 && p.X <= element.ActualWidth && p.Y <= element.ActualHeight;
        }
        static bool IsVisible(FrameworkElement element)
        {
            for (DependencyObject? node = element; node != null; node = VisualTreeHelper.GetParent(node))
                if (node is UIElement { Visibility: not Visibility.Visible }) return false;
            return true;
        }

        void ExitRoot(object sender, PointerRoutedEventArgs e)
        {
            if (!((FrameworkElement)_overlay).IsLoaded || e.Pointer.PointerDeviceType == PointerDeviceType.Touch) return;
            Point p = e.GetCurrentPoint(_root).Position;
            if (p.X >= 0 && p.Y >= 0 && p.X <= _root.ActualWidth && p.Y <= _root.ActualHeight) return;
            InBottomBand = false;
            RefreshHover(e);
            Access.Call(_overlay, "ShowControlsTemporarily");
        }
    }
}

