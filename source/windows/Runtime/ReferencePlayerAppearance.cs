using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
namespace Yingyu.Update;

// Styling only: the original transport buttons, sliders, hover flyouts and all
// event handlers stay attached. There are no mpv calls or shortcut changes here.
internal static class ReferencePlayerAppearance
{
    static readonly ConditionalWeakTable<object,State> States=new();
    internal static void Apply(object overlay)=>States.GetValue(overlay,o=>new State(o)).Apply();
    sealed class State
    {
        readonly object owner;readonly FrameworkElement element;readonly Grid chrome;
        Grid? controls;TextBlock title;bool moved;
        internal State(object owner){this.owner=owner;element=(FrameworkElement)owner;chrome=Access.Get<Grid>(owner,"ChromeLayer");title=Access.Get<TextBlock>(owner,"TitleText");}
        static SolidColorBrush Brush(uint color)=>DesktopVisuals.Brush(color);
        internal void Apply()
        {
            var position=Access.Get<Slider>(owner,"PositionSlider");
            if(!moved)
            {
                controls=UiElements.Descendants(chrome).OfType<Grid>().FirstOrDefault(g=>g.RowDefinitions.Count>=2&&UiElements.Descendants(g).Contains(position)&&!ReferenceEquals(g,chrome));
                if(controls!=null)
                {
                    controls.RowDefinitions.Insert(0,new(){Height=GridLength.Auto});foreach(var child in controls.Children.OfType<FrameworkElement>())Grid.SetRow(child,Grid.GetRow(child)+1);
                    if(DesktopShellActions.Detach(chrome,title)){Grid.SetRow(title,0);Grid.SetColumn(title,0);Grid.SetColumnSpan(title,Math.Max(1,controls.ColumnDefinitions.Count));controls.Children.Add(title);}
                    moved=true;
                }
            }
            if(controls!=null){controls.Margin=new(Math.Clamp(element.ActualWidth*.025,24,48),0,Math.Clamp(element.ActualWidth*.025,24,48),42);controls.RowSpacing=8;}
            title.HorizontalAlignment=HorizontalAlignment.Left;title.TextAlignment=TextAlignment.Left;title.FontSize=22;title.FontWeight=Microsoft.UI.Text.FontWeights.Bold;title.Foreground=Brush(0xFFFFFFFF);title.Margin=new(0,0,0,12);title.MaxWidth=Math.Max(200,element.ActualWidth-96);
            foreach(string name in new[]{"PositionText","DurationText"}){var text=Access.Get<TextBlock>(owner,name);text.FontSize=18;text.Foreground=Brush(0xFFFFFFFF);}
            foreach(var slider in new[]{position,Access.Get<Slider>(owner,"VolumeSlider")})foreach(string key in new[]{"SliderTrackValueFill","SliderTrackValueFillPointerOver","SliderTrackValueFillPressed","SliderThumbBackground","SliderThumbBackgroundPointerOver","SliderThumbBackgroundPressed"})slider.Resources[key]=Brush(0xEEFFFFFF);
            position.Foreground=Brush(0xEEFFFFFF);position.Background=Brush(0x55FFFFFF);
            foreach(var button in UiElements.Descendants(chrome).OfType<Button>())
            {
                if(button.Name=="PlayerMediaInfoButton")continue;
                button.Background=Brush(0);button.BorderThickness=new(0);button.Foreground=Brush(0xFFFFFFFF);button.Height=44;button.MinHeight=44;button.MinWidth=44;if(double.IsFinite(button.Width)&&button.Width<44)button.Width=44;button.Padding=new(10);button.CornerRadius=new(22);
                foreach(var icon in UiElements.Descendants(button).OfType<FontIcon>()){icon.FontSize=22;icon.Foreground=Brush(0xFFFFFFFF);}
                button.Resources["ButtonBackgroundPointerOver"]=Brush(0x18FFFFFF);button.Resources["ButtonBackgroundPressed"]=Brush(0x28FFFFFF);
            }
            // Preserve visible speed/track labels: their content carries actual
            // state. Their original hover-only templates remain in use.
            foreach(var band in chrome.Children.OfType<Border>().Where(b=>b.Background is LinearGradientBrush))
            {
                bool bottom=band.VerticalAlignment==VerticalAlignment.Bottom;band.Height=bottom?250:110;
                var gradient=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(0,1)};
                gradient.GradientStops.Add(new(){Offset=0,Color=DesktopMaterial.Color(bottom?0x00000000u:0x55000000u)});gradient.GradientStops.Add(new(){Offset=1,Color=DesktopMaterial.Color(bottom?0x77000000u:0x00000000u)});band.Background=gradient;
            }
        }
    }
}
