using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
namespace Yingyu.Update;

internal static class DesktopCloseButton
{
    static ControlTemplate? template;
    internal static void Apply(Button button,DesktopThemePalette palette)
    {
        // The inherited detail action style enforces 88/116 DIP minimum widths.
        // Reset the complete geometry so a nominally round button stays round.
        button.Template=template??=(ControlTemplate)XamlReader.Load(DesktopVisuals.ActionXaml);
        button.Width=button.Height=button.MinWidth=button.MinHeight=button.MaxWidth=button.MaxHeight=40;
        button.Padding=new(0);button.CornerRadius=new(20);button.BorderThickness=new(0);
        button.Background=DesktopVisuals.Brush(palette.Surface);button.Foreground=DesktopVisuals.Brush(palette.Text);
        button.HorizontalContentAlignment=HorizontalAlignment.Center;button.VerticalContentAlignment=VerticalAlignment.Center;
        if(button.Content is not FontIcon{Glyph:"\uE8BB"})button.Content=new FontIcon{Glyph="\uE8BB"};
        if(button.Content is FontIcon icon){icon.FontSize=16;icon.IsTextScaleFactorEnabled=false;icon.Foreground=DesktopVisuals.Brush(palette.Text);icon.Margin=new(0);icon.HorizontalAlignment=HorizontalAlignment.Center;icon.VerticalAlignment=VerticalAlignment.Center;}
    }
}
