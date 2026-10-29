using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Yingyu.Update;

// Local presentation resources: settings and the player keep their own theme.
internal static class ReferenceSurfaces
{
    static readonly ConditionalWeakTable<ScrollViewer,object> Rows=new();
    sealed class MenuState { internal DesktopThemePalette Palette; internal Action Paint=null!; }
    static readonly ConditionalWeakTable<FlyoutBase,MenuState> Menus=new();
    static readonly ConditionalWeakTable<FrameworkElement,EpisodeStyleState> Episodes=new();
    internal static void WatchEpisodes(FrameworkElement? owner){if(owner!=null)Episodes.GetValue(owner,e=>new EpisodeStyleState(e));}
    // ItemsControl creates a fresh button tree when expanding or changing ranges.
    // Observe those changes, then style the realized tree after layout. There is
    // no permanent LayoutUpdated traversal while the page is idle or scrolling.
    sealed class EpisodeStyleState
    {
        readonly FrameworkElement owner;bool pending;
        internal EpisodeStyleState(FrameworkElement owner)
        {
            this.owner=owner;
            if(owner is ItemsControl items)items.Items.VectorChanged+=(_,_)=>Queue();
            if(owner is ItemsRepeater repeater)repeater.ElementPrepared+=(_,args)=>{if(args.Element is FrameworkElement element&&!element.IsLoaded){RoutedEventHandler? loaded=null;loaded=(_,_)=>{element.Loaded-=loaded;Queue();};element.Loaded+=loaded;}Queue();};
            owner.Loaded+=(_,_)=>Queue();owner.Unloaded+=(_,_)=>Stop();Queue();
        }
        void Queue(){if(pending||!owner.IsLoaded)return;pending=true;owner.LayoutUpdated+=Paint;owner.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>Paint(null!,null!));}
        void Stop(){owner.LayoutUpdated-=Paint;pending=false;}
        void Paint(object? sender,object? args)
        {
            if(!pending||!owner.IsLoaded){Stop();return;}
            for(DependencyObject? node=owner;node!=null;node=VisualTreeHelper.GetParent(node))if(node is UIElement{Visibility:Visibility.Collapsed}){Stop();return;}
            var buttons=UiElements.Descendants(owner).OfType<Button>().Where(b=>b.Tag is string&&b.Content is Grid).ToArray();
            foreach(var button in buttons)Button(button);
            if(owner is ItemsControl items?buttons.Length>=items.Items.Count:buttons.Length>0||owner is ItemsRepeater{ItemsSource:null})Stop();
        }
    }
    internal static bool Dark(FrameworkElement? element=null)=>DesktopTheme.Options.Mode==2||DesktopTheme.Options.Mode==0&&((element?.XamlRoot?.Content as FrameworkElement)?.ActualTheme??element?.ActualTheme??Application.Current.RequestedTheme switch {ApplicationTheme.Dark=>ElementTheme.Dark,_=>ElementTheme.Light})==ElementTheme.Dark;
    internal static DesktopThemePalette Palette(FrameworkElement? element=null)=>DesktopThemePalette.Resolve(DesktopTheme.Options,Dark(element));
    static SolidColorBrush Brush(uint value)=>DesktopVisuals.Brush(value);
    internal static void Resources(FrameworkElement root)
    {
        var p=Palette(root);root.RequestedTheme=Dark(root)?ElementTheme.Dark:ElementTheme.Light;
        foreach(string key in new[]{"PrimaryTextBrush","DetailPrimaryTextBrush","ComboBoxForeground","ComboBoxForegroundPointerOver","ComboBoxForegroundPressed","ComboBoxItemForegroundSelected","ComboBoxItemForegroundSelectedPointerOver","ButtonForeground","ButtonForegroundPointerOver","ButtonForegroundPressed","TextControlForeground"})root.Resources[key]=Brush(p.Text);
        foreach(string key in new[]{"SecondaryTextBrush","DetailSecondaryTextBrush"})root.Resources[key]=Brush(p.Secondary);
        foreach(string key in new[]{"ComboBoxBackground","ComboBoxBackgroundPointerOver","ComboBoxBackgroundPressed","ComboBoxDropDownBackground","MenuFlyoutPresenterBackground","FlyoutBackground","EpisodeTileBrush","DetailTileBrush","ButtonBackground"})root.Resources[key]=Brush(p.Surface);
        foreach(string key in new[]{"ButtonBackgroundPointerOver","ButtonBackgroundPressed","ComboBoxItemBackgroundSelected","ComboBoxItemBackgroundSelectedPointerOver"})root.Resources[key]=Brush(p.Hover);
        root.Resources["FlyoutPresenterBackground"]=Brush(p.Surface);
        root.Resources["FlyoutPresenterBorderBrush"]=Brush(0);root.Resources["MenuFlyoutPresenterBorderBrush"]=Brush(0);
        root.Resources["EpisodeTileBorderBrush"]=Brush(0);
    }
    internal static void Button(Button button)
    {
        var p=Palette(button);Resources(button);button.Background=Brush(p.Hover);button.Foreground=Brush(p.Text);button.BorderBrush=Brush(0);button.BorderThickness=new(0);button.CornerRadius=new(18);button.MinHeight=36;button.Padding=new(14,6,14,6);
        if(button.Content is IconElement icon){double size=icon is FontIcon font?font.FontSize:20;button.Padding=new(8);button.MinWidth=Math.Max(36,size+16);button.MinHeight=Math.Max(36,size+16);if(!double.IsNaN(button.Width))button.Width=Math.Max(button.Width,button.MinWidth);if(!double.IsNaN(button.Height))button.Height=Math.Max(button.Height,button.MinHeight);}
        // Compiled XBF bindings retain their data root and can clear DataContext.
        // Style the existing selected border; its original IsCurrent visibility
        // binding and the watched-progress bar continue to own their state.
        if(button.Tag is string&&button.Content is Grid content)
            for(DependencyObject? n=VisualTreeHelper.GetParent(button);n!=null;n=VisualTreeHelper.GetParent(n))
                if(n is FrameworkElement owner&&owner.Name is "DetailEpisodeStripItems" or "DetailEpisodesGrid")
                {
                    button.Padding=new(0);button.HorizontalContentAlignment=HorizontalAlignment.Stretch;button.VerticalContentAlignment=VerticalAlignment.Stretch;
                    // The original selection overlay used a -1 margin to cover
                    // the old outer stroke. With that stroke removed, it extends
                    // past the presenter and clips its corners asymmetrically.
                    foreach(var selected in content.Children.OfType<Border>()){selected.Margin=new(0);selected.Background=Brush(p.Selection);selected.BorderBrush=Brush(p.Accent);selected.CornerRadius=button.CornerRadius;}
                    break;
                }
        foreach(var text in UiElements.Descendants(button).OfType<TextBlock>())text.Foreground=Brush(p.Text);
    }
    internal static void Apply(FrameworkElement view)
    {
        var p=Palette(view);Resources(view);
        foreach(var node in UiElements.Descendants(view).ToArray())
        {
            if(DesktopCardSurface.Owns(node))continue;
            if(node is FrameworkElement group&&group.Name is "DetailEpisodeStripItems" or "DetailEpisodesGrid")WatchEpisodes(group);
            if(node is TextBlock text)text.Foreground=Brush(p.Text);
            if(node is ComboBox combo){Resources(combo);combo.Foreground=Brush(p.Text);combo.Background=Brush(p.Surface);combo.BorderBrush=Brush(0);combo.BorderThickness=new(0);combo.CornerRadius=new(16);combo.MinHeight=36;}
            if(node is Button button){
                // Specialized templates own their size, state and painting. The
                // alphabet rail must never inherit generic pill dimensions.
                if(!DesktopNavigation.Owns(button)&&button.Name is not ("PosterQuickPlay" or "PosterMore" or "PosterWatched" or "PosterFavoriteButton")&&!UiElements.Descendants(button).OfType<Image>().Any()){
                    Resources(button);button.Foreground=Brush(p.Text);
                    if(button.Content is IconElement icon){double size=icon is FontIcon font?font.FontSize:20;button.Padding=new(8);button.MinWidth=Math.Max(36,size+16);button.MinHeight=Math.Max(36,size+16);if(!double.IsNaN(button.Width))button.Width=Math.Max(button.Width,button.MinWidth);if(!double.IsNaN(button.Height))button.Height=Math.Max(button.Height,button.MinHeight);}
                    if(button.Tag is string&&button.Content is Grid&&HasAncestor(button,"DetailEpisodeStripItems","DetailEpisodesGrid"))Button(button);
                }
                if(button.Flyout!=null)Flyout(button.Flyout);
            }
            if(node is ScrollViewer scroll)Row(scroll);
        }
        foreach(var selected in UiElements.Descendants(view).OfType<Button>().Where(b=>Microsoft.UI.Xaml.Automation.AutomationProperties.GetItemStatus(b)=="当前位置"))
        {
            selected.Foreground=Brush(p.Accent);
            foreach(var label in UiElements.Descendants(selected).OfType<TextBlock>())label.Foreground=Brush(p.Accent);
            foreach(var icon in UiElements.Descendants(selected).OfType<IconElement>())icon.Foreground=Brush(p.Accent);
        }
        DesktopContentBounds.Apply(view);DesktopReadability.Arrows(view);
    }
    static bool HasAncestor(DependencyObject node,params string[] names){for(var n=VisualTreeHelper.GetParent(node);n!=null;n=VisualTreeHelper.GetParent(n))if(n is FrameworkElement e&&names.Contains(e.Name))return true;return false;}
    internal static void Flyout(FlyoutBase flyout)
    {
        FrameworkElement? Anchor()=>flyout is Flyout f?f.Content as FrameworkElement:(flyout as MenuFlyout)?.Items.FirstOrDefault();
        if(Menus.TryGetValue(flyout,out var previous)){if(previous.Palette!=Palette(Anchor()))previous.Paint();return;}
        var state=new MenuState();Menus.Add(flyout,state);
        bool styled=false;
        void Paint()
        {
            var anchor=Anchor();var p=Palette(anchor);state.Palette=p;
            var type=flyout is MenuFlyout?typeof(MenuFlyoutPresenter):typeof(FlyoutPresenter);
            var style=new Style(type);style.Setters.Add(new Setter(FrameworkElement.RequestedThemeProperty,Dark(anchor)?ElementTheme.Dark:ElementTheme.Light));style.Setters.Add(new Setter(Control.BackgroundProperty,Brush(p.Surface)));style.Setters.Add(new Setter(Control.ForegroundProperty,Brush(p.Text)));style.Setters.Add(new Setter(Control.BorderBrushProperty,Brush(0)));style.Setters.Add(new Setter(Control.BorderThicknessProperty,new Thickness(0)));style.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(4)));style.Setters.Add(new Setter(Control.CornerRadiusProperty,new CornerRadius(12)));
            if(flyout is Flyout f){if(!styled)f.FlyoutPresenterStyle=style;if(f.Content is FrameworkElement content){Apply(content);if(content is Border border){border.Background=Brush(0);border.BorderThickness=new(0);border.Padding=new(0);}if(content is Panel panel)panel.Background=Brush(0);foreach(var b in UiElements.Descendants(content).OfType<Button>()){b.Height=double.NaN;b.MinHeight=40;b.Width=double.NaN;b.MinWidth=136;b.Background=Brush(0);b.BorderThickness=new(0);b.CornerRadius=new(6);b.HorizontalContentAlignment=HorizontalAlignment.Left;}}}
            if(flyout is MenuFlyout m){if(!styled)m.MenuFlyoutPresenterStyle=style;foreach(var item in m.Items){Resources(item);item.Foreground=Brush(p.Text);}}
            if(anchor?.XamlRoot is {} xaml)foreach(var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(xaml))foreach(var presenter in new[]{popup.Child}.Concat(UiElements.Descendants(popup.Child)).OfType<Control>().Where(c=>c is FlyoutPresenter or MenuFlyoutPresenter)){presenter.RequestedTheme=Dark(anchor)?ElementTheme.Dark:ElementTheme.Light;presenter.Background=Brush(p.Surface);presenter.Foreground=Brush(p.Text);presenter.BorderBrush=Brush(0);presenter.BorderThickness=new(0);presenter.Padding=new(4);}
            styled=true;
        }
        state.Paint=Paint;
        flyout.Opening+=(_,_)=>Paint();flyout.Opened+=(_,_)=>Paint();Paint();
    }
    internal static void Ancestors(FrameworkElement card)
    {for(DependencyObject? n=VisualTreeHelper.GetParent(card);n!=null;n=VisualTreeHelper.GetParent(n))if(n is ScrollViewer scroll)Row(scroll);}
    internal static void Row(ScrollViewer scroll)
    {
        if(scroll.HorizontalScrollBarVisibility!=ScrollBarVisibility.Hidden||scroll.VerticalScrollBarVisibility!=ScrollBarVisibility.Disabled)return;
        // Disable native horizontal gestures, while ChangeView remains available
        // to the existing arrow handlers. Never translate a wheel into row motion.
        scroll.HorizontalScrollMode=ScrollMode.Disabled;
        if(Rows.TryGetValue(scroll,out _))return;Rows.Add(scroll,new());
        // A disabled horizontal gesture already lets vertical wheel input bubble
        // to the native outer ScrollViewer. Keep its animation, accumulated
        // destination and system wheel settings instead of synthesizing offsets.
        void Wheel(object sender,PointerRoutedEventArgs e){if(e.GetCurrentPoint(scroll).Properties.IsHorizontalMouseWheel)e.Handled=true;}
        // Only horizontal wheel input is consumed before the class handler.
        if(scroll.Content is UIElement content)content.AddHandler(UIElement.PointerWheelChangedEvent,new PointerEventHandler(Wheel),true);
        scroll.AddHandler(UIElement.PointerWheelChangedEvent,new PointerEventHandler((sender,e)=>{if(!e.Handled)Wheel(sender,e);}),true);
    }
}
