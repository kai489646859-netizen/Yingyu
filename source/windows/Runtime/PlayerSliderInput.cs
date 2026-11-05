using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Yingyu.Update;

// Own pointer input before it reaches the native Slider/Thumb drag handlers.
// Keep the original Slider for layout, rendering, keyboard and accessibility.
public static class PlayerSliderInput
{
    static readonly ConditionalWeakTable<object, State> States = new();
    public static void Configure(object owner) => States.GetValue(owner, x => new State(x));
    internal static void ConfigureDanmaku(Slider slider) => new State.Input(null, slider, false);
    public static void Reset(object owner) { if (States.TryGetValue(owner, out var s)) s.Reset(); }
    public static bool VolumeDragging(object owner) => States.TryGetValue(owner, out var s) && s.VolumeDragging;
    public static bool HoldPosition(object owner, double position, double duration)
        => States.TryGetValue(owner, out var s) && s.Hold(position, duration);

    sealed class State
    {
        readonly object owner;
        readonly Slider position;
        double? target;
        long expires;
        readonly Input volume; readonly Input seekInput; internal bool VolumeDragging => volume.Dragging;
        internal void Reset() { seekInput.Abort(); volume.Abort(); target = null; Access.Set(owner, "_isSeeking", false); }
        internal State(object owner)
        {
            this.owner = owner;
            position = Access.Get<Slider>(owner, "PositionSlider");
            seekInput = new Input(this, position, true);
            volume = new Input(this, Access.Get<Slider>(owner, "VolumeSlider"), false);
            ((FrameworkElement)owner).Unloaded += (_, _) => { target = null; Access.Set(owner, "_isSeeking", false); };
        }
        internal bool Hold(double value, double duration)
        {
            if (Access.Get<bool>(owner, "_isSeeking")) return true;
            if (target is not double t) return false;
            if (Environment.TickCount64 >= expires || duration != position.Maximum || Math.Abs(value - t) <= 1)
            { target = null; return false; }
            return true;
        }
        internal void Begin() { target = null; Access.Set(owner, "_isSeeking", true); Access.Get<Microsoft.UI.Dispatching.DispatcherQueueTimer>(owner, "_autoHideTimer").Stop(); }
        internal void End(bool commit)
        {
            Access.Set(owner, "_isSeeking", false);
            if (commit)
            {
                target = position.Value; expires = Environment.TickCount64 + 5000;
                Access.Get<Delegate?>(owner, "SeekRequested")?.DynamicInvoke(owner, position.Value);
            }
            Access.Call(owner, "ShowControlsTemporarily");
        }

        internal sealed class Input
        {
            readonly State? state; readonly Slider slider; readonly bool seek;
            Grid? surface; FrameworkElement? track; Thumb? thumb;
            uint? pointer; double offset;
            internal bool Dragging => pointer != null;
            internal Input(State? state, Slider slider, bool seek)
            {
                this.state = state; this.slider = slider; this.seek = seek;
                slider.Loaded += (_, _) => Attach();
                slider.Unloaded += (_, _) => Finish(false);
                if (slider.IsLoaded) Attach();
            }
            void Attach()
            {
                slider.ApplyTemplate();
                if (VisualTreeHelper.GetChildrenCount(slider) == 0 || VisualTreeHelper.GetChild(slider, 0) is not Grid root) return;
                if (ReferenceEquals(root, surface)) return;
                var vertical = slider.Orientation == Orientation.Vertical;
                var nextThumb = UiElements.Descendants(root).OfType<Thumb>().FirstOrDefault(t => t.Name == (vertical ? "VerticalThumb" : "HorizontalThumb"));
                if (nextThumb is null || VisualTreeHelper.GetParent(nextThumb) is not FrameworkElement nextTrack) return;
                if (surface is not null)
                {
                    Finish(false);
                    surface.PointerPressed -= Press; surface.PointerMoved -= Move;
                    surface.PointerReleased -= Release; surface.PointerCanceled -= Cancel;
                    surface.PointerCaptureLost -= Lost;
                }
                thumb = nextThumb;
                track = nextTrack;
                surface = root;
                foreach (var child in root.Children) child.IsHitTestVisible = false;
                root.Background ??= new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0));
                slider.IsThumbToolTipEnabled = false;
                root.PointerPressed += Press; root.PointerMoved += Move;
                root.PointerReleased += Release; root.PointerCanceled += Cancel;
                root.PointerCaptureLost += Lost;
            }
            double Axis(Point p) => slider.Orientation == Orientation.Vertical ? p.Y : p.X;
            double Length => slider.Orientation == Orientation.Vertical ? track!.ActualHeight : track!.ActualWidth;
            double ThumbLength => slider.Orientation == Orientation.Vertical ? thumb!.ActualHeight : thumb!.ActualWidth;
            bool Reversed => slider.Orientation == Orientation.Vertical ^ slider.IsDirectionReversed ^ (slider.Orientation == Orientation.Horizontal && slider.FlowDirection == FlowDirection.RightToLeft);
            void Press(object sender, PointerRoutedEventArgs e)
            {
                e.Handled = true;
                if (surface is null || Length <= ThumbLength || !ReferenceEquals(sender, surface)) return;
                var point = e.GetCurrentPoint(surface);
                var local = point.Position;
                if (local.X < 0 || local.Y < 0 || local.X > surface.ActualWidth || local.Y > surface.ActualHeight) return;
                if (pointer != null || !slider.IsEnabled || !point.Properties.IsLeftButtonPressed && e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse) return;
                if (!surface.CapturePointer(e.Pointer)) return;
                pointer = e.Pointer.PointerId;
                slider.Focus(FocusState.Pointer);
                if (seek) state!.Begin();
                var p = e.GetCurrentPoint(track).Position;
                var onThumb = e.GetCurrentPoint(thumb).Position;
                double a = Axis(onThumb);
                bool hitThumb = onThumb.X >= 0 && onThumb.Y >= 0 && onThumb.X <= thumb!.ActualWidth && onThumb.Y <= thumb.ActualHeight;
                offset = hitThumb ? a - ThumbLength / 2 : 0;
                Set(Axis(p));
                if (state is not null) Access.Call(state.owner, "ShowControlsTemporarily");
            }
            void Move(object sender, PointerRoutedEventArgs e)
            {
                if (pointer != e.Pointer.PointerId || !ReferenceEquals(sender, surface)) return;
                e.Handled = true;
                var point = e.GetCurrentPoint(track);
                if (e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse && !point.Properties.IsLeftButtonPressed)
                {
                    Finish(false);
                    return;
                }
                Set(Axis(point.Position));
            }
            void Set(double axis)
            {
                double span = Length - ThumbLength;
                if (span <= 0 || !double.IsFinite(axis)) return;
                double fraction = Math.Clamp((axis - ThumbLength / 2 - offset) / span, 0, 1);
                if (Reversed) fraction = 1 - fraction;
                double value = slider.Minimum + fraction * (slider.Maximum - slider.Minimum);
                if (slider.StepFrequency > 0) value = slider.Minimum + Math.Round((value - slider.Minimum) / slider.StepFrequency) * slider.StepFrequency;
                slider.Value = Math.Clamp(value, slider.Minimum, slider.Maximum);
            }
            void Release(object sender, PointerRoutedEventArgs e)
            {
                if (pointer != e.Pointer.PointerId || !ReferenceEquals(sender, surface)) return;
                e.Handled = true;
                // The last pressed/moved coordinate owns the value. Release
                // can arrive after the flyout or track has moved.
                Finish(true);
            }
            void Cancel(object sender, PointerRoutedEventArgs e) { if (pointer == e.Pointer.PointerId) Finish(false); }
            void Lost(object sender, PointerRoutedEventArgs e) { if (pointer == e.Pointer.PointerId) Finish(false); }
            internal void Abort() => Finish(false);
            void Finish(bool commit)
            {
                if (pointer == null) return;
                pointer = null; // CaptureLost from our own release must never commit twice.
                surface?.ReleasePointerCaptures();
                if (seek) state!.End(commit);
            }
        }
    }
}

