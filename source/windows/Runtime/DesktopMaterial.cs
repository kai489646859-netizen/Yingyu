using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
namespace Yingyu.Update;

// Local XAML material only. Film pixels and subtitle composition are untouched.
public static class DesktopMaterial
{
    public static Color Color(uint c)=>Windows.UI.Color.FromArgb((byte)(c>>24),(byte)(c>>16),(byte)(c>>8),(byte)c);
    public static Brush Surface(DesktopThemeOptions options,DesktopThemePalette p,bool player=false)
    {
        uint color=player?0xFF191B21:p.Sidebar;
        return new SolidColorBrush(Color(color));
    }
    public static Brush Atmosphere(DesktopThemeOptions options,DesktopThemePalette p)
    {
        // An opaque theme-derived wash joins the desktop surfaces without a
        // bitmap, timer, network request or composition effect. Accessibility
        // and reduced-transparency preferences retain a plain opaque surface.
        if(p.Background==p.Surface&&p.Accent==p.Text)return new SolidColorBrush(Color(p.Background));
        var brush=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(1,0)};
        if((p.Background&0x00FFFFFF)>0x808080)
        {
            foreach(var stop in new[]{(0d,0xFFFFFBF9u),(.08,0xFFF4FAFFu),(.25,0xFFF8F6FFu),(.62,0xFFF8F6FFu),(.82,0xFFF4F9FDu),(1d,0xFFFFF6FBu)})
                brush.GradientStops.Add(new(){Offset=stop.Item1,Color=Color(Mix(stop.Item2,p.Accent,.065))});
            return brush;
        }
        brush.GradientStops.Add(new(){Offset=0,Color=Color(Mix(0xFF151923,p.Accent,.12))});
        brush.GradientStops.Add(new(){Offset=.48,Color=Color(Mix(0xFF151923,p.Accent,.025))});
        brush.GradientStops.Add(new(){Offset=1,Color=Color(Mix(0xFF151923,p.Accent,.065))});
        return brush;
    }
    internal static uint Mix(uint background,uint foreground,double amount)
    {
        uint Channel(int shift)=>(uint)Math.Round(((background>>shift)&255)*(1-amount)+((foreground>>shift)&255)*amount);
        return 0xFF000000|Channel(16)<<16|Channel(8)<<8|Channel(0);
    }
}
