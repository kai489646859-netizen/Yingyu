using System.Numerics;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Input;

namespace Yingyu.Update;
internal static class DesktopCardSurface
{
    static readonly ConditionalWeakTable<Grid,Surface> Surfaces=new();
    internal static void Apply(Grid root,DesktopThemeOptions options,DesktopThemePalette palette)
        => Surfaces.GetValue(root,g=>new Surface(g)).Update(options,palette);
    internal static void Apply(Grid root,DesktopThemeOptions options,DesktopThemePalette palette,object page)
    {var surface=Surfaces.GetValue(root,g=>new Surface(g));surface.Owner=page;surface.Update(options,palette);}
    internal static bool Ready(Grid root,object card)=>Surfaces.TryGetValue(root,out var surface)&&surface.Current(card);
    internal static bool PaintPoster(Grid root,object card)=>Surfaces.TryGetValue(root,out var surface)&&surface.PaintPoster(card);
    internal static void RefreshAfterScroll(object page)
    {
        foreach(var pair in Surfaces)
            if(pair.Key.IsLoaded&&ReferenceEquals(pair.Value.Owner,page)&&pair.Value.Deferred)
                pair.Value.Update(DesktopTheme.Options,ReferenceSurfaces.Palette(pair.Key));
    }
    internal static bool Owns(DependencyObject node)
    {for(DependencyObject? current=node;current!=null;current=VisualTreeHelper.GetParent(current))if(current is Grid grid&&Surfaces.TryGetValue(grid,out _))return true;return false;}
    sealed class Surface
    {
        readonly Grid root,frame=new(),picture=new();
        readonly Image image=new(){Stretch=Stretch.UniformToFill};
        readonly Border shade=new(){Background=DesktopVisuals.Brush(0xFF000000),Opacity=0,IsHitTestVisible=false};
        readonly StackPanel footer=new(){Orientation=Orientation.Horizontal,Spacing=6,HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Bottom,Margin=new(8,8,8,12),Opacity=0,IsHitTestVisible=false};
        readonly Border rounded=new(),track=new(){Height=6,VerticalAlignment=VerticalAlignment.Bottom},fill=new(){Height=6,HorizontalAlignment=HorizontalAlignment.Left};
        readonly FontIcon missing=new(){Glyph="\uEB9F",FontSize=28};
        readonly TextBlock title=new(){FontSize=14,TextTrimming=TextTrimming.CharacterEllipsis},subtitle=new(){FontSize=12,TextTrimming=TextTrimming.CharacterEllipsis};
        readonly Border rating=new(){HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Bottom,Margin=new(10,10,10,12),Padding=new(7,4,7,4),CornerRadius=new(7)},count=new(){HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Top,Margin=new(10),Padding=new(8,4,8,4),CornerRadius=new(7)};
        readonly Microsoft.UI.Composition.CompositionRoundedRectangleGeometry geometry;
        double radius,percentage;
        bool landscape;
        ImageSource? paintedSource;
        bool missingVisible=true;
        bool hovered,pressed;
        DesktopThemeOptions? styledOptions;DesktopThemePalette styledPalette;bool styled;object? paintedModel;
        internal bool PaintPoster(object card)
        {
            if(!styled||!ReferenceEquals(paintedModel,card)||!ReferenceEquals(root.DataContext,card))return false;
            image.Source=card.GetType().GetProperty("Poster")?.GetValue(card) as BitmapImage;
            bool loaded=image.Source is BitmapImage{PixelWidth:>0,PixelHeight:>0};
            missing.Visibility=loaded?Visibility.Collapsed:Visibility.Visible;
            rounded.Background=DesktopVisuals.Brush(loaded?0x00000000:styledPalette.Hover);
            return true;
        }
        object? menuOwner,menuCard;string? menuType;bool menuPlayed,menuFavorite;
        readonly Button? favorite;
        internal object? Owner;
        internal bool Deferred;
        readonly Button play=new(){Name="PosterQuickPlay",HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center,Width=52,Height=52,Opacity=0,IsHitTestVisible=false},more=new(){Name="PosterMore",Width=32,Height=32},watched=new(){Name="PosterWatched",Width=32,Height=32};
        internal bool Current(object card)=>ReferenceEquals(paintedSource,card.GetType().GetProperty("Poster")?.GetValue(card))&&!missingVisible;
        public Surface(Grid root)
        {
            this.root=root;
            // Track dependency-property changes once instead of crossing into
            // WinUI getters on every viewport/scroll readiness check. External
            // rebinding still invalidates the cached state synchronously.
            image.RegisterPropertyChangedCallback(Image.SourceProperty,(_,_)=>paintedSource=image.Source);
            missing.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>missingVisible=missing.Visibility!=Visibility.Collapsed);
            image.ImageOpened+=(_,_)=>{missing.Visibility=Visibility.Collapsed;Fit();};
            image.ImageFailed+=(_,_)=>{missing.Visibility=Visibility.Visible;};
            // Keep the actual favorite control and its original events/bindings.
            favorite=Logical(root).Concat(UiElements.Descendants(root)).OfType<Button>().FirstOrDefault(b=>b.Name=="PosterFavoriteButton");
            // A XBF template can own the control before FrameworkElement.Parent
            // is populated. Detach from the actual logical collection first.
            if(favorite!=null&&!Detach(root,favorite))throw new InvalidOperationException("海报收藏控件仍属于旧容器。");
            root.Children.Clear();root.RowDefinitions.Clear();root.ColumnDefinitions.Clear();
            root.RowDefinitions.Add(new(){Height=new GridLength(1)});root.RowDefinitions.Add(new(){Height=GridLength.Auto});root.RowDefinitions.Add(new(){Height=GridLength.Auto});
            root.Margin=new Thickness(0);root.Padding=new Thickness(0);root.MinWidth=0;root.HorizontalAlignment=HorizontalAlignment.Left;
            root.Clip=null;root.Height=double.NaN;root.MinHeight=0;root.MaxHeight=double.PositiveInfinity;root.BorderThickness=new Thickness(0);root.Background=null;
            picture.Children.Add(image);picture.Children.Add(shade);picture.Children.Add(track);track.Child=fill;rounded.Child=picture;frame.Children.Add(rounded);frame.Children.Add(missing);root.Children.Add(frame);
            picture.Children.Add(rating);picture.Children.Add(count);
            play.Content=new Microsoft.UI.Xaml.Shapes.Polygon{Width=16,Height=18,Margin=new(3,0,0,0),Stretch=Stretch.Uniform,Fill=DesktopVisuals.Brush(0xFFFFFFFF),Points=new PointCollection{new(0,0),new(0,18),new(15,9)}};
            more.Content=new FontIcon{Glyph="\uE712",FontSize=22,Foreground=DesktopVisuals.Brush(0xFFFFFFFF)};
            watched.Content=new Border{Width=18,Height=18,CornerRadius=new(9),BorderThickness=new(2),BorderBrush=DesktopVisuals.Brush(0xFFFFFFFF),Child=new FontIcon{Glyph="\uE73E",FontSize=12,Foreground=DesktopVisuals.Brush(0xFFFFFFFF)}};
            footer.Children.Add(watched);if(favorite!=null){Grid.SetRow(favorite,0);Grid.SetColumn(favorite,0);footer.Children.Add(favorite);}footer.Children.Add(more);
            frame.Children.Add(play);frame.Children.Add(footer);
            play.Click+=async (_,_)=>{if(Owner==null||root.DataContext==null)return;play.IsEnabled=false;try{await DesktopCardActions.Play(Owner,root.DataContext);}finally{play.IsEnabled=true;}};
            more.Click+=(_,_)=>{if(Owner!=null&&root.DataContext!=null)DesktopCardActions.Menu(Owner,root,root.DataContext).ShowAt(more);};
            watched.Click+=async(_,_)=>{if(Owner==null||root.DataContext==null)return;watched.IsEnabled=false;try{await DesktopCardActions.Watched(Owner,root.DataContext);}finally{watched.IsEnabled=true;}};
            foreach(var button in new[]{play,more,watched,favorite}.Where(b=>b!=null))button!.Tapped+=(_,e)=>e.Handled=true;
            root.PointerEntered+=(_,e)=>{if(e.Pointer.PointerDeviceType==Microsoft.UI.Input.PointerDeviceType.Mouse)SetHovered(true);};
            root.AddHandler(UIElement.PointerExitedEvent,new PointerEventHandler((_,e)=>{if(!ReferenceEquals(e.OriginalSource,root)&&Inside(e))return;SetHovered(false);}),true);
            root.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler((_,e)=>{if(e.Pointer.PointerDeviceType==Microsoft.UI.Input.PointerDeviceType.Mouse&&e.GetCurrentPoint(root).Properties.IsLeftButtonPressed)SetPressed(true);}),true);
            root.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler((_,_)=>{
                if(!Deferred||root.DataContext is not {} card||card.GetType().GetProperty("Item")?.GetValue(card) is not EmbyItem item)return;
                try{EnsureMenu(card,item);}catch(Exception error){try{PlaybackTransport.Write("Warning","Poster.Menu","卡片菜单未完成；"+error.GetType().Name);}catch(Exception){}}
            }),true);
            root.AddHandler(UIElement.PointerReleasedEvent,new PointerEventHandler((_,e)=>{pressed=false;hovered=Inside(e);PaintHover();}),true);
            root.PointerCanceled+=(_,_)=>ResetHover();root.PointerCaptureLost+=(_,_)=>{pressed=false;PaintHover();};
            root.GotFocus+=(_,_)=>PaintHover();root.LostFocus+=(_,_)=>PaintHover();root.Unloaded+=(_,_)=>ResetHover();root.DataContextChanged+=(_,_)=>ResetHover();ResetHover();
            Grid.SetRow(title,1);title.Margin=new(0,8,0,0);root.Children.Add(title);
            Grid.SetRow(subtitle,2);subtitle.Margin=new(0,4,0,10);root.Children.Add(subtitle);
            var visual=ElementCompositionPreview.GetElementVisual(rounded);geometry=visual.Compositor.CreateRoundedRectangleGeometry();visual.Clip=visual.Compositor.CreateGeometricClip(geometry);
            PosterMotion.Attach(frame,rounded);
            PosterPointerScope.Watch(root,()=>SetHovered(false));
            frame.SizeChanged+=(_,_)=>Fit();
        }
        bool Inside(PointerRoutedEventArgs e){var p=e.GetCurrentPoint(root).Position;return p.X>=0&&p.Y>=0&&p.X<root.ActualWidth&&p.Y<root.ActualHeight;}
        void SetHovered(bool value){hovered=value;if(!value)pressed=false;PaintHover();}
        void SetPressed(bool value){pressed=value;PaintHover();}
        void ResetHover(){hovered=pressed=false;PaintHover(true);}
        void PaintHover(bool reset=false)
        {
            bool focused=play.FocusState==FocusState.Keyboard||more.FocusState==FocusState.Keyboard||watched.FocusState==FocusState.Keyboard||favorite?.FocusState==FocusState.Keyboard;
            bool show=!reset&&Owner!=null&&(hovered||pressed||focused);
            shade.Opacity=show?(pressed ? .55 : .38):0;play.Opacity=footer.Opacity=show?1:0;play.IsHitTestVisible=footer.IsHitTestVisible=show;
            rating.Opacity=show?0:1;
            if(favorite!=null){favorite.Opacity=show?1:0;favorite.IsHitTestVisible=show;}
        }
        static IEnumerable<DependencyObject> Logical(DependencyObject node)
        {
            yield return node;
            IEnumerable<DependencyObject> children=node switch{Panel p=>p.Children,Border b when b.Child!=null=>new[]{b.Child},ContentControl c when c.Content is DependencyObject d=>new[]{d},ContentPresenter c when c.Content is DependencyObject d=>new[]{d},_=>Array.Empty<DependencyObject>()};
            foreach(var child in children)foreach(var nested in Logical(child))yield return nested;
        }
        static bool Detach(DependencyObject node,UIElement target)
        {
            if(node is Panel p){if(p.Children.Contains(target)){p.Children.Remove(target);return true;}foreach(var child in p.Children.ToArray())if(Detach(child,target))return true;}
            DependencyObject? content=node switch{Border b=>b.Child,ContentControl c=>c.Content as DependencyObject,ContentPresenter c=>c.Content as DependencyObject,_=>null};
            if(ReferenceEquals(content,target)){if(node is Border b)b.Child=null;else if(node is ContentControl c)c.Content=null;else if(node is ContentPresenter cp)cp.Content=null;return true;}
            return content!=null&&Detach(content,target);
        }
        void Fit()
        {
            double inset=PosterMotion.Inset(frame.ActualWidth,frame.ActualHeight);
            double width=Math.Max(0,frame.ActualWidth-2*inset),height=Math.Max(0,frame.ActualHeight-2*inset);
            // A row has one aperture, independent of each server image's ratio.
            // Loading a different source must never shrink one card in the row.
            var fit=CardFit.Resolve(width,height,landscape?16:2,landscape?9:3);
            rounded.Width=fit.Width;rounded.Height=fit.Height;geometry.Size=new((float)fit.Width,(float)fit.Height);geometry.CornerRadius=new((float)Math.Min(radius,Math.Min(fit.Width,fit.Height)/2));
            picture.Width=image.Width=fit.Width;picture.Height=image.Height=fit.Height;
            footer.Spacing=landscape?6:Math.Clamp((fit.Width*.66-96)/2,4,24);
            footer.Margin=new(inset+10,inset+10,inset+10,inset+9);
            fill.Width=fit.Width*percentage/100;
        }
        void EnsureMenu(object card,EmbyItem item)
        {
            bool played=item.UserData?.Played==true,favorited=item.UserData?.IsFavorite==true;
            if(Owner==null||ReferenceEquals(menuOwner,Owner)&&ReferenceEquals(menuCard,card)&&menuType==item.Type&&menuPlayed==played&&menuFavorite==favorited)return;
            root.ContextFlyout=DesktopCardActions.Menu(Owner,root,card);
            menuOwner=Owner;menuCard=card;menuType=item.Type;menuPlayed=played;menuFavorite=favorited;
        }
        public void Update(DesktopThemeOptions options,DesktopThemePalette palette)
        {
            if(root.DataContext is not {} card)return;
            var item=card.GetType().GetProperty("Item")?.GetValue(card) as EmbyItem;if(item==null)return;
            landscape=card.GetType().GetProperty("PreferLandscapeArtwork")?.GetValue(card) is true;
            bool animating=Owner!=null&&DesktopScroll.IsAnimating(Owner);Deferred=animating;
            string playLabel=item.Type is "Series" or "Season"?"选择集数":"播放／继续观看";
            ToolTipService.SetToolTip(play,playLabel);Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(play,playLabel);
            ToolTipService.SetToolTip(more,"更多");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more,"更多");string watchLabel=item.UserData?.Played==true?"标为未看":"标为已看";ToolTipService.SetToolTip(watched,watchLabel);Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(watched,watchLabel);
            if(!animating)EnsureMenu(card,item);
            else if(!ReferenceEquals(menuCard,card))root.ContextFlyout=null;
            bool themeChanged=!styled||styledOptions!=options||styledPalette!=palette;
            if(themeChanged)foreach(var button in new[]{play,more,watched,favorite}.Where(b=>b!=null)){
                button!.Background=DesktopVisuals.Brush(0xCC101820);button.Foreground=DesktopVisuals.Brush(0xFFFFFFFF);button.CornerRadius=new(button==play?26:16);button.Padding=new(0);button.MinHeight=button.MinWidth=button==play?52:32;if(button!=play){button.Width=button.Height=32;}
                button.BorderBrush=DesktopVisuals.Brush(0xFFFFFFFF);button.BorderThickness=new(button==play?1.5:0);
                foreach(string suffix in new[]{"","PointerOver","Pressed","Disabled"})button.Resources["ButtonForeground"+suffix]=DesktopVisuals.Brush(0xFFFFFFFF);
                button.Resources["ButtonBackgroundPointerOver"]=DesktopVisuals.Brush(0xF02A3845);button.Resources["ButtonBackgroundPressed"]=DesktopVisuals.Brush(0xFF101820);
                foreach(var icon in UiElements.Descendants(button).OfType<IconElement>())icon.Foreground=DesktopVisuals.Brush(0xFFFFFFFF);
                foreach(var text in UiElements.Descendants(button).OfType<TextBlock>())text.Foreground=DesktopVisuals.Brush(0xFFFFFFFF);
            }
            styled=true;styledOptions=options;styledPalette=palette;
            rating.VerticalAlignment=VerticalAlignment.Bottom;rating.Margin=new(10,10,10,12);
            image.Stretch=Stretch.UniformToFill;
            paintedModel=card;radius=options.Radius;image.Source=card.GetType().GetProperty("Poster")?.GetValue(card) as BitmapImage;
            bool loaded=image.Source is BitmapImage{PixelWidth:>0,PixelHeight:>0};missing.Visibility=loaded?Visibility.Collapsed:Visibility.Visible;
            missing.Foreground=DesktopVisuals.Brush(palette.Secondary);rounded.Background=DesktopVisuals.Brush(loaded?0x00000000:palette.Hover);
            if(!animating)ReferenceSurfaces.Ancestors(root);
            title.Text=card.GetType().GetProperty(landscape?"ResumeTitle":"Title")?.GetValue(card)?.ToString()??item.Name;
            subtitle.Text=card.GetType().GetProperty(landscape?"ResumeLabel":"Subtitle")?.GetValue(card)?.ToString()??"";
            if(landscape){subtitle.Text=ResumeServerHistory.Caption(item,subtitle.Text);if(ResumeSync.IsPending(item))subtitle.Text+=" · 待同步";}
            title.Foreground=DesktopVisuals.Brush(palette.Text);subtitle.Foreground=DesktopVisuals.Brush(palette.Secondary);
            title.TextAlignment=subtitle.TextAlignment=landscape?TextAlignment.Center:TextAlignment.Left;
            ToolTipService.SetToolTip(title,title.Text);ToolTipService.SetToolTip(subtitle,subtitle.Text);
            percentage=DesktopReadability.Percentage(item,(double?)card.GetType().GetProperty("Progress")?.GetValue(card)??0,landscape);
            track.Visibility=(landscape&&item.RunTimeTicks is >0||percentage>0&&percentage<100)?Visibility.Visible:Visibility.Collapsed;
            track.Background=DesktopVisuals.Brush(0xEE101018);track.BorderBrush=DesktopVisuals.Brush(0);track.BorderThickness=new Thickness(0);fill.Background=DesktopVisuals.Brush(DesktopReadability.Progress(palette));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(frame,$"{title.Text}，已观看 {percentage:0}%");
            rating.Visibility=!landscape&&item.CommunityRating is >=0 and <=10?Visibility.Visible:Visibility.Collapsed;
            if(themeChanged)rating.Background=DesktopVisuals.Brush(0xD91A2028);
            if(rating.Child is not TextBlock ratingText){ratingText=new TextBlock{Foreground=DesktopVisuals.Brush(0xFFFFFFFF),FontSize=11,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold};rating.Child=ratingText;}
            ratingText.Text=item.CommunityRating?.ToString("0.0")??"";
            bool hasCount=!landscape&&card.GetType().GetProperty("HasEpisodeCount")?.GetValue(card) is true;
            count.Visibility=hasCount?Visibility.Visible:Visibility.Collapsed;
            if(themeChanged)count.Background=DesktopVisuals.Brush(0xD91A2028);
            if(count.Child is not TextBlock countText){countText=new TextBlock{Foreground=DesktopVisuals.Brush(0xFFFFFFFF),FontSize=11,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold};count.Child=countText;}
            countText.Text=card.GetType().GetProperty("EpisodeCountLabel")?.GetValue(card)?.ToString()??"";
            Fit();if(themeChanged)DesktopContentBounds.Apply(root);
        }
    }
}
