using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace Yingyu.Update;

internal static class DanmakuToolbarIcon
{
    internal static void Configure(ButtonBase button)
    {
        button.Width=36;
        button.Height=36;
        button.MinWidth=button.MinHeight=0;
        button.Padding=new(0);
        button.BorderThickness=new(0);
        button.Background=DesktopVisuals.Brush(0);
        button.HorizontalContentAlignment=HorizontalAlignment.Center;
        button.VerticalContentAlignment=VerticalAlignment.Center;

        var face=new Canvas{Width=30,Height=27,IsHitTestVisible=false};
        var white=DesktopVisuals.Brush(0xFFFFFFFF);
        face.Children.Add(Outline("M 12,23 H 4 Q 1.5,23 1.5,20.5 V 4 Q 1.5,1.5 4,1.5 H 24 Q 26.5,1.5 26.5,4 V 15",white));
        var label=new TextBlock
        {
            Text=button is ToggleButton?"精":"弹",FontSize=14,FontWeight=Microsoft.UI.Text.FontWeights.Bold,
            FontFamily=new FontFamily("Microsoft YaHei UI"),Foreground=white
        };
        Canvas.SetLeft(label,6.5);
        Canvas.SetTop(label,3);
        face.Children.Add(label);

        if(button is ToggleButton toggle)
        {
            var track=new Border{Width=14,Height=8,CornerRadius=new(4)};
            var thumb=new Ellipse{Width=6,Height=6,Fill=white};
            Canvas.SetLeft(track,16);
            Canvas.SetTop(track,19);
            Canvas.SetTop(thumb,20);
            face.Children.Add(track);
            face.Children.Add(thumb);
            var selected=DesktopVisuals.Brush(0xFFFF651A);
            var normal=DesktopVisuals.Brush(0xFF68686B);
            void Paint()
            {
                bool on=toggle.IsChecked==true;
                track.Background=on?selected:normal;
                Canvas.SetLeft(thumb,on?23:17);
            }
            toggle.RegisterPropertyChangedCallback(ToggleButton.IsCheckedProperty,(_,_)=>Paint());
            Paint();
            foreach(string key in new[]{"ToggleButtonBackgroundChecked","ToggleButtonBackgroundCheckedPointerOver","ToggleButtonBackgroundCheckedPressed","ToggleButtonBackgroundCheckedDisabled"})
                toggle.Resources[key]=DesktopVisuals.Brush(0);
        }
        else
        {
            face.Children.Add(Outline("M 22,18 H 27 L 29.4,22 L 27,26 H 22 L 19.6,22 Z",white));
        }
        button.Content=new Viewbox{Width=28,Height=26,Child=face,IsHitTestVisible=false};
    }

    static Path Outline(string data,Brush stroke)
    {
        var path=(Path)XamlReader.Load($"""<Path xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Data="{data}" />""");
        path.Stroke=stroke;
        path.StrokeThickness=2.35;
        path.StrokeStartLineCap=path.StrokeEndLineCap=PenLineCap.Round;
        path.StrokeLineJoin=PenLineJoin.Round;
        return path;
    }
}
