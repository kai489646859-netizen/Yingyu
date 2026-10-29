using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Markup;

namespace Yingyu.Update;

// Pointer presentation and settings input only; no selection or persistence writes.
public static class DesktopInputBehavior
{
    static readonly ConditionalWeakTable<FrameworkElement, object> Roots = new();
    static readonly ConditionalWeakTable<Control, object> Options = new();
    static readonly ConditionalWeakTable<UIElement, object> WheelTargets = new();
    static readonly ConditionalWeakTable<PointerRoutedEventArgs, object> WheelEvents = new();
    sealed class ToolbarState { internal readonly SolidColorBrush Hover = new(); internal readonly SolidColorBrush Pressed = new(); }
    static readonly ConditionalWeakTable<Button, ToolbarState> ToolbarButtons = new();
    static readonly ConditionalWeakTable<ScrollViewer, ScrollIntent> Scrolls = new();
    sealed class ScrollIntent { internal long Tick; internal double Target; }
    static bool tooltipStyleReady;

    // Both host and adapter tooltip call sites route here. Keep existing
    // AutomationProperties names; tooltip presentation is explicitly unwanted.
    public static void SetToolTip(DependencyObject target, object? ignored)
    {
        if (ToolTipService.GetToolTip(target) is ToolTip tip) tip.IsOpen = false;
        ToolTipService.SetToolTip(target, null);
    }

    internal static void Apply(FrameworkElement root)
    {
        if (!tooltipStyleReady)
        {
            var resources = Application.Current.Resources;
            var style = new Style(typeof(ToolTip));
            if (resources.ContainsKey(typeof(ToolTip)) && resources[typeof(ToolTip)] is Style existing) style.BasedOn = existing;
            style.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Collapsed));
            resources[typeof(ToolTip)] = style;
            tooltipStyleReady = true;
        }
        if (!Roots.TryGetValue(root, out _))
        {
            Roots.Add(root, new());
            root.Loaded += (_, _) => Scan(root);
            Scan(root);
            root.AddHandler(UIElement.PointerEnteredEvent, new PointerEventHandler(Pointer), true);

        }
    }
    static void Scan(FrameworkElement root)
    {
        Clear(root);
        foreach (var node in UiElements.Descendants(root)) Clear(node);
    }
    static void Clear(DependencyObject node)
    {
        if (ToolTipService.GetToolTip(node) != null) SetToolTip(node, null);
        if (node is Control control && control is ComboBox or NumberBox or Slider && !Options.TryGetValue(control,out _) && InSettings(control)) Guard(control);
    }
    static void Pointer(object sender, PointerRoutedEventArgs e)
    {
        for (var node = e.OriginalSource as DependencyObject; node != null; node = VisualTreeHelper.GetParent(node)) Clear(node);
    }
    static bool InSettings(DependencyObject node)
    {
        for (DependencyObject? item = node; item != null; item = VisualTreeHelper.GetParent(item))
            if (item is FrameworkElement { Name: "SettingsView" }) return true;
        return false;
    }
    static void Guard(Control control)
    {
        if (!Options.TryGetValue(control, out _))
        {
            Options.Add(control, new());
            control.Loaded += (_, _) => HookTemplate(control);
            control.RegisterPropertyChangedCallback(Control.TemplateProperty, (_, _) => control.DispatcherQueue.TryEnqueue(() => HookTemplate(control)));
        }
        HookTemplate(control);
    }
    static void HookTemplate(Control control)
    {
        // The child receives the routed event BEFORE the option's native class
        // handler. Handling it on the option/page itself would be too late.
        foreach (var child in UiElements.Descendants(control).OfType<UIElement>())
        {
            if (WheelTargets.TryGetValue(child, out _)) continue;
            WheelTargets.Add(child, new());
            child.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler((_, e) => Wheel(control, e)), true);
        }
    }
    static void Wheel(Control control, PointerRoutedEventArgs e)
    {
        if (!InSettings(control) || WheelEvents.TryGetValue(e, out _)) return;
        WheelEvents.Add(e, new());
        var point = e.GetCurrentPoint(control).Properties;
        e.Handled = true;
        if (point.IsHorizontalMouseWheel) return;
        ScrollViewer? outer = null;
        for (var node = VisualTreeHelper.GetParent(control); node != null; node = VisualTreeHelper.GetParent(node))
            if (node is ScrollViewer scroll) { outer = scroll; break; }
        if (outer == null || outer.ScrollableHeight <= 0) return;
        uint lines = 3; SystemParametersInfo(0x0068, 0, ref lines, 0);
        double distance = lines == uint.MaxValue ? outer.ViewportHeight : lines * 16;
        var intent = Scrolls.GetValue(outer, _ => new());
        long now = Environment.TickCount64;
        if (now - intent.Tick > 350) intent.Target = outer.VerticalOffset;
        intent.Tick = now;
        intent.Target = Math.Clamp(intent.Target - point.MouseWheelDelta / 120d * distance, 0, outer.ScrollableHeight);
        outer.ChangeView(null, intent.Target, null, DesktopTheme.Options.ReducedMotion);
    }
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint parameter, ref uint value, uint flags);

    internal static void Toolbar(Button button)
    {
        bool attached = ToolbarButtons.TryGetValue(button, out var state);
        state ??= ToolbarButtons.GetValue(button, _ => new());
        var palette = ReferenceSurfaces.Palette(button);
        state.Hover.Color = DesktopMaterial.Color(palette.Hover);
        state.Pressed.Color = DesktopMaterial.Color(palette.Selection);
        void PaintSurface(){var surface=UiElements.Descendants(button).OfType<Border>().FirstOrDefault(b=>b.Name=="ToolbarHoverSurface");if(surface!=null&&!ReferenceEquals(surface.Background,state.Hover))surface.Background=state.Hover;}
        if (attached) { PaintSurface(); return; }
        button.Resources["DesktopToolbarHoverBrush"] = state.Hover;
        button.Resources["DesktopToolbarPressedBrush"] = state.Pressed;
        button.CornerRadius = new(20);
        var toolbarTemplate = (ControlTemplate)XamlReader.Load("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
              <Grid x:Name="ToolbarIconChrome" Background="{TemplateBinding Background}">
                <VisualStateManager.VisualStateGroups><VisualStateGroup x:Name="CommonStates">
                  <VisualState x:Name="Normal"/>
                  <VisualState x:Name="PointerOver"><VisualState.Setters><Setter Target="ToolbarHoverSurface.Opacity" Value="1"/></VisualState.Setters></VisualState>
                  <VisualState x:Name="Pressed"><VisualState.Setters><Setter Target="ToolbarHoverSurface.Opacity" Value="1"/><Setter Target="ToolbarContent.Opacity" Value="0.65"/></VisualState.Setters></VisualState>
                  <VisualState x:Name="Disabled"><VisualState.Setters><Setter Target="ToolbarContent.Opacity" Value="0.4"/></VisualState.Setters></VisualState>
                </VisualStateGroup></VisualStateManager.VisualStateGroups>
                <Border x:Name="ToolbarHoverSurface" CornerRadius="{TemplateBinding CornerRadius}" Background="ToolbarHoverColor" Opacity="0" IsHitTestVisible="False"/>
                <ContentPresenter x:Name="ToolbarContent" Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" Padding="{TemplateBinding Padding}" HorizontalContentAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalContentAlignment="{TemplateBinding VerticalContentAlignment}" Foreground="{TemplateBinding Foreground}"/>
              </Grid>
            </ControlTemplate>
            """.Replace("ToolbarHoverColor",state.Hover.Color.ToString()));
        button.Template = toolbarTemplate;
        button.UseSystemFocusVisuals = true;
        button.Loaded += (_, _) => PaintSurface();
        if(button.IsLoaded)button.ApplyTemplate();
        PaintSurface();

    }
}
