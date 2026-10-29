using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

// One handled-input observer per visual root, checking only currently hovered
// surfaces. Child exits can carry the old in-bounds point after layout/capture.
internal static class PosterPointerScope
{
    static readonly ConditionalWeakTable<UIElement, Scope> Scopes = new();
    internal static void Watch(FrameworkElement target, Action leave) => _ = new Entry(target, leave);
    sealed class Entry
    {
        internal readonly FrameworkElement Target;
        readonly Action leave;
        Scope? scope;
        internal Entry(FrameworkElement target, Action leave)
        {
            Target = target; this.leave = leave;
            target.Loaded += (_, _) => Attach();
            target.Unloaded += (_, _) => { Leave(); scope = null; };
            target.DataContextChanged += (_, _) => Leave();
            target.AddHandler(UIElement.PointerEnteredEvent, new PointerEventHandler((_, e) =>
            {
                if (e.Pointer.PointerDeviceType != Microsoft.UI.Input.PointerDeviceType.Mouse) return;
                if (scope == null) Attach();
                scope?.Active.Add(this);
            }), true);
            if (target.IsLoaded) Attach();
        }
        void Attach()
        {
            DependencyObject root = Target;
            while (VisualTreeHelper.GetParent(root) is {} parent) root = parent;
            if (root is UIElement ui) scope = Scopes.GetValue(ui, x => new Scope(x));
        }
        internal void Leave() { scope?.Active.Remove(this); leave(); }
        internal bool Contains(PointerRoutedEventArgs e)
        {
            if (!Target.IsLoaded || Target.Visibility != Visibility.Visible) return false;
            // The actual event source resolves sibling surfaces and overlays even
            // when an exit reports the last point inside the old card.
            bool descendant = false;
            for (DependencyObject? node = e.OriginalSource as DependencyObject; node != null; node = VisualTreeHelper.GetParent(node))
                if (ReferenceEquals(node, Target)) { descendant = true; break; }
            if (!descendant) return false;
            var p = e.GetCurrentPoint(Target).Position;
            return p.X >= 0 && p.Y >= 0 && p.X < Target.ActualWidth && p.Y < Target.ActualHeight;
        }
    }
    sealed class Scope
    {
        internal readonly HashSet<Entry> Active = new();
        internal Scope(UIElement root)
        {
            root.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(Check), true);
            root.AddHandler(UIElement.PointerExitedEvent, new PointerEventHandler(Check), true);
            root.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler((_, _) => Clear()), true);
        }
        void Check(object sender, PointerRoutedEventArgs e)
        {
            foreach (var entry in Active.ToArray())
                try { if (!entry.Contains(e)) entry.Leave(); }
                catch (Exception) { try { entry.Leave(); } catch (Exception) { Active.Remove(entry); } }
        }
        void Clear() { foreach (var entry in Active.ToArray()) try { entry.Leave(); } catch (Exception) { Active.Remove(entry); } }
    }
}
