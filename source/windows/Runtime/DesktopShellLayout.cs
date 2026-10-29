using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

// Changes only the existing shell chrome. No template is replaced, no input
// handler is attached, and all selected/hover colors come from the active palette.
internal static class DesktopShellLayout
{
    const BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
    static T? Find<T>(FrameworkElement page,string name) where T:class
        =>page.GetType().GetField(name,Flags)?.GetValue(page) as T??page.FindName(name) as T;
    internal static void Apply(FrameworkElement page,DesktopThemeOptions options,DesktopThemePalette palette)
    {
        DesktopShellActions.Apply(page,options,palette);
        foreach(string name in new[]{"ShellGrid","SettingsView"})
        {
            if(Find<Grid>(page,name) is not {} grid)continue;
            foreach(var sidebar in grid.Children.OfType<Border>().Where(border=>Grid.GetColumn(border)==0&&border.Name!="DesktopAccountToolbar"))
            {
                sidebar.Margin=new Thickness(0);sidebar.CornerRadius=new CornerRadius(0);
                sidebar.BorderThickness=new Thickness(0,0,1,0);
                sidebar.BorderBrush=DesktopVisuals.Brush(palette.Outline);sidebar.Background=DesktopMaterial.Surface(options,palette);
                if(name!="SettingsView")continue;
                foreach(var button in UiElements.Descendants(sidebar).OfType<Button>())
                {
                    if(button.Tag is not string target||!target.EndsWith("SettingsSection",StringComparison.Ordinal)||Find<FrameworkElement>(page,target) is not {} section)continue;
                    bool selected=!LogCenterLauncher.IsActive(page)&&section.Visibility==Visibility.Visible;
                    button.CornerRadius=new CornerRadius(Math.Min(options.Radius,10));button.BorderThickness=new Thickness(3,0,0,0);button.BorderBrush=DesktopVisuals.Brush(selected?palette.Accent:0x00000000);
                    button.Background=DesktopVisuals.Brush(selected?palette.Selection:0x00000000);button.Foreground=DesktopVisuals.Brush(palette.Text);
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(button,selected?"当前位置":"");
                    button.Height=38;button.MinHeight=38;button.Padding=new Thickness(12,7,12,7);button.FontSize=14;
                    button.Resources["ButtonBackgroundPointerOver"]=DesktopVisuals.Brush(palette.Hover);
                    button.Resources["ButtonBackgroundPressed"]=DesktopVisuals.Brush(palette.Selection);
                    foreach(string key in new[]{"ButtonForeground","ButtonForegroundPointerOver","ButtonForegroundPressed"})button.Resources[key]=DesktopVisuals.Brush(palette.Text);
                }
            }
        }
    }
}
