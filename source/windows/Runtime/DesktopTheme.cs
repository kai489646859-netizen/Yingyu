using System.Reflection;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Yingyu.Update;

public static class DesktopTheme
{
    const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    static readonly ConditionalWeakTable<object, State> Pages = new();
    static readonly List<WeakReference<State>> LivePages = new();
    static DesktopThemeOptions? options;
    public static DesktopThemeOptions Options => options ??= DesktopThemeStore.Load(Path.Combine(CachePaths.UserDataRoot, "desktop-theme.json"));
    static string StorePath => Path.Combine(CachePaths.UserDataRoot, "desktop-theme.json");
    static void Report(Exception error)
    { try { PlaybackTransport.Write("Warning", "Desktop.Theme", "桌面外观未完全应用，保留可用界面；异常类型=" + error.GetType().Name); } catch (Exception) { } }
    public static void Configure(object page)
    {
        try { if(page is FrameworkElement inputRoot)DesktopInputBehavior.Apply(inputRoot);DesktopPeople.Configure(page);Pages.GetValue(page, key => { var state = new State((FrameworkElement)key); LivePages.Add(new(state)); return state; }); }
        catch (Exception error) { Report(error); }
    }
    public static AppThemePreference WindowTheme(AppThemePreference inherited) => Options.Mode switch
    { 1 => AppThemePreference.Light, 2 => AppThemePreference.Dark, _ => AppThemePreference.System };
    public static bool ReduceMotion(bool inherited) => inherited || Options.ReducedMotion;
    public static PosterGridMetrics Metrics(double availableWidth, double rasterizationScale)
    {
        var grid = DesktopThemeGrid.Resolve(Options, availableWidth, rasterizationScale);
        return new(grid.ItemWidth, grid.ItemHeight, grid.CardWidth, grid.ArtworkHeight, grid.Columns);
    }
    public static void Card(object page, object? candidate)
    {
        try
        {
            if (candidate is FrameworkElement element && Pages.TryGetValue(page, out var state)) state.TrackCard(element);
        }
        catch (Exception error) { Report(error); }
    }
    public static void Detail(object page)
    {
        try { if (Pages.TryGetValue(page, out var state)) state.Detail(); }
        catch (Exception error) { Report(error); }
    }
    public static void Navigation(object page)
    {
        try { if (Pages.TryGetValue(page, out var state)) state.Navigation(); }
        catch (Exception error) { Report(error); }
    }
    static Color Color(uint value) => Windows.UI.Color.FromArgb((byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value);
    static SolidColorBrush Brush(uint value) => new(Color(value));
    sealed class CardState
    {
        public CardState(FrameworkElement element)
        {
            Element = new(element);
            // Capture the immutable XBF template before the surface adapter
            // replaces its children or imposes desktop dimensions.
            if(element is Grid grid&&grid.RowDefinitions.FirstOrDefault()?.Height is {IsAbsolute:true,Value:>0} row)
                NativeLandscapeWidth=row.Value*16/9;
            if(double.IsFinite(element.Width)&&element.Width>0)NativeLandscapeWidth=element.Width;
            else if(NativeLandscapeWidth<=0&&element.ActualWidth>0)NativeLandscapeWidth=element.ActualWidth;
        }
        public WeakReference<FrameworkElement> Element;
        public double NativeLandscapeWidth;
        
        public INotifyPropertyChanged? Source;
        public PropertyChangedEventHandler? Changed;
        public bool PaintQueued,FullPaint;
    }
    sealed class State
    {
        readonly FrameworkElement page;
        readonly ConditionalWeakTable<FrameworkElement, CardState> registered = new();
        readonly List<CardState> cards = new();
        readonly Dictionary<string, SolidColorBrush> nativeBrushes = new();
        readonly TextBlock status = new() { FontSize = 12, MinHeight = 18, TextWrapping = TextWrapping.Wrap };
        readonly DesktopThemeSystemEvents system = new(Report);
        DesktopThemeSystemSnapshot systemSnapshot;
        bool applying, settingsAttached;
        DesktopThemePalette palette;
        public State(FrameworkElement page)
        {
            this.page = page;
            palette = DesktopThemePalette.Resolve(Options, Options.Mode == 2);
            // Publish native input colors before their templates are realized.
            // Later updates mutate these same brush instances across theme saves.
            NativeResources(Application.Current.Resources);
            // Each supported callback has its own exception boundary. There is
            // no optional system-event subscription during construction or load.
            system.Run("register-loaded", () => page.Loaded += OnLoaded);
            system.Run("register-unloaded", () => page.Unloaded += OnUnloaded);
            system.Run("register-theme", () => page.ActualThemeChanged += OnActualThemeChanged);
            system.Run("register-size", () => page.SizeChanged += OnSizeChanged);
            system.Run("register-focus", () => page.GotFocus += OnGotFocus);
            system.Run("initial-load", () => { if (page.IsLoaded) OnLoaded(page, null!); });
        }
        void OnLoaded(object sender, RoutedEventArgs args)
        {
            system.Run("loaded-settings", BuildSettings);
            system.Run("loaded-theme", Apply);
            system.Run("loaded-resume", () => ResumeSync.Home(page));
        }
        void OnUnloaded(object sender, RoutedEventArgs args) => system.Run("unloaded", () =>
        {
            foreach (var card in cards.ToArray()) system.Run("unloaded-card", () => UnbindCard(card));
            cards.Clear();
        });
        void OnActualThemeChanged(FrameworkElement sender, object args) => system.Run("actual-theme", () =>
        { if (!applying && (Options.Mode == 0 || system.Read() != systemSnapshot)) Apply(); });
        void OnSizeChanged(object sender, SizeChangedEventArgs args) => system.Run("page-size", () =>
        { if (Math.Abs(args.NewSize.Width - args.PreviousSize.Width) > 1) { Layout(); Detail(); } });
        void OnGotFocus(object sender, RoutedEventArgs args) => system.Run("page-focus", () =>
        { if (!applying && page.IsLoaded) { if (system.Read() != systemSnapshot) Apply(); ResumeSync.Home(page); } });
        T? Find<T>(string name) where T : class => page.GetType().GetField(name, Flags)?.GetValue(page) as T ?? page.FindName(name) as T;
        void SetBrush(ResourceDictionary resources, string key, uint value)
        {
            try
            {
                if (resources.ContainsKey(key) && resources[key] is SolidColorBrush existing) existing.Color = Color(value);
                else resources[key] = Brush(value);
            }
            catch (ArgumentException) { resources[key] = Brush(value); }
        }
        void NativeBrush(ResourceDictionary resources, string key, uint value)
        {
            // Framework theme dictionaries can return frozen system brushes.
            // Own each override locally instead of mutating those shared objects.
            if (nativeBrushes.TryGetValue(key, out var brush)) brush.Color = Color(value);
            else { brush = Brush(value); nativeBrushes.Add(key, brush); }
            // Share one owned brush per semantic key across the theme scopes.
            // A native template may retain a prior dictionary's brush instance.
            resources[key] = brush;
        }
        void NativeResources(ResourceDictionary resources)
        {
            foreach (string name in new[] { "ToggleSwitchFillOn", "ToggleSwitchFillOnPointerOver", "ToggleSwitchFillOnPressed",
                "ToggleSwitchStrokeOn", "ToggleSwitchStrokeOnPointerOver", "ToggleSwitchStrokeOnPressed",
                "ComboBoxBorderBrushFocused", "TextControlBorderBrushFocused", "AutoSuggestBoxBorderBrushFocused",
                "ListViewItemSelectionIndicatorBrush" }) NativeBrush(resources, name, palette.Accent);
            foreach (string name in new[] { "ComboBoxItemBackgroundSelected", "ComboBoxItemBackgroundSelectedPointerOver", "ComboBoxItemBackgroundSelectedPressed" })
                NativeBrush(resources, name, palette.Selection);
            foreach (string name in new[] { "ComboBoxItemForegroundSelected", "ComboBoxItemForegroundSelectedPointerOver", "ComboBoxItemForegroundSelectedPressed" })
                NativeBrush(resources, name, palette.Text);
            foreach (string name in new[] { "ToggleSwitchKnobFillOn", "ToggleSwitchKnobFillOnPointerOver", "ToggleSwitchKnobFillOnPressed" })
                NativeBrush(resources, name, systemSnapshot.HighContrast ? palette.Background : Options.Mode == 2 || Options.Mode == 0 && page.ActualTheme == ElementTheme.Dark ? 0xFF16181D : 0xFFFFFFFF);
        }
        void Resources(ResourceDictionary resources)
        {
            NativeResources(resources);
            foreach (var pair in new (string, uint)[]
            {
                ("AppBackgroundBrush",palette.Background),("SettingsBackgroundBrush",palette.Background),
                ("CardBrush",palette.Surface),("PrimaryTextBrush",palette.Text),("SecondaryTextBrush",palette.Secondary),
                ("SidebarSurfaceBrush",palette.Sidebar),("ChromeSurfaceBrush",palette.Sidebar),
                ("ToolbarButtonBrush",palette.Surface),("ToolbarButtonHoverBrush",palette.Hover),
                ("SubtleSurfaceBrush",palette.Hover),("SubtleBorderBrush",palette.Outline),
                ("EpisodeTileBrush",palette.Surface),("EpisodeTileBorderBrush",palette.Outline),
                ("AvatarBrush",palette.Selection),("PanelBrush",palette.Surface),("PanelBorderBrush",palette.Outline),
                ("CardOutlineBrush",palette.Outline),("DetailPrimaryTextBrush",palette.Text),
                ("DetailSecondaryTextBrush",palette.Secondary),("DetailTileBrush",palette.Surface),
                ("DetailTileBorderBrush",palette.Outline),("DetailSubtleSurfaceBrush",palette.Hover),
                ("DetailSectionSurfaceBrush",palette.Surface),("DetailEyebrowBrush",palette.Accent),
                ("LoginCardBrush",palette.Surface),("LoginCardBorderBrush",palette.Outline),
                ("AccentBrush",palette.Accent),("SidebarSelectionBrush",palette.Selection),
                ("SidebarSelectionBorderBrush",palette.Accent),
            }) SetBrush(resources, pair.Item1, pair.Item2);
            foreach (string name in new[] { "AppBackgroundColor", "SurfaceColor" }) resources[name] = Color(name == "SurfaceColor" ? palette.Surface : palette.Background);
            foreach (string prefix in new[] { "DetailGradient", "DetailSideGradient", "LoginGradient" })
            {
                resources[prefix + "StartColor"] = Color(palette.Background);
                resources[prefix + "MiddleColor"] = Color((palette.Background & 0x00FFFFFF) | 0xD9000000);
                resources[prefix + "EndColor"] = Color((palette.Background & 0x00FFFFFF) | 0x30000000);
            }
            resources["DetailBottomFadeStartColor"] = Color(palette.Background & 0x00FFFFFF);
            resources["DetailBottomFadeEndColor"] = Color(palette.Background);
        }
        void Apply()
        {
            if (applying) return;
            applying = true;
            try
            {
                // Set the window's inherited mode before reading ActualTheme.
                // In System mode the page can otherwise still inherit the
                // previous explicit Light/Dark mode during this same callback.
                var app = Application.Current;
                app.GetType().GetMethod("ApplyTheme", Flags)?.Invoke(app, new object[] { WindowTheme(AppThemePreference.System) });
                page.RequestedTheme = Options.Mode switch { 1 => ElementTheme.Light, 2 => ElementTheme.Dark, _ => ElementTheme.Default };
                bool dark = Options.Mode == 2 || Options.Mode == 0 && page.ActualTheme == ElementTheme.Dark;
                palette = DesktopThemePalette.Resolve(Options, dark);
                systemSnapshot = system.Read();
                if (systemSnapshot is { HighContrast: true, Background: { } background, Foreground: { } text })
                {
                    palette = new(background, background, background, text, text, text, text, background, background);
                }
                // Existing XBF ThemeResource and StaticResource users share these
                // objects. No composition effects, bitmap filters or video layers.
                var appResources = Application.Current.Resources;
                Resources(appResources);
                foreach (var dictionary in appResources.ThemeDictionaries.Values.OfType<ResourceDictionary>()) Resources(dictionary);
                Resources(page.Resources);
                // Refresh native title-bar colors after publishing the palette.
                // The applying guard suppresses theme-event re-entry throughout.
                app.GetType().GetMethod("ApplyTheme", Flags)?.Invoke(app, new object[] { WindowTheme(AppThemePreference.System) });
                if (page is Control control) { control.Background = Brush(palette.Background); control.Foreground = Brush(palette.Text); }
                if (Find<Grid>("ShellGrid") is { } shell) shell.Background = DesktopMaterial.Atmosphere(Options,palette);
                foreach (string name in new[] { "AccountSettingsSection", "AppearanceSettingsSection", "ExperienceSettingsSection", "CacheSettingsSection", "DiagnosticsSettingsSection", "AboutSettingsSection", "EpisodesSection" })
                    if (Find<Border>(name) is { } section)
                    { section.Background = Brush(palette.Surface); section.BorderBrush = Brush(palette.Outline); section.BorderThickness = new Thickness(1); section.CornerRadius = new(Options.Radius + (Options.Radius > 0 ? 4 : 0)); section.Padding = new Thickness(20); }
                foreach (string name in new[] { "PageTitleText", "ContentSectionTitle" })
                    if (Find<TextBlock>(name) is { } title) { title.FontSize = name == "PageTitleText" ? 27 : 20; title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; title.Foreground = Brush(palette.Text); }
                if (Find<TextBlock>("GreetingText") is { } greeting) { greeting.FontSize = 12; greeting.Foreground = Brush(palette.Secondary); }
                foreach (string name in new[] { "AccountPanelUserText", "AccountPanelServerText", "SearchResultsCount", "SidebarVersionText" })
                    if (Find<TextBlock>(name) is { } label)
                    { label.FontSize = name == "AccountPanelUserText" ? 17 : 12; label.Foreground = Brush(name == "AccountPanelUserText" ? palette.Text : palette.Secondary); }
                foreach (string name in new[] { "SettingsButton", "ProfileSwitchButton", "GlobalRefreshButton", "RefreshLibraryButton", "BackToTopButton" })
                    if (Find<Button>(name) is { } button) Button(button, false);
                if (Find<AutoSuggestBox>("SearchBox") is { } search)
                { search.CornerRadius = new(Math.Min(Options.Radius, 10)); search.Height = 36; search.MinWidth = 180; search.MaxWidth = Math.Clamp(page.ActualWidth-720,180,440); search.Width=search.MaxWidth; search.PlaceholderText = "搜索片名或演员…"; search.Background = Brush(palette.Surface); }
                Layout(); Navigation(); Detail();
                cards.RemoveAll(card => !card.Element.TryGetTarget(out var element) || !element.IsLoaded);
                foreach (var card in cards.ToArray()) if (card.Element.TryGetTarget(out var element)) StyleCard(element);
                // Reuse the host's anchor-preserving responsive grid update.
                if (Find<GridView>("LatestGrid") is { ActualWidth: > 0 } latest)
                    Access.Call(page, "ApplyResponsivePosterLayout", latest.ActualWidth);
                if (Find<GridView>("CollectionGrid") is { ItemsPanelRoot: ItemsWrapGrid wrap, ActualWidth: > 0 } collection)
                    wrap.ItemWidth = Metrics(collection.ActualWidth - 16, page.XamlRoot?.RasterizationScale ?? 1).ItemWidth;
            }
            catch (Exception error) { Report(error); status.Text = "外观未完全应用，部分控件保留原样。"; }
            finally { applying = false; }
        }
        void Layout()
        {
            DesktopLogin.Apply(page,palette);
            DesktopSettings.Layout(page);
            DesktopNavigation.Update(page);
            if(Find<AutoSuggestBox>("SearchBox") is {} search)
            {search.MaxWidth=Math.Clamp(page.ActualWidth-720,180,440);search.Width=search.MaxWidth;}
            if (Find<Grid>("ShellGrid") is { ColumnDefinitions.Count: > 0 } shell)
                shell.ColumnDefinitions[0].Width = new GridLength(page.ActualWidth is > 0 and < 1080 ? 176 : 204);
            if (Find<Grid>("LibraryHeaderGrid") is { } header) header.Margin = new Thickness(24, 20, 24, 14);
            if (Find<ScrollViewer>("MainContentScrollViewer") is { } scroll) scroll.Padding = new Thickness(24, 0, 24, 28);
            DesktopShellLayout.Apply(page, Options, palette);
            LogCenterLauncher.ApplyTheme(page);
            ReferenceAppearance.Apply(page);
        }
        void Button(Button button, bool selected)
        {
            foreach(string key in new[]{"ButtonForeground","ButtonForegroundPointerOver","ButtonForegroundPressed"})button.Resources[key]=Brush(palette.Text);
            button.Resources["ButtonBackgroundPointerOver"]=Brush(palette.Hover);button.Resources["ButtonBackgroundPressed"]=Brush(palette.Selection);
            button.CornerRadius = new(Math.Min(Options.Radius, 10));
            button.Background = Brush(selected ? palette.Selection : 0x00000000);
            button.Foreground = Brush(selected ? palette.Accent : palette.Text);
            button.BorderBrush = Brush(selected ? palette.Accent : 0x00000000);
            button.BorderThickness = new Thickness(3,0,0,0);
            button.Padding = new Thickness(12, 7, 12, 7);
            button.MinHeight = 38;
            foreach(var text in UiElements.Descendants(button).OfType<TextBlock>()){text.Foreground=Brush(selected?palette.Accent:palette.Text);text.FontWeight=selected?Microsoft.UI.Text.FontWeights.SemiBold:Microsoft.UI.Text.FontWeights.Normal;}
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(button,selected?"当前位置":"");
        }
        public void Navigation()
        {
            var active = page.GetType().GetField("_activeNavigation", Flags)?.GetValue(page)?.ToString();
            var library = page.GetType().GetField("_activeLibraryId", Flags)?.GetValue(page) as string;
            foreach (string name in new[] { "HomeNavButton", "FavoritesNavButton", "CollectionNavButton" })
                if (Find<Button>(name) is { } button)
                { Button(button, name == "HomeNavButton" && active == "Home" || name == "FavoritesNavButton" && active == "Favorites"); button.Margin = new Thickness(8, 2, 8, 2); button.HorizontalAlignment = HorizontalAlignment.Stretch; }
            if (Find<StackPanel>("LibraryNavPanel") is { } nav)
                foreach (var button in nav.Children.OfType<Button>())
                { Button(button, active == "Library" && Equals(button.Tag, library)); button.Margin = new Thickness(8, 2, 8, 2); button.HorizontalAlignment = HorizontalAlignment.Stretch; }
            DesktopShellLayout.Apply(page, Options, palette);
            ReferenceAppearance.Apply(page);
        }
        public void Detail()
        {
            if(Find<Grid>("DetailView") is {} detailView)
            {
                // The compiled template's literal gradients do not follow the
                // resource color keys. Set the realized layers themselves.
                var layers=UiElements.Descendants(detailView).OfType<Microsoft.UI.Xaml.Shapes.Rectangle>().Where(r=>r.Fill is LinearGradientBrush).ToArray();
                foreach(var layer in layers)
                {
                    var old=(LinearGradientBrush)layer.Fill;
                    var brush=new LinearGradientBrush{StartPoint=old.StartPoint,EndPoint=old.EndPoint};
                    bool bottom=layer.Name=="DetailBackdropFadeLayer";
                    bool horizontal=Math.Abs(old.EndPoint.X-old.StartPoint.X)>Math.Abs(old.EndPoint.Y-old.StartPoint.Y);
                    (double Offset,byte Alpha)[] stops=bottom?new[]{(0d,(byte)0),(.72d,(byte)0),(1d,(byte)255)}
                        :horizontal?new[]{(0d,(byte)255),(.38d,(byte)225),(.70d,(byte)35),(1d,(byte)0)}
                        :new[]{(0d,(byte)0),(.65d,(byte)0),(1d,(byte)210)};
                    foreach(var stop in stops)brush.GradientStops.Add(new GradientStop{Offset=stop.Offset,Color=Color((palette.Background&0x00FFFFFF)|((uint)stop.Alpha<<24))});
                    layer.Fill=brush;layer.IsHitTestVisible=false;
                }
            }
            if (Find<Grid>("DetailPageLayout") is { } layout)
                layout.Padding = new Thickness(page.ActualWidth is > 0 and < 900 ? 28 : 46, 24, 40, 40);
            if (Find<TextBlock>("DetailTitleText") is { } title)
            { title.FontSize = page.ActualWidth is > 0 and < 900 ? 32 : 44; title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; title.Foreground = Brush(palette.Text); }
            if (Find<TextBlock>("DetailOverviewText") is { } overview)
            { overview.FontSize = 15; overview.LineHeight = 26; overview.MaxWidth = 780; overview.Foreground = Brush(palette.Text); }
            foreach (string name in new[] { "DetailPlayButton", "DetailWatchButton", "DetailFavoriteButton", "DetailMoreButton", "DetailPlayedButton", "DetailUnplayedButton", "DetailSourceButton", "DetailBackButton" })
                if (Find<Button>(name) is { } button)
                {
                    bool primary = name is "DetailPlayButton" or "DetailWatchButton";
                    Button(button, primary);
                    bool dark = Options.Mode == 2 || Options.Mode == 0 && page.ActualTheme == ElementTheme.Dark;
                    DesktopVisuals.Action(button,palette,primary,name is "DetailFavoriteButton" or "DetailMoreButton",dark || systemSnapshot.HighContrast);
                    if(name=="DetailBackButton")DesktopCloseButton.Apply(button,palette);

                }
            if (Find<StackPanel>("DetailDesktopActions") is {} actions)
            { actions.Width=double.NaN;actions.MinWidth=0;actions.MaxWidth=double.PositiveInfinity;actions.Spacing=10; }
            if (Find<StackPanel>("DetailAllActions") is {} all)
            { all.Width=double.NaN;all.MinWidth=0;all.MaxWidth=double.PositiveInfinity;all.Spacing=12;all.Orientation=page.ActualWidth<1100?Orientation.Vertical:Orientation.Horizontal; }
            if (Find<Border>("DetailPosterFallback") is { } poster) poster.CornerRadius = new(Options.Radius);
            ReferenceAppearance.Apply(page);
            DetailArtwork.EnsureSurface(page);
        }
        public void TrackCard(FrameworkElement element)
        {
            if (!registered.TryGetValue(element, out var entry))
            {
                entry = new(element); registered.Add(element, entry); cards.Add(entry);
                element.Unloaded += (_, _) => system.Run("card-unloaded", () => { cards.Remove(entry); UnbindCard(entry); });
                element.Loaded += (_, _) => system.Run("card-loaded", () => { if (!cards.Contains(entry)) cards.Add(entry); BindCard(element, entry); StyleCard(element); });
                element.SizeChanged += (_, _) => system.Run("card-size", () => SizeCard(element));
            }
            BindCard(element, entry);
            StyleCard(element);
        }
        static void UnbindCard(CardState entry)
        {
            if (entry.Source != null && entry.Changed != null) entry.Source.PropertyChanged -= entry.Changed;
            entry.Source = null; entry.Changed = null;
        }
        void BindCard(FrameworkElement element, CardState entry)
        {
            if (ReferenceEquals(entry.Source, element.DataContext)) return;
            UnbindCard(entry);
            if (element.DataContext is not INotifyPropertyChanged source) return;
            entry.Source = source;
            entry.Changed = (_, args) => system.Run("card-notification", () =>
            {
                if (args.PropertyName is not ("Title" or "Progress" or "HasProgress" or "Poster" or "IsFavorite" or "Item") && !string.IsNullOrEmpty(args.PropertyName)) return;
                if(args.PropertyName!="Poster")entry.FullPaint=true;
                if(entry.PaintQueued)return;entry.PaintQueued=true;
                if(!element.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,() => system.Run("card-refresh", () => {
                    entry.PaintQueued=false;bool full=entry.FullPaint;entry.FullPaint=false;
                    if(element.IsLoaded&&(full||element is not Grid grid||!DesktopCardSurface.PaintPoster(grid,element.DataContext)))StyleCard(element);
                })))entry.PaintQueued=false;
            });
            source.PropertyChanged += entry.Changed;
        }
        void StyleCard(FrameworkElement element)
        {
            // Only this realized template is visited, on load/recycle or a user
            // theme change. No LayoutUpdated handler or offscreen item traversal.
            if(element is Grid cardGrid)DesktopCardSurface.Apply(cardGrid,Options,palette,page);
            SizeCard(element);
            if(element is Grid referenceCard)ReferenceAppearance.Artwork(page,referenceCard);
            // PosterMotion owns the image visual's reduced-motion behavior.
            // Writing XAML transitions here conflicts with composition-backed
            // templates, even when assigning null, and must not block refresh.
        }
        void SizeCard(FrameworkElement element)
        {
            if (element.DataContext is not { } card || element is not Grid grid || grid.RowDefinitions.Count == 0) return;
            bool landscape = card.GetType().GetProperty("PreferLandscapeArtwork")?.GetValue(card) is true;
            bool browse = card.GetType().GetProperty("UsesBrowseViewport")?.GetValue(card) is true;
            for(DependencyObject? node=VisualTreeHelper.GetParent(element);node!=null;node=VisualTreeHelper.GetParent(node))
            {
                if(node is GridViewItem cell){cell.Padding=new Thickness(0);cell.Margin=new Thickness(0);cell.Background=Brush(0x00000000);cell.BorderBrush=Brush(0x00000000);cell.BorderThickness=new Thickness(0);cell.MinWidth=0;cell.MinHeight=0;cell.Height=double.NaN;cell.MaxHeight=double.PositiveInfinity;cell.Clip=null;if(browse)cell.Width=double.NaN;break;}
                if(node is ItemsControl)break;
            }
            if (!browse)
            {
                double width = landscape && registered.TryGetValue(element,out var native)&&native.NativeLandscapeWidth>0
                    ? native.NativeLandscapeWidth : landscape ? Options.PosterWidth * 1.65 : Options.PosterWidth;
                grid.Width = width; grid.MaxWidth = width;
                double itemWidth=landscape?width:width+14; // Landscape already reserves its hover inset internally.
                // Home rows use their own panel; update only the containing row,
                // never the virtualized library wall's anchor-preserving grid.
                for (DependencyObject? ancestor = VisualTreeHelper.GetParent(element); ancestor != null; ancestor = VisualTreeHelper.GetParent(ancestor))
                {
                    if(ancestor is GridViewItem container){container.Padding=new Thickness(0);container.Margin=new Thickness(0);container.BorderThickness=new Thickness(0);container.MinWidth=landscape?itemWidth:0;container.MaxWidth=landscape?itemWidth:double.PositiveInfinity;container.Width=itemWidth;container.HorizontalContentAlignment=HorizontalAlignment.Left;}
                    if (ancestor is ItemsWrapGrid wrap) { wrap.ItemWidth = itemWidth; wrap.ItemHeight=width*(landscape?9.0/16:1.5)+64; break; }
                    if (ancestor is ItemsControl) break;
                }
            }
            double artworkWidth = double.IsFinite(grid.Width) ? grid.Width : grid.ActualWidth;
            grid.Margin=new Thickness(0);grid.Padding=new Thickness(0);
            if (artworkWidth > 0) grid.RowDefinitions[0].Height = new GridLength(artworkWidth * (landscape ? 9.0 / 16 : 1.5));
        }
        void BuildSettings()
        {
            if (settingsAttached || Find<Border>("AppearanceSettingsSection") is not { } section) return;
            var oldContent = section.Child;
            var panel = new StackPanel { Spacing = 16 };
            panel.Children.Add(new TextBlock { Text = "桌面个性化", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            panel.Children.Add(new TextBlock { Text = "选择喜欢的配色，调整海报与窗口。", TextWrapping = TextWrapping.Wrap, FontSize = 13 });
            Choice(panel, "明暗模式", new[] { "跟随系统", "浅色", "深色" }, Options.Mode, index => Options with { Mode = index });
            Choice(panel, "主题配色", new[] { "霞光紫", "海湾蓝", "宝石绿", "流金粉" }, Array.IndexOf(new[]{5,9,7,6},Options.Accent), index => Options with { Accent = new[]{5,9,7,6}[index] });
            Choice(panel, "卡片圆角", new[] { "柔和", "利落", "直角" }, Options.Corners, index => Options with { Corners = index });
            var motion = new ToggleSwitch { Header = "减少动态效果", IsOn = Options.ReducedMotion };
            bool revertingMotion = false;
            motion.Toggled += (_, _) => system.Run("motion-toggle", () =>
            {
                if (revertingMotion) return;
                if (!Save(Options with { ReducedMotion = motion.IsOn }))
                { revertingMotion = true; motion.IsOn = Options.ReducedMotion; revertingMotion = false; }
            });
            panel.Children.Add(motion);
            if(Find<Border>("ExperienceSettingsSection")?.Child is Panel experience && !experience.Children.OfType<FrameworkElement>().Any(c=>c.Name=="DesktopPlaybackPreferences"))
            {
                var controls=new StackPanel{Name="DesktopPlaybackPreferences",Spacing=16};
                var hdr=new ToggleSwitch{Header="HDR（测试）",IsOn=Options.HdrExperimental,OnContent="开启",OffContent="关闭"};
                bool revertingHdr=false;
                hdr.Toggled+=(_,_)=>
                {
                    if(revertingHdr)return;
                    if(!Save(Options with{HdrExperimental=hdr.IsOn}))
                    {revertingHdr=true;hdr.IsOn=Options.HdrExperimental;revertingHdr=false;}
                };
                controls.Children.Add(hdr);
                controls.Children.Add(new TextBlock{Text="默认关闭：杜比、HDR、HLG 转换为 SDR。开启后请求 HDR 输出，杜比转换为 HDR10。需要系统与显示器支持 HDR；下次播放生效。",TextWrapping=TextWrapping.Wrap,FontSize=13});
                var click=new ToggleSwitch{Header="画面单击暂停／继续",IsOn=Options.VideoClickPause};
                click.Toggled+=(_,_)=>Save(Options with{VideoClickPause=click.IsOn});controls.Children.Add(click);
                Choice(controls,"方向键定位步长",new[]{"5 秒","10 秒","30 秒"},Array.IndexOf(new[]{5,10,30},Options.SeekStepSeconds),i=>Options with{SeekStepSeconds=new[]{5,10,30}[i]});
                Choice(controls,"暂停／继续快捷键",new[]{"Space / K","K","P"},Array.IndexOf(new[]{32,75,80},Options.PauseKey),i=>Options with{PauseKey=new[]{32,75,80}[i]});
                Choice(controls,"全屏快捷键",new[]{"F","F11","G"},Array.IndexOf(new[]{70,122,71},Options.FullScreenKey),i=>Options with{FullScreenKey=new[]{70,122,71}[i]});
                Choice(controls,"静音快捷键",new[]{"M","V"},Options.MuteKey==77?0:1,i=>Options with{MuteKey=i==0?77:86});
                var hold=new ToggleSwitch{Header="按住 → 临时 3 倍速",IsOn=Options.RightHoldBoost};hold.Toggled+=(_,_)=>Save(Options with{RightHoldBoost=hold.IsOn});controls.Children.Add(hold);
                var volume=new ToggleSwitch{Header="↑ / ↓ 调整音量",IsOn=Options.KeyboardVolumeKeys};volume.Toggled+=(_,_)=>Save(Options with{KeyboardVolumeKeys=volume.IsOn});controls.Children.Add(volume);
                experience.Children.Add(controls);
            }
            var reset = new Button { Content = "恢复默认外观" };
            reset.Click += (_, _) => system.Run("reset-click", () =>
            {
                if (!Save(new DesktopThemeOptions{HdrExperimental=Options.HdrExperimental,VideoClickPause=Options.VideoClickPause,SeekStepSeconds=Options.SeekStepSeconds,KeyboardVolumeKeys=Options.KeyboardVolumeKeys,RightHoldBoost=Options.RightHoldBoost,PauseKey=Options.PauseKey,FullScreenKey=Options.FullScreenKey,MuteKey=Options.MuteKey})) return;
                // Recreate only the appearance controls, preserving the original
                // window-size preference UI and unrelated playback preferences.
                if (oldContent is FrameworkElement original && original.Parent is Panel parent) parent.Children.Remove(oldContent);
                panel.Children.Remove(status);
                section.Child = oldContent; settingsAttached = false; BuildSettings();
            });
            panel.Children.Add(reset); panel.Children.Add(status);
            try
            {
                section.Child = null;
                var layout = new Grid { Name="DesktopAppearanceLayout",ColumnSpacing = 0, RowSpacing = 28 };
                layout.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
                layout.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
                layout.RowDefinitions.Add(new() { Height = GridLength.Auto }); layout.RowDefinitions.Add(new() { Height = GridLength.Auto });
                panel.Name="DesktopAppearanceOptions";panel.Spacing=14;layout.Children.Add(panel);
                var window = new StackPanel { Name="DesktopWindowOptions",Spacing = 14,VerticalAlignment=VerticalAlignment.Top };
                window.Children.Add(new TextBlock { Text = "窗口与浏览", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                if (oldContent != null) window.Children.Add(oldContent);
                Grid.SetColumn(window, 0);Grid.SetRow(window,1);layout.ColumnDefinitions[1].Width=new(0);layout.Children.Add(window);
                layout.SizeChanged += (_, args) => system.Run("settings-desktop-width", () =>
                { Grid.SetColumn(window,0);Grid.SetRow(window,1);layout.ColumnDefinitions[1].Width=new(0); });
                section.Child = layout;
                settingsAttached = true;
                if (Find<ComboBox>("ThemeCombo") is { } oldTheme) oldTheme.Visibility = Visibility.Collapsed;
            }
            catch
            {
                settingsAttached = false;
                if (oldContent is FrameworkElement original && original.Parent is Panel parent) parent.Children.Remove(oldContent);
                panel.Children.Remove(status);
                section.Child = oldContent;
                throw;
            }
        }
        void Choice(StackPanel panel, string title, string[] labels, int selected, Func<int, DesktopThemeOptions> update)
        {
            var combo = new ComboBox { MinWidth = 180, MaxWidth = double.PositiveInfinity, HorizontalAlignment = HorizontalAlignment.Stretch };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(combo, title);
            foreach (string label in labels) combo.Items.Add(label);
            combo.SelectedIndex = selected;
            bool reverting = false;
            combo.SelectionChanged += (_, _) => system.Run("choice-selection", () =>
            {
                if (reverting || combo.SelectedIndex < 0) return;
                if (Save(update(combo.SelectedIndex))) selected = combo.SelectedIndex;
                else { reverting = true; combo.SelectedIndex = selected; reverting = false; }
            });
            var row = new Grid { ColumnSpacing = 20, RowSpacing = 8 };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(168) }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            row.RowDefinitions.Add(new() { Height = GridLength.Auto }); row.RowDefinitions.Add(new() { Height = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, FontSize = 14 });
            Grid.SetColumn(combo, 1); row.Children.Add(combo);
            row.SizeChanged += (_, args) => system.Run("setting-row-size", () =>
            {
                bool narrow = args.NewSize.Width < 380;
                row.ColumnDefinitions[0].Width = narrow ? new GridLength(1, GridUnitType.Star) : new GridLength(168);
                Grid.SetColumn(combo, narrow ? 0 : 1); Grid.SetRow(combo, narrow ? 1 : 0);
            });
            panel.Children.Add(row);
        }
        bool Save(DesktopThemeOptions next)
        {
            try { DesktopThemeStore.Save(StorePath, next); options = next.Validate(); }
            catch (Exception error) { status.Text = "外观保存失败，已保留原设置：" + error.GetType().Name; return false; }
            LivePages.RemoveAll(weak => !weak.TryGetTarget(out _));
            foreach (var weak in LivePages.ToArray()) if (weak.TryGetTarget(out var state)) state.Apply();
            PlayerDesktopStyle.RefreshAll();
            status.Text = "已保存并应用"; return true;
        }
    }
}
