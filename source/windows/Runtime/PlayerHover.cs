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

    sealed class State
    {
        readonly object _overlay;
        readonly Grid _root;
        readonly Slider _position;
        readonly Button _volume;
        readonly Flyout _flyout;
        readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _close;
        UIElement? _pointerRoot;
        UIElement? _cursorRoot;
        bool _buttonHover, _popupHover;
        public bool InBottomBand { get; private set; }
        public State(object overlay)
        {
            _overlay = overlay;
            Access.Get<Microsoft.UI.Dispatching.DispatcherQueueTimer>(overlay,"_autoHideTimer").Interval=TimeSpan.FromSeconds(5);
            overlay.GetType().GetEvent("ControlsVisibilityChanged")!.AddEventHandler(overlay,new EventHandler<bool>((_,visible)=>Cursor(visible)));
            _root = Access.Get<Grid>(overlay, "RootGrid");
            _position = Access.Get<Slider>(overlay, "PositionSlider");
            _volume = Access.Get<Button>(overlay, "VolumeButton");
            _flyout = Access.Get<Flyout>(overlay, "VolumeFlyout");
            var chrome = Access.Get<Grid>(overlay, "ChromeLayer");
            chrome.Background ??= new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            _close = _root.DispatcherQueue.CreateTimer();
            _close.IsRepeating = false;
            _close.Interval = TimeSpan.FromMilliseconds(180);
            _close.Tick += (_, _) => { if (!_buttonHover && !_popupHover) _flyout.Hide(); };
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
                        presenter.PointerEntered -= PopupEnter;
                        presenter.PointerExited -= PopupExit;
                        presenter.PointerEntered += PopupEnter;
                        presenter.PointerExited += PopupExit;
                        break;
                    }
                }
            };
            _flyout.Closed += (_, _) => { _popupHover = false; _close.Stop(); };
            ((FrameworkElement)overlay).Unloaded += (_, _) =>
            { Cursor(true);DetachPointerRoot(); InBottomBand = false; _buttonHover = _popupHover = false; _close.Stop(); _flyout.Hide(); };
            if (((FrameworkElement)overlay).IsLoaded) AttachPointerRoot();
        }
        void AttachPointerRoot()
        {
            DetachPointerRoot();
            // The video panel is a sibling of the overlay. Observe the shared
            // player visual root so leaving the controls for video is not lost.
            DependencyObject root = (FrameworkElement)_overlay;
            while (VisualTreeHelper.GetParent(root) is DependencyObject parent)
            {
                root=parent;
                if(root is UIElement element&&root.GetType().GetMethod("HideCursor",Type.EmptyTypes)!=null
                    &&root.GetType().GetMethod("ShowCursor",Type.EmptyTypes)!=null)_cursorRoot=element;
            }
            _pointerRoot = root as UIElement ?? _root;
            _pointerRoot.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(Move), true);
            _pointerRoot.AddHandler(UIElement.PointerExitedEvent, new PointerEventHandler(ExitRoot), true);
            Cursor(Access.Get<bool>(_overlay,"_controlsVisible"));
        }
        void Cursor(bool visible)
        {
            // The existing five-second control timer is the sole idle clock.
            // Both windowed CursorGrid and the existing fullscreen shield
            // follow this event; movement restores through the original path.
            if(_cursorRoot is {} root&&root.GetType().GetMethod(visible?"ShowCursor":"HideCursor",Type.EmptyTypes) is {} method)
                method.Invoke(root,null);
        }
        void DetachPointerRoot()
        {
            if (_pointerRoot == null) return;
            _pointerRoot.RemoveHandler(UIElement.PointerMovedEvent, new PointerEventHandler(Move));
            _pointerRoot.RemoveHandler(UIElement.PointerExitedEvent, new PointerEventHandler(ExitRoot));
            _pointerRoot = null;
            _cursorRoot = null;
        }
        void PopupEnter(object sender, PointerRoutedEventArgs e) { _popupHover = true; _close.Stop(); }
        void PopupExit(object sender, PointerRoutedEventArgs e) { _popupHover = false; CloseSoon(); }
        void CloseSoon() { _close.Stop(); if (!_buttonHover && !_popupHover) _close.Start(); }
        void Move(object sender, PointerRoutedEventArgs e)
        {
            if (!((FrameworkElement)_overlay).IsLoaded || e.Pointer.PointerDeviceType == PointerDeviceType.Touch) return;
            Point p = e.GetCurrentPoint(_root).Position;
            double top = _position.TransformToVisual(_root).TransformPoint(new Point(0, 0)).Y;
            bool within = _position.ActualHeight > 0 && top > 0 && p.X >= 0 && p.X <= _root.ActualWidth
                && p.Y >= top && p.Y <= _root.ActualHeight;
            bool changed = within != InBottomBand;
            InBottomBand = within;
            if (RefreshHover(e) || changed)
                Access.Call(_overlay, "ShowControlsTemporarily");
            // Use the original coordinate check and five-second timer. If the
            // overlay already received this event, the unchanged point is a no-op.
            Access.Call(_overlay, "RootGrid_PointerMoved", sender, e);
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
            for (DependencyObject? node = element; node != null; node = VisualTreeHelper.GetParent(node))
                if (node is UIElement ui && ui.Visibility != Visibility.Visible) return false;
            Point p = e.GetCurrentPoint(element).Position;
            return p.X >= 0 && p.Y >= 0 && p.X <= element.ActualWidth && p.Y <= element.ActualHeight;
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
