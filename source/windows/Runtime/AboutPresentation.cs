using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Yingyu.Update;

internal static class AboutPresentation
{
    sealed class State
    {
        internal readonly StackPanel Body=new(){Spacing=20};
        internal readonly TextBlock Version=new(){FontSize=14};
        internal readonly TextBlock PathText=new(){FontSize=13,TextWrapping=TextWrapping.Wrap};
        internal readonly Border Card=new(){CornerRadius=new(14),Padding=new(24),BorderThickness=new(1)};
        internal State(){
            var header=new StackPanel{Orientation=Orientation.Horizontal,Spacing=18};
            header.Children.Add(new Image{Width=56,Height=56,Source=new BitmapImage(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory,"Assets","AppIconSource.png")))});
            var title=new StackPanel{Spacing=5};title.Children.Add(new TextBlock{Text="映屿",FontSize=28,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold});title.Children.Add(Version);header.Children.Add(title);Body.Children.Add(header);
            var content=new StackPanel{Spacing=12};
            content.Children.Add(new TextBlock{Text="你的私人影院",FontSize=20,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold});
            content.Children.Add(new TextBlock{Text="连接 Emby 媒体库，整理片单，继续观看。",FontSize=15,TextWrapping=TextWrapping.Wrap});
            content.Children.Add(new TextBlock{Text="个人数据",FontSize=15,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,Margin=new(0,8,0,0)});
            content.Children.Add(new TextBlock{Text="账号、设置与观看记录保存在本机，覆盖更新时保留。海报优先读取已有缓存。",FontSize=14,TextWrapping=TextWrapping.Wrap});
            content.Children.Add(PathText);Card.Child=content;Body.Children.Add(Card);
        }
    }
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    internal static void Apply(FrameworkElement page,DesktopThemePalette palette){
        if(Access.Get<object?>(page,"AboutSettingsSection") is not Border section)return;
        var state=States.GetValue(page,_=>new());
        if(!ReferenceEquals(section.Child,state.Body))section.Child=state.Body;
        section.MaxWidth=760;
        var version=page.GetType().Assembly.GetName().Version;state.Version.Text=$"版本 {version?.Major}.{version?.Minor}.{version?.Build}";
        state.PathText.Text="数据目录："+CachePaths.UserDataRoot+"\n缓存目录："+CachePaths.CacheRoot;
        state.Card.Background=DesktopVisuals.Brush(palette.Surface);state.Card.BorderBrush=DesktopVisuals.Brush(palette.Outline);
        foreach(var text in UiElements.Descendants(state.Body).OfType<TextBlock>())text.Foreground=DesktopVisuals.Brush(text.FontSize>=15?palette.Text:palette.Secondary);
        // Settings' save footer does not describe the read-only About page.
        if(Access.Get<object?>(page,"SettingsView") is FrameworkElement settings)
            foreach(var text in UiElements.Descendants(settings).OfType<TextBlock>().Where(t=>t.Text=="设置会自动保存。"))text.Visibility=section.Visibility==Visibility.Visible?Visibility.Collapsed:Visibility.Visible;
    }
}
