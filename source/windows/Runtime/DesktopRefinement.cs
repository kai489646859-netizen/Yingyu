using System.Reflection;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

// Presentation only. Original controls, handlers, data sources, navigation and
// loading rules remain owned by the host. Never touches the player surface.
internal static class DesktopRefinement
{
    const BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
    static readonly ConditionalWeakTable<FrameworkElement,State> Pages=new();
    static T? Find<T>(FrameworkElement page,string name) where T:class
        =>page.GetType().GetField(name,Flags)?.GetValue(page) as T??page.FindName(name) as T;
    internal static void Apply(FrameworkElement page,DesktopThemePalette palette,bool reference,bool detail,bool settings)
        =>Pages.GetValue(page,_=>new State()).Apply(page,palette,reference,detail,settings);
    sealed class State
    {
        DesktopThemePalette palette;DesktopThemeOptions? options;
        Brush? atmosphere,header;readonly SolidColorBrush clear=DesktopVisuals.Brush(0);
        bool duplicateTitleHidden;
        Button? browseSearch;
        void BrowseHeader(FrameworkElement page,DesktopThemePalette p,bool reference,bool detail,bool settings)
        {
            if(Find<Grid>(page,"LibraryHeaderGrid") is not {} top)return;
            if(browseSearch==null)
            {
                browseSearch=new Button{Name="DesktopBrowseSearch",HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch};
                var line=new Grid{ColumnSpacing=10};line.ColumnDefinitions.Add(new(){Width=GridLength.Auto});line.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
                line.Children.Add(new FontIcon{Glyph="\uE721",FontSize=20,VerticalAlignment=VerticalAlignment.Center});
                var text=new TextBlock{Text="搜索片名或演员",FontSize=15,VerticalAlignment=VerticalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis};Grid.SetColumn(text,1);line.Children.Add(text);browseSearch.Content=line;
                browseSearch.Click+=(_,_)=>ReferenceAppearance.FocusSearch(page);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(browseSearch,"搜索片名或演员");
                while(top.RowDefinitions.Count<2)top.RowDefinitions.Add(new(){Height=GridLength.Auto});
                Grid.SetRow(browseSearch,1);Grid.SetColumnSpan(browseSearch,Math.Max(1,top.ColumnDefinitions.Count));top.Children.Add(browseSearch);
                top.SizeChanged+=(_,_)=>{try{if(browseSearch.Visibility==Visibility.Visible)BrowseHeader(page,palette,false,false,false);}catch(Exception error){try{PlaybackTransport.Write("Warning","Desktop.Layout","搜索行布局未完成；"+error.GetType().Name);}catch(Exception){}}};
            }
            browseSearch.Visibility=Access.Get<object?>(page,"_activeNavigation")?.ToString()=="Home"||reference||detail||settings||ReferenceAppearance.UsesInlineSearch(page)?Visibility.Collapsed:Visibility.Visible;
            if(reference||detail||settings)return;
            browseSearch.Height=44;browseSearch.Margin=new(0,16,0,4);browseSearch.Padding=new(14,0,14,0);browseSearch.CornerRadius=new(12);
            DesktopReadability.Search(browseSearch,p);
            if(browseSearch.Content is Grid searchLine)foreach(var child in searchLine.Children){if(child is TextBlock text)text.Foreground=DesktopVisuals.Brush(p.Secondary);if(child is FontIcon icon)icon.Foreground=DesktopVisuals.Brush(p.Accent);}
            if(top.ColumnDefinitions.Count>1)top.ColumnDefinitions[1].Width=new(1,GridUnitType.Star);
            if(Find<StackPanel>(page,"LibraryHeaderTitle") is {} title){Grid.SetRow(title,0);Grid.SetColumn(title,0);Grid.SetColumnSpan(title,2);}
            if(Find<Button>(page,"GlobalRefreshButton") is {} refresh){Grid.SetRow(refresh,0);Grid.SetColumn(refresh,Math.Min(2,Math.Max(0,top.ColumnDefinitions.Count-1)));refresh.Width=40;refresh.Height=40;refresh.MinWidth=refresh.MinHeight=40;refresh.Padding=new(0);refresh.BorderThickness=new(0);refresh.Foreground=DesktopVisuals.Brush(p.Accent);if(refresh.Content is not FontIcon{Glyph:"\uE72C"})refresh.Content=new FontIcon{Glyph="\uE72C",FontSize=22};if(refresh.Content is FontIcon glyph)glyph.Foreground=DesktopVisuals.Brush(p.Accent);}
        }
        void Brushes(DesktopThemePalette p)
        {
            var current=DesktopTheme.Options;
            if(atmosphere!=null&&palette==p&&options==current)return;
            palette=p;options=current;atmosphere=DesktopMaterial.Atmosphere(current,p);
            if(p.Background==p.Surface&&p.Accent==p.Text)
                header=DesktopMaterial.Surface(current,p);
            else
            {
                var gradient=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(1,0)};
                gradient.GradientStops.Add(new(){Offset=0,Color=DesktopMaterial.Color(p.Sidebar)});
                gradient.GradientStops.Add(new(){Offset=.65,Color=DesktopMaterial.Color(DesktopMaterial.Mix(p.Background,p.Accent,.14))});
                gradient.GradientStops.Add(new(){Offset=1,Color=DesktopMaterial.Color(DesktopMaterial.Mix(p.Background,p.Accent,.04))});
                header=gradient;
            }
        }
        internal void Apply(FrameworkElement page,DesktopThemePalette p,bool reference,bool detail,bool settings)
        {
            // DesktopTheme publishes the system high-contrast colors into its
            // owned resources. Respect that effective palette at this last
            // presentation pass as well as at the original theme pass.
            var resources=Application.Current.Resources;
            if(resources.ContainsKey("AppBackgroundBrush")&&resources["AppBackgroundBrush"] is SolidColorBrush bg
                &&resources.ContainsKey("PrimaryTextBrush")&&resources["PrimaryTextBrush"] is SolidColorBrush fg)
            {
                uint Value(Windows.UI.Color c)=>(uint)c.A<<24|(uint)c.R<<16|(uint)c.G<<8|c.B;
                uint background=Value(bg.Color),text=Value(fg.Color);
                if(background!=p.Background&&text!=p.Text)p=new(background,background,background,text,text,text,text,background,background);
            }
            PlayerInfoData.Remember(page);
            Brushes(p);BrowseHeader(page,p,reference,detail,settings);
            if(Find<Grid>(page,"ShellGrid") is {} shell)
            {
                shell.Background=atmosphere;
                foreach(var name in new[]{"LibraryView","CollectionView"})
                    if(Find<Grid>(page,name) is {} view)view.Background=clear;
                // Settings overlays the browse view; it needs its own opaque
                // wash so the underlying cards cannot show through.
                if(Find<Grid>(page,"SettingsView") is {} settingsView)settingsView.Background=atmosphere;
                if(!detail&&shell.Children.OfType<Border>().FirstOrDefault(b=>b.Name=="DesktopAccountToolbar") is {} bar)
                {bar.Background=header;bar.MinHeight=54;bar.Padding=new(20,4,24,4);}
                if(!reference&&!detail&&!settings&&Find<Button>(page,"SettingsButton") is {} settingsButton)
                {
                    settingsButton.Width=settingsButton.Height=40;settingsButton.MinWidth=settingsButton.MinHeight=40;settingsButton.Padding=new(0);
                    if(settingsButton.Content is not FontIcon{Glyph:"\uE713"})settingsButton.Content=new FontIcon{Glyph="\uE713",FontSize=22};
                    if(settingsButton.Content is FontIcon icon)icon.Foreground=DesktopVisuals.Brush(p.Accent);
                    ToolTipService.SetToolTip(settingsButton,"设置");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(settingsButton,"设置");
                }
            }
            if(!reference&&!settings)
            {
                if(Find<Grid>(page,"LibraryHeaderGrid") is {} top)top.Margin=new(28,16,28,12);
                if(Find<TextBlock>(page,"PageTitleText") is {} title){title.FontSize=30;title.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;}
                if(Find<TextBlock>(page,"GreetingText") is {} greeting)greeting.Margin=new(0,0,0,4);
                if(Find<TextBlock>(page,"ContentSectionTitle") is {} subtitle)
                {
                    subtitle.FontSize=18;
                    bool duplicate=!string.IsNullOrWhiteSpace(subtitle.Text)&&Find<TextBlock>(page,"PageTitleText")?.Text.Trim()==subtitle.Text.Trim();
                    if(duplicate&&subtitle.Visibility==Visibility.Visible){subtitle.Visibility=Visibility.Collapsed;duplicateTitleHidden=true;}
                    else if(!duplicate&&duplicateTitleHidden){subtitle.Visibility=Visibility.Visible;duplicateTitleHidden=false;}
                }
                if(Find<ScrollViewer>(page,"MainContentScrollViewer") is {} content)content.Padding=new(28,0,28,32);
                if(Find<StackPanel>(page,"ResumeSection") is {} resume){resume.Margin=new(0,0,0,28);Headings(resume);}
                if(Find<ItemsControl>(page,"HomeLibrarySectionsControl") is {} sections)
                {
                    sections.Margin=new(0,0,0,8);
                    Headings(sections);
                }
            }
            if(Find<Grid>(page,"SettingsView") is {} settingView)
            {
                foreach(var name in new[]{"AccountSettingsSection","AppearanceSettingsSection","ExperienceSettingsSection","CacheSettingsSection","DiagnosticsSettingsSection","AboutSettingsSection"})
                    if(Find<Border>(page,name) is {} section){section.Padding=new(24);section.CornerRadius=new(DesktopTheme.Options.Radius);}
            }
            DesktopContentBounds.Apply(page);DesktopReadability.Arrows(page);DesktopWindowSurface.Apply(page,p);
        }
        void Headings(FrameworkElement section)
        {
            foreach(var button in UiElements.Descendants(section).OfType<Button>())
            {
                if(DesktopCardSurface.Owns(button))continue;
                var labels=UiElements.Descendants(button).OfType<TextBlock>().Where(t=>t.FontSize>=18).ToArray();
                if(labels.Length==0)continue;
                button.Background=clear;button.BorderThickness=new(0);button.Padding=new(0,6,8,10);
                foreach(var icon in UiElements.Descendants(button).OfType<FontIcon>()){icon.FontSize=16;icon.Foreground=DesktopVisuals.Brush(palette.Accent);}
                button.CornerRadius=new(Math.Min(DesktopTheme.Options.Radius,8));
                foreach(var label in labels){label.FontSize=20;label.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;}
            }
        }
    }
}
