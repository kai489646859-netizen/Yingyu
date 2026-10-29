using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;

namespace Yingyu.Update;

// Presentation adapter for the supplied desktop references. Moves the original
// controls; media requests, commands, selection and persistence stay in the host.
internal static partial class ReferenceAppearance
{
    static readonly ConditionalWeakTable<FrameworkElement, State> States = new();
    internal static void Apply(FrameworkElement page) => States.GetValue(page, p => new State(p)).Apply();
    internal static void FocusSearch(FrameworkElement page){var state=States.GetValue(page,p=>new State(p));state.ShowSearch();}
    // Retain the backdrop loader for later use; current design uses its existing wash.
    internal static bool WantsDetailBackground(FrameworkElement page)=>false;
    internal static bool UsesInlineSearch(FrameworkElement page)=>States.TryGetValue(page,out var state)&&state.InlineSearch();
    internal static void Artwork(FrameworkElement page, Grid card)
    {
        if (States.TryGetValue(page, out var state)) state.HomeArtwork(card);
    }
    internal static readonly uint Accent = 0xFF249DDB;
    static readonly BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    static SolidColorBrush Brush(uint color) => DesktopVisuals.Brush(color);
    sealed partial class State
    {
        readonly FrameworkElement page;
        DesktopThemePalette Palette=>ReferenceSurfaces.Palette(page);
        bool Dark=>ReferenceSurfaces.Dark(page);
        readonly Grid background = new() { Name = "ReferenceAtmosphere", IsHitTestVisible = false };
        readonly Image wallpaper = new() { Name = "ReferenceWallpaper", Stretch = Stretch.UniformToFill, IsHitTestVisible = false };
        readonly Image capture = new() { Name = "ReferenceWallpaperSource", Stretch = Stretch.UniformToFill, IsHitTestVisible = false };
        readonly Border tint = new() { IsHitTestVisible = false };
        readonly Grid toolbar = new() { Name = "ReferenceTopBar" };
        readonly StackPanel genreChips = new() { Name = "ReferenceGenreChips", Spacing = 6 };
        string? genreKey;
        readonly Button searchButton=new(){Name="ReferenceSearchButton",Content=new FontIcon{Glyph="\uE721",FontSize=20}};
        readonly Border searchHost=new(){Name="ReferenceSearchHost",HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Top,Visibility=Visibility.Collapsed};

        object? session;

        bool attached, applying;
        bool searchExpanded;
        Border? sidebar;
        readonly SolidColorBrush iconClear=Brush(0),iconText=Brush(0),iconHover=Brush(0),iconPressed=Brush(0),iconDisabled=Brush(0);
        static void IconResource(Button button,string key,Brush brush){if(!button.Resources.ContainsKey(key)||!ReferenceEquals(button.Resources[key],brush))button.Resources[key]=brush;}

        public State(FrameworkElement page)
        {
            this.page = page;
            background.Children.Add(wallpaper); background.Children.Add(tint);
            Canvas.SetZIndex(capture,-11);
            Canvas.SetZIndex(background, -10);
            foreach (var name in new[] { "DetailView", "LibraryView", "SettingsView", "CollectionView", "SearchResultsPanel", "AccountPanelOverlay" })
                Find<FrameworkElement>(name)?.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => Queue());
            foreach (var name in new[] { "DetailBackdropImage", "DetailPosterImage" })
                if (Find<Image>(name) is { } image) { image.RegisterPropertyChangedCallback(Image.SourceProperty, (_, _) => Queue());image.ImageOpened+=(_,_)=>Queue(); }
            if (Find<TextBlock>("PageTitleText") is { } title) title.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) => Queue());
            foreach (var name in new[] { "DetailGenresText", "DetailTypeText" }) Find<TextBlock>(name)?.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) => Queue());
            searchButton.Click+=(_,_)=>ShowSearch();
            ToolTipService.SetToolTip(searchButton,"搜索片名或演员（Ctrl+F）");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(searchButton,"搜索片名或演员");
            page.Unloaded += (_, _) => { wallpaper.Source = capture.Source = null; searchExpanded=false; };
            page.SizeChanged += (_, _) => Queue();

        }
        T? Find<T>(string name) where T : class => page.GetType().GetField(name, Flags)?.GetValue(page) as T ?? page.FindName(name) as T;
        bool queued;
        internal void ShowSearch(){try{if(InlineSearch()){Find<AutoSuggestBox>("SearchBox")?.Focus(FocusState.Keyboard);return;}OpenSearchPage();}catch(Exception error){Warn(error);try{CloseSearchPage(true);}catch(Exception){}}}
        void Queue()
        {
            if(queued||!page.IsLoaded)return;
            queued=true;
            try{if(!page.DispatcherQueue.TryEnqueue(()=>{queued=false;try{if(page.IsLoaded)Apply();}catch(Exception e){Warn(e);}}))queued=false;}
            catch(Exception error){queued=false;Warn(error);}
        }
        static void Warn(Exception e) { try { PlaybackTransport.Write("Warning", "Desktop.Appearance", "参考外观未完全应用；" + e.GetType().Name); } catch { } }
        static void Move(DependencyObject from, Panel to, UIElement element)
        { if (to.Children.Contains(element)) return; if (DesktopShellActions.Detach(from, element)) { if(element is FrameworkElement control){Grid.SetRow(control, 0); Grid.SetColumn(control, 0);} to.Children.Add(element); } }
        void PlaceChrome(Grid shell,bool reference)
        {
            if(sidebar==null)return;
            sidebar.Visibility=reference?Visibility.Collapsed:Visibility.Visible;
            shell.ColumnDefinitions[0].Width=new(reference?0:page.ActualWidth is >0 and <1080?176:204);
            if(!reference){DesktopTheme.Navigation(page);DesktopShellLayout.Apply(page,DesktopTheme.Options,Palette);ReferenceSurfaces.Apply(sidebar);}
        }
        void Attach(Grid shell)
        {
            if(attached||shell.Children.OfType<Border>().FirstOrDefault(b=>b.Name=="DesktopAccountToolbar") is not {} bar||bar.Child is not StackPanel right)return;
            sidebar=shell.Children.OfType<Border>().FirstOrDefault(b=>Grid.GetColumn(b)==0&&b!=bar);if(sidebar==null)return;
            ReferenceSurfaces.WatchEpisodes(Find<FrameworkElement>("DetailEpisodesGrid"));ReferenceSurfaces.WatchEpisodes(Find<FrameworkElement>("DetailEpisodeStripItems"));
            bar.Child=null;toolbar.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});toolbar.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            Grid.SetColumn(right,1);toolbar.Children.Add(right);bar.Child=toolbar;
            if(Find<AutoSuggestBox>("SearchBox") is {} search&&DesktopShellActions.Detach(shell,search)){searchHost.Child=search;AttachSearchPage(shell);}
            right.Children.Insert(0,searchButton);
            capture.Opacity=0;shell.Children.Insert(0,capture);Grid.SetColumnSpan(capture,Math.Max(1,shell.ColumnDefinitions.Count));Grid.SetRowSpan(capture,Math.Max(1,shell.RowDefinitions.Count));
            shell.Children.Insert(0,background);Grid.SetColumnSpan(background,Math.Max(1,shell.ColumnDefinitions.Count));Grid.SetRowSpan(background,Math.Max(1,shell.RowDefinitions.Count));
            attached=true;
        }
        public void Apply()
        {
            if (applying || !page.IsLoaded || Find<Grid>("ShellGrid") is not { } shell) return;
            applying = true;
            try
            {
                Attach(shell); if (!attached) return;
                capture.Width=wallpaper.Width=shell.ActualWidth;capture.Height=wallpaper.Height=shell.ActualHeight;
                var currentSession = page.GetType().GetField("_session", Flags)?.GetValue(page);
                if (!ReferenceEquals(currentSession, session)) { CloseSearchPage(false);suggestionNames=Array.Empty<string>();suggestionWidth=0;searchOrigin.Clear();session = currentSession; wallpaper.Source=capture.Source=null; }
                shell.Background = Brush(Palette.Background);
                background.Background = Fallback();
                bool detail = Find<Grid>("DetailView")?.Visibility == Visibility.Visible;
                bool settings = Find<Grid>("SettingsView")?.Visibility == Visibility.Visible;
                if(settings&&searchExpanded)CloseSearchPage(false);
                bool reference=detail||searchExpanded;
                PlaceChrome(shell,reference);
                var bar=shell.Children.OfType<Border>().First(b=>b.Name=="DesktopAccountToolbar");
                bool fullSearch=searchExpanded&&!detail;
                bar.Visibility=fullSearch||settings?Visibility.Collapsed:Visibility.Visible;
                if(shell.RowDefinitions.Count>0)shell.RowDefinitions[0].Height=fullSearch?new GridLength(0):GridLength.Auto;
                if(Find<Button>("DetailBackButton") is {} exit)
                {
                    if(!toolbar.Children.Contains(exit))Move(shell,toolbar,exit);
                    Grid.SetColumn(exit,0);exit.HorizontalAlignment=HorizontalAlignment.Right;
                    exit.Visibility=detail?Visibility.Visible:Visibility.Collapsed;
                    if(detail){Icon(exit);DesktopCloseButton.Apply(exit,Palette);ToolTipService.SetToolTip(exit,"退出详情");Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(exit,"退出详情");exit.IsEnabled=true;}
                }
                foreach(string name in new[]{"HomeNavButton","SettingsButton","ProfileSwitchButton","GlobalRefreshButton"})if(Find<Button>(name) is {} button)button.Visibility=detail||(settings&&(name is "SettingsButton" or "ProfileSwitchButton"))?Visibility.Collapsed:Visibility.Visible;
                searchButton.Visibility=!detail&&!searchExpanded&&!settings?Visibility.Visible:Visibility.Collapsed;
                double inset=Math.Clamp(page.ActualWidth*.04,24,74);
                foreach(var name in new[]{"LibraryView","DetailView","CollectionView"})if(Find<Grid>(name) is {} view)view.Background=Brush(reference?0:Palette.Background);
                bar.Padding=detail?new(24,12,32,12):new(24,6,24,6);bar.MinHeight=detail?64:0;bar.BorderThickness=new(0,0,0,detail?0:1);bar.Background=detail?Brush(0):DesktopMaterial.Surface(DesktopTheme.Options,Palette);
                Icon(searchButton);
                if (Find<AutoSuggestBox>("SearchBox") is { } search)
                {
                    searchHost.Visibility=searchExpanded||InlineSearch()?Visibility.Visible:Visibility.Collapsed;searchHost.Margin=new(24,20,24,0);searchHost.Width=Math.Min(866,Math.Max(180,page.ActualWidth-80));searchHost.Background=Brush(0);searchHost.BorderThickness=new(0);searchHost.CornerRadius=new(22);
                    search.Width=double.NaN;search.MaxWidth=double.PositiveInfinity;search.MinWidth=120;
                    search.VerticalContentAlignment=VerticalAlignment.Center;search.Padding=new(0);search.FontSize=14;search.Height = 42; search.MinHeight=42; search.Margin = new(0); search.HorizontalAlignment = HorizontalAlignment.Stretch; search.CornerRadius = new(22);
                    search.RequestedTheme=Dark?ElementTheme.Dark:ElementTheme.Light; search.Background = Brush(0); search.Foreground = Brush(Palette.Text); search.BorderBrush = Brush(Palette.Outline); search.BorderThickness = new(1);
                    foreach(var input in UiElements.Descendants(search).OfType<TextBox>()){
                        input.VerticalContentAlignment=VerticalAlignment.Center;input.Padding=new(16,0,16,0);input.FontSize=14;input.MinHeight=42;input.Height=42;
                        input.RequestedTheme=Dark?ElementTheme.Dark:ElementTheme.Light;input.Foreground=Brush(Palette.Text);input.Background=Brush(Palette.Surface);input.CornerRadius=new(22);
                        foreach(var suffix in new[]{"","PointerOver","Focused","Disabled"}){input.Resources["TextControlBackground"+suffix]=Brush(Palette.Surface);input.Resources["TextControlForeground"+suffix]=Brush(Palette.Text);input.Resources["TextControlPlaceholderForeground"+suffix]=Brush(Palette.Secondary);}
                    }
                }
                if(Find<AutoSuggestBox>("SearchBox") is {} finalSearch)DesktopReadability.Search(finalSearch,Palette);
                if (Find<Grid>("LibraryHeaderGrid") is { } header) header.Margin = reference?new(inset, searchExpanded?84:4, inset, 16):new(24,20,24,14);
                if (Find<ScrollViewer>("MainContentScrollViewer") is { } scroll) scroll.Padding = reference?new(inset,0,inset,32):new(24,0,24,28);
                if (Find<TextBlock>("PageTitleText") is { } title) { title.FontSize = reference?22:27; title.Foreground = Brush(Palette.Text); }
                if (Find<TextBlock>("GreetingText") is { } greeting) { greeting.FontSize = 12; greeting.Foreground = Brush(Palette.Secondary); }
                foreach (var element in new FrameworkElement?[] { Find<ItemsControl>("HomeLibrarySectionsControl"), Find<StackPanel>("ResumeSection"), Find<StackPanel>("SearchResultsPanel") }.OfType<FrameworkElement>())
                    foreach (var text in UiElements.Descendants(element).OfType<TextBlock>().Where(t=>!DesktopCardSurface.Owns(t))) { text.Foreground = Brush(Palette.Text); if (text.FontSize >= 18) { text.FontSize = reference?22:20; text.FontWeight = reference?Microsoft.UI.Text.FontWeights.Bold:Microsoft.UI.Text.FontWeights.SemiBold; } }
                if(Find<Grid>("DetailView") is {} scene)ReferenceSurfaces.Apply(scene);
                if(searchExpanded&&Find<StackPanel>("SearchResultsPanel") is {} results)ReferenceSurfaces.Apply(results);

                if(Find<Grid>("AccountPanelOverlay") is {} account){ReferenceSurfaces.Apply(account);foreach(var panel in account.Children.OfType<Border>())panel.Background=Brush(Palette.Surface);}
                if (detail) Detail(inset);
                SearchLayout(inset);
                background.Visibility=Visibility.Collapsed;
                capture.Visibility=Visibility.Collapsed;
                capture.Source=wallpaper.Source=null;
                DesktopRefinement.Apply(page,Palette,reference,detail,settings);
                PlaceInlineSearch();
            }
            finally { applying = false; }
        }
        void Icon(Button button)
        {
            if(ReferenceEquals(button,searchButton))DesktopInputBehavior.Toolbar(button);
            button.Width = 40; button.MinWidth = 40; button.Height = 40; button.MinHeight = 40; button.Padding = new(0); button.Margin = new(0); button.CornerRadius = new(20); button.BorderThickness = new(0);
            iconText.Color=DesktopMaterial.Color(Palette.Text);iconHover.Color=DesktopMaterial.Color(Palette.Hover);iconPressed.Color=DesktopMaterial.Color(Palette.Selection);iconDisabled.Color=DesktopMaterial.Color(Palette.Secondary);
            button.Background=iconClear;button.Foreground=iconText;button.HorizontalContentAlignment=HorizontalAlignment.Center;
            if(button.Content is FontIcon glyph)glyph.Foreground=iconText;
            foreach (string key in new[] { "ButtonForeground", "ButtonForegroundPointerOver", "ButtonForegroundPressed" }) IconResource(button,key,iconText);
            IconResource(button,"ButtonBackgroundPointerOver",iconHover);IconResource(button,"ButtonBackgroundPressed",iconPressed);
            IconResource(button,"ButtonForegroundDisabled",iconDisabled);IconResource(button,"ButtonBackgroundDisabled",iconClear);
        }
        void Detail(double inset)
        {
            if (Find<Grid>("DetailView") is not { } view || Find<Grid>("DetailHeroLayout") is not { } hero || Find<StackPanel>("DetailHeroText") is not { } text ) return;
            foreach (var rectangle in UiElements.Descendants(view).OfType<Microsoft.UI.Xaml.Shapes.Rectangle>().Where(r => r.Fill is LinearGradientBrush)) rectangle.Opacity = 0;
            foreach (var name in new[] { "DetailBackdropImage", "DetailAmbientImage" }) if (Find<Image>(name) is { } image) image.Opacity = 0;
            if (Find<Grid>("DetailPageLayout") is { } layout) layout.Padding = new(inset, 15, inset, 46);
            bool compact = page.ActualWidth < 760; double width = compact ? 184 : Math.Clamp(page.ActualWidth * .19, 220, 286);
            hero.Margin = new(0); hero.MinHeight = width * 1.5; hero.ColumnSpacing = compact ? 20 : 25;
            while (hero.ColumnDefinitions.Count < 2) hero.ColumnDefinitions.Add(new());
            hero.ColumnDefinitions[0].Width = new(width); hero.ColumnDefinitions[1].Width = new(1, GridUnitType.Star);
            if(DetailArtwork.Frame(page) is not {} poster)return;
            double posterHeight=width*1.5;
            if(Find<Image>("DetailPosterImage") is {} detailPoster){detailPoster.Stretch=Stretch.Uniform;detailPoster.HorizontalAlignment=HorizontalAlignment.Stretch;detailPoster.VerticalAlignment=VerticalAlignment.Stretch;detailPoster.Width=detailPoster.Height=double.NaN;if(detailPoster.Source is BitmapSource{PixelWidth:>0,PixelHeight:>0} pixels)posterHeight=width*pixels.PixelHeight/pixels.PixelWidth;}
            poster.BorderThickness=new(0);poster.Padding=new(0);poster.Background=Brush(0);poster.Width = width; poster.Height = posterHeight; poster.Visibility = Visibility.Visible; poster.CornerRadius = new(Math.Min(DesktopTheme.Options.Radius,12)); poster.VerticalAlignment = VerticalAlignment.Top; poster.Margin = new(0); Grid.SetColumn(poster, 0); Grid.SetRow(poster, 0);
            Grid.SetColumn(text, 1); Grid.SetRow(text, 0); text.Margin = new(0); text.Spacing = 12; text.VerticalAlignment = VerticalAlignment.Top;text.MaxWidth=double.PositiveInfinity;text.HorizontalAlignment=HorizontalAlignment.Stretch;
            if (Find<TextBlock>("DetailTitleText") is { } title) { title.FontSize = compact ? 25 : 29; title.FontWeight = Microsoft.UI.Text.FontWeights.Bold; title.Margin = new(0); }
            foreach (var label in UiElements.Descendants(text).OfType<TextBlock>()) label.Foreground = Brush(Palette.Text);
            foreach (var name in new[] { "DetailMetadataText", "DetailGenresText", "DetailTypeText" }) if (Find<TextBlock>(name) is { } label) { label.FontSize = 14; label.Foreground = Brush(Palette.Secondary); }
            Genres(text, Math.Max(180, page.ActualWidth - inset * 2 - width - hero.ColumnSpacing));
            if(Find<Button>("DetailOverviewToggle") is {} more){more.Background=Brush(0);more.BorderThickness=new(0);more.FontSize=16;more.Foreground=Brush(Palette.Secondary);more.Padding=new(0,4,0,4);more.HorizontalAlignment=HorizontalAlignment.Left;}
            if (Find<TextBlock>("DetailOverviewText") is { } overview) { overview.FontSize = 15; overview.LineHeight = 25; overview.MaxWidth = double.PositiveInfinity; overview.Margin = new(0, 4, 0, 0); }
            if (Find<Grid>("DetailAllActions") is { } actions && Find<TextBlock>("DetailOverviewText") is { } synopsis)
            {
                if (!text.Children.Contains(actions)) Move(view, text, actions);
                // The XBF can keep the toggle in the old action container.
                // Move the original button with its original click handler first.
                UIElement anchor=synopsis;
                if(Find<Button>("DetailOverviewToggle") is {} toggle)
                {
                    if(!text.Children.Contains(toggle))Move(view,text,toggle);
                    if(text.Children.Contains(toggle))
                    {
                        text.Children.Remove(toggle);text.Children.Insert(text.Children.IndexOf(synopsis)+1,toggle);anchor=toggle;
                    }
                }
                int at = text.Children.IndexOf(anchor); int current = text.Children.IndexOf(actions);
                if (at >= 0 && current != at+1) { text.Children.Remove(actions);text.Children.Insert(text.Children.IndexOf(anchor)+1,actions); }
                actions.Margin = new(0, 6, 0, 4); actions.ColumnSpacing = 8;
                if(Find<StackPanel>("DetailDesktopActions") is {} desktop){bool stack=page.ActualWidth<1100;while(actions.RowDefinitions.Count<2)actions.RowDefinitions.Add(new(){Height=GridLength.Auto});Grid.SetColumn(desktop,stack?0:1);Grid.SetRow(desktop,stack?1:0);Grid.SetColumnSpan(desktop,stack?Math.Max(1,actions.ColumnDefinitions.Count):1);actions.RowSpacing=8;}
            }
            foreach (var name in new[] { "DetailPlayButton", "DetailWatchButton", "DetailFavoriteButton", "DetailMoreButton", "DetailSourceButton" }) if (Find<Button>(name) is { } button)
            {
                bool icon = name is "DetailFavoriteButton" or "DetailMoreButton";
                bool primary=name=="DetailPlayButton";uint foreground=primary?(Dark?Palette.Background:0xFFFFFFFF):Palette.Text;
                button.Height = 44; button.MinHeight = 44; button.CornerRadius = new(Math.Min(DesktopTheme.Options.Radius,12)); button.BorderThickness = new(0); button.Background = Brush(primary?Palette.Accent:Palette.Selection); button.Foreground = Brush(foreground);
                button.Padding = icon ? new(10) : new(18, 8, 18, 8); button.MinWidth = icon ? 44 : 110; button.Width = icon ? 44 : double.NaN;
                foreach (var label in UiElements.Descendants(button).OfType<TextBlock>()) label.Foreground = Brush(foreground);
                foreach (var glyph in UiElements.Descendants(button).OfType<FontIcon>()) glyph.Foreground = Brush(primary?foreground:name is "DetailFavoriteButton" or "DetailWatchButton" ? Palette.Accent : Palette.Text);
            }
            if (Find<Border>("EpisodesSection") is { } episodes) { episodes.Margin = new(0, 28, 0, 0); episodes.Padding = new(0); episodes.Background = Brush(0); episodes.BorderThickness = new(0); }
            DesktopDetailLayout.Apply(page);
        }
        void Genres(StackPanel text, double available)
        {
            if (Find<TextBlock>("DetailGenresText") is not { } genres || Find<TextBlock>("DetailTypeText") is not { } type) return;
            if (!text.Children.Contains(genreChips)) { int index = text.Children.IndexOf(genres); if (index < 0) return; text.Children.Insert(index, genreChips); }
            genres.Visibility = type.Visibility = Visibility.Collapsed;
            string key = type.Text + "|" + genres.Text + "|" + Math.Round(available)+"|"+Palette;
            if (key == genreKey) return; genreKey = key; genreChips.Children.Clear();
            var values = new[] { type.Text }.Concat(genres.Text.Split(new[] { '·', ',', '，', '、' }, StringSplitOptions.RemoveEmptyEntries)).Select(v => v.Trim()).Where(v => v.Length > 0).Distinct();
            StackPanel? row = null; double used = 0;
            foreach (var value in values)
            {
                var label = new TextBlock { Text = value, FontSize = 14, Foreground = Brush(Palette.Text), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
                var chip = new Border { Child = label, Padding = new(12, 3, 12, 3), CornerRadius = new(16), BorderThickness = new(1), BorderBrush = Brush(Palette.Outline), Background = Brush(Palette.Hover), MaxWidth = available };
                chip.Measure(new Size(available, 100)); double itemWidth = chip.DesiredSize.Width;
                if (row == null || used + 8 + itemWidth > available) { row = new() { Orientation = Orientation.Horizontal, Spacing = 8 }; genreChips.Children.Add(row); used = 0; }
                row.Children.Add(chip); used += itemWidth + (used > 0 ? 8 : 0); ToolTipService.SetToolTip(chip, value);
            }
            genreChips.Visibility = genreChips.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        public void HomeArtwork(Grid card) { } // Shared gradient needs no poster capture or CPU blur.
        Brush Fallback()
        {
            return DesktopMaterial.Atmosphere(DesktopTheme.Options,Palette);
        }
    }
}

