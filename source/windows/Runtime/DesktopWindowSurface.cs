using System.Reflection;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

// One native XAML background spans the existing main-window title and client.
// Keep the original TitleBar control, drag regions and OS caption buttons.
internal static class DesktopWindowSurface
{
    sealed class State { internal Brush? Brush;internal DesktopThemeOptions? Options;internal DesktopThemePalette Palette; }
    static readonly ConditionalWeakTable<Grid,State> Windows=new();
    static readonly SolidColorBrush Clear=DesktopVisuals.Brush(0);
    internal static void Apply(FrameworkElement page,DesktopThemePalette palette)
    {
        const BindingFlags flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
        FieldInfo? field=null;for(Type? type=Application.Current.GetType();type!=null&&field==null;type=type.BaseType)field=type.GetField("_window",flags);
        if(field?.GetValue(Application.Current) is not Window window
            ||window.GetType().FullName!="EmbyDesktop.MainWindow"||window.Content is not Grid root||page.XamlRoot==null)return;
        bool owned=false;for(DependencyObject? node=page;node!=null;node=VisualTreeHelper.GetParent(node))if(ReferenceEquals(node,root)){owned=true;break;}
        if(!owned)return;
        var state=Windows.GetOrCreateValue(root);var options=DesktopTheme.Options;
        if(state.Brush==null||state.Options!=options||state.Palette!=palette)
        {state.Brush=DesktopMaterial.Atmosphere(options,palette);state.Options=options;state.Palette=palette;}
        root.Background=state.Brush;
        root.RequestedTheme=page.RequestedTheme;
        DesktopWindowFoundation.Apply(window,root,state.Brush!,palette.Background==palette.Surface&&palette.Accent==palette.Text,palette.Background==palette.Surface&&palette.Accent==palette.Text);
        if(page is Control control){control.Background=Clear;control.BorderThickness=new(0);}
        foreach(var frame in root.Children.OfType<Frame>())frame.Background=Clear;
        if(window.GetType().GetField("AppTitleBar",flags)?.GetValue(window) is Control bar)
        {
            for(DependencyObject? node=bar;node!=null&&!ReferenceEquals(node,root);node=VisualTreeHelper.GetParent(node))
            {
                if(node is Control title)title.Background=Clear;
                if(node is Panel panel)
                {
                    panel.Background=Clear;
                    // The XBF bottom rule is a sibling of AppTitleBar in its
                    // wrapper, rather than part of the TitleBar template.
                    foreach(var rule in panel.Children.OfType<Border>())
                        if(rule.BorderThickness.Left==0&&rule.BorderThickness.Top==0&&rule.BorderThickness.Right==0&&rule.BorderThickness.Bottom>0)
                        {rule.BorderThickness=new(0);rule.Background=Clear;}
                }
                if(node is Border border){border.Background=Clear;border.BorderThickness=new(0);}
            }
        }
        foreach(string name in new[]{"ShellGrid","LibraryView","CollectionView","SettingsView","LibraryHeaderGrid"})
            if(page.GetType().GetField(name,flags)?.GetValue(page) is Grid grid)
            {
                if(name!="SettingsView")grid.Background=Clear;
                if(name=="ShellGrid")
                    foreach(var layer in grid.Children.OfType<FrameworkElement>().Where(e=>e.Name is "ReferenceAtmosphere" or "ReferenceWallpaperSource"))layer.Visibility=Visibility.Collapsed;
                if(name is "ShellGrid" or "SettingsView")
                    foreach(var border in grid.Children.OfType<Border>().Where(b=>Grid.GetColumn(b)==0||b.Name=="DesktopAccountToolbar"))
                    {border.Background=Clear;border.BorderThickness=new(0);}
            }
    }
}
