using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
namespace Yingyu.Update;

public static class PlayerDesktopStyle
{
    static readonly ConditionalWeakTable<object,State> States=new();
    static readonly List<WeakReference<State>> Live=new();
    public static void Configure(object overlay)
    {try{States.GetValue(overlay,o=>{var s=new State(o);Live.Add(new(s));return s;});}catch(Exception e){Warn(e);}}
    public static void RefreshAll(){Live.RemoveAll(x=>!x.TryGetTarget(out _));foreach(var weak in Live.ToArray())if(weak.TryGetTarget(out var state))state.Apply();}
    static void Warn(Exception e){try{PlaybackTransport.Write("Warning","Playback.Desktop","播放器外观或交互未完成；"+e.GetType().Name);}catch(Exception){}}
    public static void CancelClick(object overlay){if(States.TryGetValue(overlay,out var state))state.Cancel();}
    public static void StyleTools(Flyout flyout)
    {var p=DesktopThemePalette.Resolve(DesktopTheme.Options,true);var style=State.Presenter(DesktopTheme.Options,p);flyout.FlyoutPresenterStyle=style;}
    public static void GroupTools(UIElement content)
    {
        if(content is ScrollViewer {Content:UIElement body})content=body;
        if(content is not StackPanel panel)return;
        if(panel.Children.OfType<FrameworkElement>().Any(item=>item.Name=="DesktopTrackTools"))return;
        var items=panel.Children.ToArray();panel.Children.Clear();
        var groups=new[]{new Expander{Header="字幕与轨道",IsExpanded=true},new Expander{Header="片头片尾"},new Expander{Header="定时与窗口"},new Expander{Header="播放信息"}};
        groups[0].Name="DesktopTrackTools";
        var bodies=groups.Select(_=>new StackPanel{Spacing=12}).ToArray();
        for(int i=0;i<groups.Length;i++){groups[i].Content=bodies[i];groups[i].HorizontalAlignment=HorizontalAlignment.Stretch;panel.Children.Add(groups[i]);}
        int section=0;
        foreach(var item in items){string text=item switch{Button b=>b.Content?.ToString()??"",NumberBox n=>n.Header?.ToString()??"",ComboBox c=>c.Header?.ToString()??"",TextBlock t=>t.Text,_=>""};
            if(text.Contains("片头")||text.Contains("片尾")||text.Contains("本剧"))section=1;
            else if(text.Contains("睡眠")||text.Contains("定时")||text.Contains("窗口"))section=2;
            else if(text.StartsWith("播放信息")||text.Contains("实时解码"))section=3;
            bodies[section].Children.Add(item);
        }
    }
    sealed class State
    {
        readonly object overlay;readonly FrameworkElement element;readonly Microsoft.UI.Dispatching.DispatcherQueueTimer click;
        readonly SolidColorBrush accentBrush=DesktopVisuals.Brush(0xFFFFFFFF);
        bool placingEpisodes,placingSubtitle;
        Flyout? episodeFlyout;
        bool pending;long lastDrag;UIElement? pointerRoot;
        [DllImport("user32.dll")]static extern uint GetDoubleClickTime();
        public State(object overlay)
        {
            this.overlay=overlay;element=(FrameworkElement)overlay;
            PlayerMediaInfo.Configure(overlay);
            element.RequestedTheme=ElementTheme.Dark;
            accentBrush.Color=DesktopMaterial.Color(DesktopThemePalette.Resolve(DesktopTheme.Options,true).Accent);
            foreach(string name in new[]{"PositionSlider","VolumeSlider"}){var slider=Access.Get<Slider>(overlay,name);slider.Foreground=accentBrush;foreach(string key in new[]{"SliderTrackValueFill","SliderTrackValueFillPointerOver","SliderTrackValueFillPressed","SliderThumbBackground","SliderThumbBackgroundPointerOver","SliderThumbBackgroundPressed"})slider.Resources[key]=accentBrush;}
            var chrome=Access.Get<Grid>(overlay,"ChromeLayer");
            // Keep the original video-overlay gradients; no second opaque panel.
            click=element.DispatcherQueue.CreateTimer();click.IsRepeating=false;click.Interval=TimeSpan.FromMilliseconds(Math.Clamp(GetDoubleClickTime(),200u,1000u));
            click.Tick+=(_,_)=>CommitClick();
            element.Loaded+=(_,_)=>{AttachInput();Apply();};element.SizeChanged+=(_,_)=>Apply();element.Unloaded+=(_,_)=>{Cancel();DetachInput();episodeFlyout?.Hide();};
            var episodes=Access.Get<Border>(overlay,"EpisodeDrawer");
            episodes.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>PlaceEpisodes());
            episodes.SizeChanged+=(_,_)=>PlaceEpisodes();
            Access.Get<Slider>(overlay,"PositionSlider").SizeChanged+=(_,_)=>PlaceEpisodes();
            Access.Get<Button>(overlay,"SubtitleTrackButton").RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>PlaceSubtitle());
            var subtitleLabel=Access.Get<Button>(overlay,"SubtitleTrackButton");
            subtitleLabel.RegisterPropertyChangedCallback(ContentControl.ContentProperty,(_,_)=>{if(!Equals(subtitleLabel.Content,"字幕"))subtitleLabel.Content="字幕";});
            subtitleLabel.Content="字幕";
            Access.Get<Button>(overlay,"EpisodeDrawerButton").SizeChanged+=(_,_)=>PlaceEpisodes();
            foreach(string name in new[]{"PositionSlider","VolumeSlider"}){
                var slider=Access.Get<Slider>(overlay,name);slider.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler((_,_)=>{lastDrag=Environment.TickCount64;Cancel();}),true);
                slider.AddHandler(UIElement.PointerReleasedEvent,new PointerEventHandler((_,_)=>lastDrag=Environment.TickCount64),true);
            }
            if(element.IsLoaded){AttachInput();Apply();}
        }
        public void Cancel(){pending=false;click.Stop();}
        void CommitClick(){click.Stop();if(!pending)return;pending=false;try{if(element.IsLoaded&&element.XamlRoot!=null&&DesktopTheme.Options.VideoClickPause&&!VisualTreeHelper.GetOpenPopupsForXamlRoot(element.XamlRoot).Any(p=>p.IsOpen)&&!Access.Get<bool>(overlay,"_desktopDialogOpen")&&Access.Get<Border>(overlay,"EpisodeDrawer").Visibility!=Visibility.Visible)Access.Call(overlay,"PlayPauseButton_Click",Access.Get<Button>(overlay,"PlayPauseButton"),new RoutedEventArgs());}catch(Exception e){Warn(e);}}
        void Double(object sender,DoubleTappedRoutedEventArgs e)=>Cancel();
        void Key(object sender,KeyRoutedEventArgs e)=>Cancel();
        void AttachInput(){DetachInput();DependencyObject root=element;while(VisualTreeHelper.GetParent(root) is {} parent)root=parent;pointerRoot=root as UIElement??element;pointerRoot.AddHandler(UIElement.TappedEvent,new TappedEventHandler(Tap),true);pointerRoot.AddHandler(UIElement.DoubleTappedEvent,new DoubleTappedEventHandler(Double),true);pointerRoot.PreviewKeyDown+=Key;}
        void DetachInput(){if(pointerRoot==null)return;pointerRoot.RemoveHandler(UIElement.TappedEvent,new TappedEventHandler(Tap));pointerRoot.RemoveHandler(UIElement.DoubleTappedEvent,new DoubleTappedEventHandler(Double));pointerRoot.PreviewKeyDown-=Key;pointerRoot=null;}
        void Tap(object sender,TappedRoutedEventArgs e)
        {
            if(e.Handled||!DesktopTheme.Options.VideoClickPause||Environment.TickCount64-lastDrag<350)return;
            var point=e.GetPosition(element);var seek=Access.Get<Slider>(overlay,"PositionSlider");var seekTop=seek.TransformToVisual(element).TransformPoint(new Windows.Foundation.Point()).Y;
            if(point.Y<68||point.Y>=seekTop-12)return;
            for(DependencyObject? node=e.OriginalSource as DependencyObject;node!=null&&!ReferenceEquals(node,element);node=VisualTreeHelper.GetParent(node))
                if(node is ButtonBase or Slider or TextBox or PasswordBox or ComboBox or NumberBox||node is FrameworkElement{Name:"TitleText"})return;
            if(VisualTreeHelper.GetOpenPopupsForXamlRoot(element.XamlRoot).Any(p=>p.IsOpen)||Access.Get<Border>(overlay,"EpisodeDrawer").Visibility==Visibility.Visible)return;
            pending=true;click.Stop();click.Start();e.Handled=true;
        }
        public void Apply()
        {
            try{
                if(!element.IsLoaded)return;var options=DesktopTheme.Options;var p=DesktopThemePalette.Resolve(options,true);
                foreach(string name in new[]{"TitleText","PositionText","DurationText"}){var text=Access.Get<TextBlock>(overlay,name);text.Foreground=DesktopVisuals.Brush(p.Text);text.FontSize=name=="TitleText"?17:13;}
                accentBrush.Color=DesktopMaterial.Color(DesktopReadability.Progress(p));
                var position=Access.Get<Slider>(overlay,"PositionSlider");position.Foreground=accentBrush;
                foreach(var slider in new[]{position,Access.Get<Slider>(overlay,"VolumeSlider")})foreach(string key in new[]{"SliderTrackValueFill","SliderTrackValueFillPointerOver","SliderTrackValueFillPressed","SliderThumbBackground","SliderThumbBackgroundPointerOver","SliderThumbBackgroundPressed"})slider.Resources[key]=accentBrush;
                foreach(var button in UiElements.Descendants(Access.Get<Grid>(overlay,"ChromeLayer")).OfType<Button>()){
                    bool transport=button.Name is "PlayPauseButton" or "PreviousButton" or "NextButton";
                    button.Background=DesktopVisuals.Brush(transport?0xFF34373E:0x00000000);button.Foreground=DesktopVisuals.Brush(p.Text);button.MinHeight=transport?42:36;button.Height=transport?42:36;button.CornerRadius=new(transport?21:9);button.Padding=new(transport?8:10,6,transport?8:10,6);
                    if(button.Name=="PlayerMediaInfoButton"){button.Padding=new(6);button.HorizontalContentAlignment=HorizontalAlignment.Center;button.VerticalContentAlignment=VerticalAlignment.Center;}
                    foreach(string key in new[]{"ButtonForeground","ButtonForegroundPointerOver","ButtonForegroundPressed"})button.Resources[key]=DesktopVisuals.Brush(p.Text);
                    button.Resources["ButtonBackgroundPointerOver"]=DesktopVisuals.Brush(0xFF40444D);button.Resources["ButtonBackgroundPressed"]=DesktopVisuals.Brush(0xFF4C515D);
                    foreach(var icon in UiElements.Descendants(button).OfType<FontIcon>())icon.Foreground=DesktopVisuals.Brush(p.Text);
                    if(button.Name is "SpeedButton" or "AudioTrackButton" or "SubtitleTrackButton" or "VolumeButton" or "EpisodeDrawerButton" or "PlayerMediaInfoButton" || Equals(button.Content,"更多"))
                        button.Template=HoverButtonTemplate;
                }
                var drawer=Access.Get<Border>(overlay,"EpisodeDrawer");drawer.Background=episodeFlyout==null?DesktopMaterial.Surface(options,p,true):DesktopVisuals.Brush(0);drawer.CornerRadius=new(16);
                if(episodeFlyout!=null)episodeFlyout.FlyoutPresenterStyle=Presenter(options,p);
                PlaceSubtitle();PlaceEpisodes();
                foreach(string name in new[]{"AudioTrack","SubtitleTrack","Speed","Volume"}){
                    var flyout=Access.Get<Flyout>(overlay,name+"Flyout");flyout.FlyoutPresenterStyle=Presenter(options,p);
                    if(flyout.Content is Panel list){flyout.Content=null;flyout.Content=new ScrollViewer{Content=list,MaxHeight=Math.Max(160,Math.Min(520,element.ActualHeight-100)),VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};}
                }
                // Statistics remain available in More; remove the duplicate toolbar entry.
                Access.Get<Button>(overlay,"PlaybackInfoButton").Visibility=Visibility.Collapsed;
                DesktopContentBounds.Apply(Access.Get<Grid>(overlay,"ChromeLayer"));
                foreach(string name in new[]{"AudioTrack","SubtitleTrack","Speed","Volume"})if(Access.Get<Flyout>(overlay,name+"Flyout").Content is DependencyObject body)DesktopContentBounds.Apply(body);
            }catch(Exception e){Warn(e);}
        }
        void PlaceSubtitle()
        {
            if(placingSubtitle)return;placingSubtitle=true;
            try
            {
                // Honor loading/compact visibility, while keeping a persistent
                // subtitle entry after normal controls return.
                if(Access.Get<System.Collections.IDictionary>(overlay,"_compactVisibility").Count>0)return;
                var subtitle=Access.Get<Button>(overlay,"SubtitleTrackButton");
                var audio=Access.Get<Button>(overlay,"AudioTrackButton");var volume=Access.Get<Button>(overlay,"VolumeButton");
                if(audio.Parent is StackPanel strip&&ReferenceEquals(volume.Parent,strip)&&ReferenceEquals(subtitle.Parent,strip))
                {
                    int at=strip.Children.IndexOf(audio)+1;
                    if(strip.Children.IndexOf(subtitle)!=at){strip.Children.Remove(subtitle);strip.Children.Insert(strip.Children.IndexOf(audio)+1,subtitle);}
                }
                subtitle.Visibility=Visibility.Visible;
            }
            finally{placingSubtitle=false;}
        }
        void PlaceEpisodes()
        {
            if(placingEpisodes)return;placingEpisodes=true;
            try
            {
                var drawer=Access.Get<Border>(overlay,"EpisodeDrawer");
                if(drawer.Visibility!=Visibility.Visible){episodeFlyout?.Hide();return;}
                var button=Access.Get<Button>(overlay,"EpisodeDrawerButton");
                if(!element.IsLoaded||button.ActualWidth<=0||element.XamlRoot==null)return;
                if(episodeFlyout==null)
                {
                    // The original drawer, episode grid and click handlers are
                    // reused inside the same native Flyout as audio/subtitles.
                    if(VisualTreeHelper.GetParent(drawer) is not Panel old)return;
                    old.Children.Remove(drawer);
                    var reference=Access.Get<Flyout>(overlay,"AudioTrackFlyout");
                    episodeFlyout=new Flyout{Content=drawer,Placement=reference.Placement,ShouldConstrainToRootBounds=reference.ShouldConstrainToRootBounds,ShowMode=reference.ShowMode,FlyoutPresenterStyle=Presenter(DesktopTheme.Options,DesktopThemePalette.Resolve(DesktopTheme.Options,true))};
                    PlayerMenus.BindEpisodes(overlay,episodeFlyout);
                    episodeFlyout.Closed+=(_,_)=>{
                        try{if(drawer.Visibility==Visibility.Visible)Access.Call(overlay,"CloseEpisodeDrawer");}
                        catch(Exception error){Warn(error);}
                    };
                }
                double width=Math.Min(292,Math.Max(1,element.ActualWidth-32));
                drawer.MinWidth=0;drawer.MaxWidth=width;drawer.Width=width;drawer.Height=double.NaN;
                drawer.HorizontalAlignment=HorizontalAlignment.Stretch;drawer.VerticalAlignment=VerticalAlignment.Stretch;
                drawer.MaxHeight=Math.Max(120,Math.Min(620,element.ActualHeight-100));drawer.Margin=new(0);drawer.BorderThickness=new(0);drawer.Background=DesktopVisuals.Brush(0);
                var episodes=Access.Get<GridView>(overlay,"EpisodeGrid");episodes.MaxHeight=Math.Max(44,drawer.MaxHeight-96);
                ScrollViewer.SetHorizontalScrollBarVisibility(episodes,ScrollBarVisibility.Disabled);
                if(!episodeFlyout.IsOpen)episodeFlyout.ShowAt(button,new FlyoutShowOptions{ShowMode=FlyoutShowMode.Transient});
            }
            finally{placingEpisodes=false;}
        }
        internal static Style Presenter(DesktopThemeOptions options,DesktopThemePalette p){var style=new Style(typeof(FlyoutPresenter));style.Setters.Add(new Setter(Control.BackgroundProperty,DesktopMaterial.Surface(options,p,true)));style.Setters.Add(new Setter(Control.ForegroundProperty,DesktopVisuals.Brush(p.Text)));style.Setters.Add(new Setter(Control.BorderBrushProperty,DesktopVisuals.Brush(0)));style.Setters.Add(new Setter(Control.BorderThicknessProperty,new Thickness(0)));style.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(4)));style.Setters.Add(new Setter(Control.CornerRadiusProperty,new CornerRadius(14)));return style;}
        static readonly ControlTemplate HoverButtonTemplate=(ControlTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
              <Grid Background="Transparent"><ContentPresenter Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" Foreground="{TemplateBinding Foreground}" Padding="{TemplateBinding Padding}" HorizontalContentAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalContentAlignment="{TemplateBinding VerticalContentAlignment}" /></Grid>
            </ControlTemplate>
            """);
    }
}

