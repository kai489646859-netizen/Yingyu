using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
namespace Yingyu.Update;

// Layout-only repair for realized chrome. No LayoutUpdated/render loop, input
// handlers, data requests, image identities or video surface changes.
internal static class DesktopContentBounds
{
    static int warnings;
    sealed record OriginalMargin(Thickness Value);
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<FrameworkElement,OriginalMargin> ExitMargins=new();
    internal static void Apply(DependencyObject root)
    {
        try
        {
            var nodes=new[]{root}.Concat(UiElements.Descendants(root)).Distinct().ToArray();
            foreach(var icon in nodes.OfType<FontIcon>())
            {
                icon.IsTextScaleFactorEnabled=false;
                icon.Width=icon.Height=double.NaN;icon.MinWidth=icon.MinHeight=0;
                icon.MaxWidth=icon.MaxHeight=double.PositiveInfinity;icon.Margin=new(0);icon.Clip=null;
                icon.HorizontalAlignment=HorizontalAlignment.Center;icon.VerticalAlignment=VerticalAlignment.Center;
            }
            foreach(var button in nodes.OfType<Button>())
            {
                if(!DesktopCardSurface.Owns(button)&&(button.Name is "CloseSettingsButton" or "HistoryBackButton" or "CollectionBackButton"
                    ||button.Content?.ToString() is "返回首页" or "返回主页"||UiElements.Descendants(button).OfType<TextBlock>().Any(t=>t.Text is "返回首页" or "返回主页")))
                {
                    if(button.Content is not FontIcon{Glyph:"\uE8BB"})button.Content=new FontIcon{Glyph="\uE8BB",FontSize=20,IsTextScaleFactorEnabled=false};
                    button.Width=button.Height=button.MinWidth=button.MinHeight=40;button.HorizontalAlignment=HorizontalAlignment.Right;
                    button.Margin=new(0,button.Margin.Top,12,button.Margin.Bottom);
                    if(VisualTreeHelper.GetParent(button) is Grid header)
                    {
                        int row=Grid.GetRow(button);Grid.SetColumn(button,0);Grid.SetColumnSpan(button,Math.Max(1,header.ColumnDefinitions.Count));
                        foreach(var sibling in header.Children.OfType<FrameworkElement>().Where(e=>e!=button&&Grid.GetRow(e)==row&&Grid.GetColumn(e)==0))
                        {var margin=ExitMargins.GetValue(sibling,e=>new(e.Margin)).Value;sibling.Margin=new(margin.Left,margin.Top,margin.Right+52,margin.Bottom);}
                    }
                    DesktopCloseButton.Apply(button,ReferenceSurfaces.Palette(button));
                    ToolTipService.SetToolTip(button,"关闭当前页面");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,"关闭当前页面");
                }
                if(button.Content is IconElement icon)
                {
                    button.Padding=new(0);button.HorizontalContentAlignment=HorizontalAlignment.Center;button.VerticalContentAlignment=VerticalAlignment.Center;
                    if(icon is FontIcon glyph&&double.IsFinite(button.Width)&&double.IsFinite(button.Height))
                        glyph.FontSize=Math.Min(glyph.FontSize,Math.Max(12,Math.Min(button.Width,button.Height)-12));
                }
            }
            foreach(var text in nodes.OfType<TextBlock>().Where(t=>t.FontSize>=18&&!DesktopCardSurface.Owns(t)))Heading(text);
        }
        catch(Exception error){if(System.Threading.Interlocked.Increment(ref warnings)<=4)try{PlaybackTransport.Write("Warning","Desktop.Bounds","图标或标题边界未完全应用；"+error.GetType().Name);}catch(Exception){}}
    }
    internal static void Heading(TextBlock text)
    {
        text.TextLineBounds=TextLineBounds.Full;text.LineStackingStrategy=LineStackingStrategy.MaxHeight;
        text.LineHeight=0;text.OpticalMarginAlignment=OpticalMarginAlignment.None;
        text.Height=double.NaN;text.MaxHeight=double.PositiveInfinity;
        text.Padding=new(2,2,2,3);text.Clip=null;
    }
}
