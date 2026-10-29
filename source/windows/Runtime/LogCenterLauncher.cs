using System.Collections.ObjectModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Storage.Pickers;
using WinRT.Interop;
using Yingyu.LogCenter;

namespace Yingyu.Update;

// Keep one log entry in settings; the former diagnostic tools live here.
public static class LogCenterLauncher
{
    static readonly ConditionalWeakTable<object, State> States = new();
    static readonly ConditionalWeakTable<object, FeedOwner> Feeds = new();
    public static bool IsActive(object page) => States.TryGetValue(page, out var state) && state.Active;
    public static void StartBackground(object page)
    {
        try { _ = Feeds.GetValue(page, p => new FeedOwner((FrameworkElement)p)); }
        catch (Exception error) { Warn("后台日志连接未完成", error); }
    }
    sealed class FeedOwner
    {
        internal readonly BackgroundLogFeed Feed;
        internal FeedOwner(FrameworkElement page)
        {
            var tail = new LocalLogTail();
            Feed = new BackgroundLogFeed(tail.ReadAsync);
            page.Loaded += (_, _) => Feed.Start();
            page.Unloaded += (_, _) => Feed.Stop();
            if (page.IsLoaded) Feed.Start();
        }
    }
    public static void Configure(object page)
    {
        try { var state = States.GetValue(page, p => new State(p)); state.Attach(); state.ApplyTheme(); SettingsWheelGuard.Enable(page); }
        catch (Exception error) { Warn("日志中心入口创建未完成", error); }
    }
    public static void ApplyTheme(object page)
    {
        try { if (States.TryGetValue(page, out var state)) state.ApplyTheme(); }
        catch (Exception error) { Warn("日志页面外观未完全应用", error); }
    }
    public static void Leave(object page)
    {
        try { if (States.TryGetValue(page, out var state)) state.Hide(); }
        catch (Exception error) { Warn("日志中心页面退出未完成", error); }
    }
    public static void Close(object page) { Leave(page); SettingsWheelGuard.Disable(page); }
    public static void DetailPlay(object page) => PlaybackTelemetry.Emit("scope=input; event=operation; action=detail-play; result=requested");
    static void Warn(string text, Exception error) => PlaybackTransport.Write("Warning", "Diagnostics", text + "；异常类型=" + error.GetType().Name);

    sealed class State
    {
        internal bool Active => _active;
        const int MaxRows = LocalLogTail.MaximumRows;
        readonly object _page;
        readonly Grid _settings;
        ObservableCollection<LogRow> _rows = new();
        readonly BackgroundLogFeed _feed;
        long _sequence;
        readonly DispatcherQueueTimer _timer;
        readonly Grid _root = new() { Visibility = Visibility.Collapsed, RowSpacing = 16, Padding = new Thickness(24), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 16, 17, 21)) };
        readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
        readonly Dictionary<string, SolidColorBrush> _themeBrushes = new(StringComparer.Ordinal);
        readonly TextBlock _status = Text("正在读取本机日志…", 12, true);
        readonly TextBlock _details = Text("点击一条记录，查看完整结果。", 13, true);
        readonly Button _pause = ActionButton("暂停自动滚动");
        readonly Button _export = ActionButton("导出原始日志");
        Button? _navigation;
        FrameworkElement? _originalPane;
        Visibility _originalVisibility;
        ScrollViewer? _listScroll;
        CancellationTokenSource? _lifetime;
        bool _attached, _active, _reading, _follow = true, _exporting, _adjustingView, _diagnosticsHidden;
        int _generation, _uiWarnings, _viewRevision;
        LogSnapshot? _pending;
        int _pendingIndex;
        ViewAnchor? _hiddenAnchor;
        string _lastStatus = "正在读取本机日志…";

        internal State(object page)
        {
            _page = page;
            _feed = Feeds.GetValue(page, p => new FeedOwner((FrameworkElement)p)).Feed;
            _settings = Access.Get<Grid>(page, "SettingsView");
            _timer = _settings.DispatcherQueue.CreateTimer();
            _timer.Interval = TimeSpan.FromSeconds(2);
            BuildPage();
            _timer.Tick += async (_, _) => await RefreshAsync();
            _settings.Loaded += (_, _) => Attach();
            ((FrameworkElement)page).Unloaded += (_, _) => SafeUi(Hide, "日志页面卸载清理未完成");
            _root.Loaded += async (_, _) => { if (_active) await RefreshAsync(); };
            _root.Unloaded += (_, _) => SafeUi(Hide, "日志视图卸载清理未完成");
        }
        internal void Attach()
        {
            if (_attached) { HideDuplicateDiagnostics(); return; }
            if (!_settings.IsLoaded)
            {
                _settings.DispatcherQueue.TryEnqueue(() => { if (_settings.IsLoaded) Attach(); });
                return;
            }
            try
            {
                var about = UiElements.Descendants((FrameworkElement)_page).OfType<Button>()
                    .SingleOrDefault(b => b.Tag is string tag && tag == "AboutSettingsSection");
                if (about == null || VisualTreeHelper.GetParent(about) is not StackPanel navigation)
                    throw new InvalidOperationException("设置侧栏结构未匹配");
                var scroll = Access.Get<ScrollViewer>(_page, "SettingsContentScrollViewer");
                var ancestors = new HashSet<DependencyObject>();
                for (DependencyObject? item = about; item != null; item = VisualTreeHelper.GetParent(item)) ancestors.Add(item);
                FrameworkElement? pane = scroll;
                DependencyObject? parent = VisualTreeHelper.GetParent(pane);
                while (parent != null && !ancestors.Contains(parent))
                {
                    pane = parent as FrameworkElement ?? throw new InvalidOperationException("设置内容容器未匹配");
                    parent = VisualTreeHelper.GetParent(pane);
                }
                if (parent is not Grid host || pane == null || ReferenceEquals(pane, about))
                    throw new InvalidOperationException("设置右侧容器未匹配");
                _originalPane = pane;
                _root.Margin = pane.Margin;
                Grid.SetColumn(_root, Grid.GetColumn(pane)); Grid.SetColumnSpan(_root, Grid.GetColumnSpan(pane));
                Grid.SetRow(_root, Grid.GetRow(pane)); Grid.SetRowSpan(_root, Grid.GetRowSpan(pane));
                _navigation = new Button
                {
                    Content = "日志中心", Tag = "YingyuLogCenter", Style = about.Style,
                    HorizontalAlignment = about.HorizontalAlignment, VerticalAlignment = about.VerticalAlignment,
                    Margin = about.Margin, Padding = about.Padding, MinHeight = about.MinHeight,
                    FontSize = about.FontSize, CornerRadius = about.CornerRadius
                };
                AutomationProperties.SetName(_navigation, "日志中心");
                _navigation.Click += (_, _) => Show();
                host.Children.Add(_root);
                navigation.Children.Insert(navigation.Children.IndexOf(about), _navigation);
                _attached = true;
                HideDuplicateDiagnostics();
                ApplyTheme(); // Loaded may attach after Configure has already applied its theme.
            }
            catch (Exception error) { Warn("日志中心侧栏连接未完成，保留原设置界面", error); }
        }
        void HideDuplicateDiagnostics()
        {
            try
            {
                var card = Access.Get<FrameworkElement>(_page, "DiagnosticsSettingsSection");
                if (!_diagnosticsHidden)
                {
                    // The original search/category routine sets every card's
                    // visibility. Keep this exact duplicate collapsed there too.
                    card.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) =>
                        SafeUi(() => { if (card.Visibility != Visibility.Collapsed) card.Visibility = Visibility.Collapsed; }, "重复日志入口隐藏未完成"));
                    _diagnosticsHidden = true;
                }
                card.Visibility = Visibility.Collapsed;
                foreach (var button in UiElements.Descendants((FrameworkElement)_page).OfType<Button>()
                    .Where(b => b.Tag is string tag && tag == "DiagnosticsSettingsSection").ToArray())
                {
                    if (VisualTreeHelper.GetParent(button) is Panel navigation) navigation.Children.Remove(button);
                    else button.Visibility = Visibility.Collapsed;
                }
            }
            catch (Exception error) { Warn("重复日志入口隐藏未完成", error); }
        }
        void BuildPage()
        {
            _root.RowDefinitions.Add(new() { Height = GridLength.Auto });
            _root.RowDefinitions.Add(new() { Height = GridLength.Auto });
            _root.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
            _root.RowDefinitions.Add(new() { Height = GridLength.Auto });
            var heading = new Grid { ColumnSpacing = 24 };
            heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var title = new StackPanel { Spacing = 8 };
            title.Children.Add(Text("日志中心", 27));
            title.Children.Add(Text("按时间查看操作、播放状态和结果", 14, true));
            Grid.SetColumn(title,0);heading.Children.Add(title);
            var close = new Button { Name="DesktopLogClose",Content = new FontIcon { Glyph = "\uE8BB", FontSize = 20 }, Width = 40, Height = 40,Padding=new(0),Margin=new(0,0,12,0), CornerRadius = new CornerRadius(20), VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(close, "关闭设置"); ToolTipService.SetToolTip(close, "关闭设置");
            close.Click += (_, _) =>
            {
                try { Access.Call(_page, "CloseSettingsButton_Click", close, new RoutedEventArgs()); }
                catch (Exception error) { Warn("设置关闭请求未完成", error); }
            };
            Grid.SetColumn(close,1);heading.Children.Add(close);_root.Children.Add(heading);

            var tools = new Grid { ColumnSpacing = 24 };
            tools.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            tools.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var description = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
            description.Children.Add(Text("中文显示供查看；原始日志用于维护", 15));
            description.Children.Add(Text("后台持续更新 · 最多显示 10,000 条，超出后移出最旧记录", 12, true));
            tools.Children.Add(description);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
            _pause.Click += (_, _) =>
            {
                try
                {
                    SetFollowing(!_follow);
                    if (_follow) Follow();
                    if (_active) UpdateStatus();
                }
                catch (Exception error) { Warn("日志自动滚动操作未完成", error); }
            };
            _export.Click += async (_, _) => await ExportAsync();
            if (Application.Current.Resources.TryGetValue("AccentButtonStyle", out var accent) && accent is Style style) _export.Style = style;
            actions.Children.Add(_pause); actions.Children.Add(_export);
            Grid.SetColumn(actions, 1); tools.Children.Add(actions);
            var toolContent = new StackPanel { Spacing = 14 }; toolContent.Children.Add(tools);
            var originalTools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            foreach (var (label, method) in new[]
            {
                ("打开日志目录", "OpenLogFolderButton_Click"), ("复制日志路径", "CopyLogPathButton_Click"),
                ("复制用于反馈", "CopyRecentLogButton_Click")
            })
            {
                var button = ActionButton(label);
                button.Click += (_, _) => SafeUi(() =>
                {
                    Access.Call(_page, method, button, new RoutedEventArgs());
                    _lastStatus = Access.Get<TextBlock>(_page, "SettingsStatusText").Text; UpdateStatus();
                }, "原日志工具操作未完成");
                originalTools.Children.Add(button);
            }
            toolContent.Children.Add(originalTools);
            toolContent.Children.Add(Text("原始日志最多保留 16 份，每份 16 MiB；自动滚动暂停时，记录与列表仍持续更新。", 12, true));
            var toolbar = Card(toolContent, new Thickness(22, 18, 22, 18)); Grid.SetRow(toolbar, 1); _root.Children.Add(toolbar);

            var table = new Grid { RowSpacing = 10 };
            table.RowDefinitions.Add(new() { Height = GridLength.Auto });
            table.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
            table.RowDefinitions.Add(new() { Height = GridLength.Auto });
            var columns = Columns(); columns.Margin = new Thickness(18, 6, 18, 2);
            foreach (var (label, column) in new[] { ("时间", 0), ("操作位置", 1), ("级别", 2), ("结果", 3) })
            {
                var text = Text(label, 12, true); Grid.SetColumn(text, column); columns.Children.Add(text);
            }
            table.Children.Add(columns); _list.ItemsSource = _rows;
            // Keep the original virtualizing panel. A log append/trim is not
            // an animated insertion/deletion of the whole visible viewport.
            _list.ItemContainerTransitions = new TransitionCollection();
            _list.ItemsPanel = (ItemsPanelTemplate)XamlReader.Load("""
                <ItemsPanelTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                  <ItemsStackPanel ItemsUpdatingScrollMode="KeepItemsInView"/>
                </ItemsPanelTemplate>
                """);
            _list.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0));
            _list.ItemContainerStyle = (Style)XamlReader.Load("""
                <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="ListViewItem">
                  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                  <Setter Property="Padding" Value="0"/><Setter Property="Margin" Value="0,2,0,2"/>
                  <Setter Property="MinHeight" Value="58"/><Setter Property="CornerRadius" Value="10"/>
                </Style>
                """);
            _list.ItemTemplate = (DataTemplate)XamlReader.Load("""
                <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                  <Border Padding="18,14" BorderThickness="0,0,0,1" BorderBrush="{ThemeResource LogOutlineBrush}">
                    <Grid ColumnSpacing="18">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="112"/><ColumnDefinition Width="172"/><ColumnDefinition Width="68"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="{Binding Time}" FontSize="12" FontFamily="Cascadia Mono, Consolas" Foreground="{ThemeResource LogSecondaryBrush}" VerticalAlignment="Center"/>
                      <Border Grid.Column="1" Background="{ThemeResource LogSelectionBrush}" CornerRadius="7" Padding="10,5" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Place}" FontSize="13" Foreground="{ThemeResource LogTextBrush}" TextTrimming="CharacterEllipsis"/>
                      </Border>
                      <Border Grid.Column="2" Background="{ThemeResource LogHoverBrush}" CornerRadius="7" Padding="8,5" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Level}" FontSize="12" Foreground="{ThemeResource LogTextBrush}" HorizontalAlignment="Center"/>
                      </Border>
                      <TextBlock Grid.Column="3" Text="{Binding Result}" FontSize="14" Foreground="{ThemeResource LogTextBrush}" TextWrapping="Wrap" MaxLines="3" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" LineHeight="23"/>
                    </Grid>
                  </Border>
                </DataTemplate>
                """);
            _list.SelectionChanged += (_, _) =>
            {
                SafeUi(() =>
                {
                    if (_list.SelectedItem is LogRow row) _details.Text = $"{row.FullTime}   {row.Place}   ·   {row.Level}\n{row.Result}";
                }, "日志完整结果显示未完成");
            };
            _list.Loaded += (_, _) =>
            {
                try
                {
                    UpdateScrollMode();
                    var scroll = UiElements.Descendants(_list).OfType<ScrollViewer>().FirstOrDefault();
                    if (scroll == null || ReferenceEquals(scroll, _listScroll)) return;
                    _listScroll = scroll;
                    scroll.ViewChanging += (_, e) =>
                    {
                        SafeUi(() =>
                        {
                            if (!_adjustingView && e.NextView.VerticalOffset != scroll.VerticalOffset)
                            {
                                _viewRevision++;
                                if (e.NextView.VerticalOffset > scroll.VerticalOffset) SetFollowing(false);
                                UpdateStatus();
                            }
                        }, "日志滚动状态更新未完成");
                    };
                }
                catch (Exception error) { Warn("日志滚动视图连接未完成", error); }
            };
            Grid.SetRow(_list, 1); table.Children.Add(_list);
            var footer = new Grid { ColumnSpacing = 16, Margin = new Thickness(8, 10, 8, 0) };
            footer.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            _status.VerticalAlignment = VerticalAlignment.Center; footer.Children.Add(_status);
            var bottom = ActionButton("回到顶部");
            bottom.Click += (_, _) => SafeUi(() => { SetFollowing(true); Follow(true); UpdateStatus(); }, "日志顶部定位未完成");
            Grid.SetColumn(bottom, 1); footer.Children.Add(bottom); Grid.SetRow(footer, 2); table.Children.Add(footer);
            var body = Card(table, new Thickness(18, 16, 18, 18)); Grid.SetRow(body, 2); _root.Children.Add(body);
            _details.IsTextSelectionEnabled = true;
            var detail = new ScrollViewer { Content = _details, MaxHeight = 128, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            var detailCard = Card(detail, new Thickness(22, 16, 22, 16)); Grid.SetRow(detailCard, 3); _root.Children.Add(detailCard);
        }
        internal void ApplyTheme()
        {
            if (_page is not FrameworkElement page) return;
            var options = DesktopTheme.Options;
            bool dark = options.Mode == 2 || options.Mode == 0 && page.ActualTheme == ElementTheme.Dark;
            var palette = DesktopThemePalette.Resolve(options, dark);
            uint Published(string key, uint fallback)
            {
                if (!page.Resources.TryGetValue(key, out var value) || value is not SolidColorBrush brush) return fallback;
                var c = brush.Color; return (uint)c.A << 24 | (uint)c.R << 16 | (uint)c.G << 8 | c.B;
            }
            palette = palette with { Background = Published("AppBackgroundBrush", palette.Background), Surface = Published("CardBrush", palette.Surface),
                Text = Published("PrimaryTextBrush", palette.Text), Secondary = Published("SecondaryTextBrush", palette.Secondary),
                Outline = Published("SubtleBorderBrush", palette.Outline), Accent = Published("AccentBrush", palette.Accent),
                Selection = Published("SidebarSelectionBrush", palette.Selection), Hover = Published("ToolbarButtonHoverBrush", palette.Hover) };
            _root.RequestedTheme = options.Mode switch { 1 => ElementTheme.Light, 2 => ElementTheme.Dark, _ => ElementTheme.Default };
            _root.Background = DesktopVisuals.Brush(palette.Background);
            foreach (var (key, color) in new[] { ("LogTextBrush", palette.Text), ("LogSecondaryBrush", palette.Secondary),
                ("LogOutlineBrush", palette.Outline), ("LogSelectionBrush", palette.Selection), ("LogHoverBrush", palette.Hover) })
            {
                // XamlReader creates the row template outside the page's
                // namescope. Publish our own namespaced brushes there too;
                // all three dictionaries share only these owned objects.
                if (_themeBrushes.TryGetValue(key, out var brush)) brush.Color = DesktopVisuals.Brush(color).Color;
                else _themeBrushes[key] = brush = DesktopVisuals.Brush(color);
                _root.Resources[key] = brush; _list.Resources[key] = brush; Application.Current.Resources[key] = brush;
            }
            _list.Foreground = DesktopVisuals.Brush(palette.Text);
            foreach (var element in Logical(_root).Concat(UiElements.Descendants(_root)).Distinct())
            {
                if (element is Border { Tag: "YingyuLogCard" } card)
                { card.Background = DesktopVisuals.Brush(palette.Surface); card.BorderBrush = DesktopVisuals.Brush(palette.Outline); card.CornerRadius = new(options.Radius); }
                if (element is TextBlock { Tag: string role } text && role is "YingyuLogText" or "YingyuLogSecondary")
                { text.Foreground = DesktopVisuals.Brush(role == "YingyuLogSecondary" ? palette.Secondary : palette.Text); text.Opacity = 1; }
                if (element is Button button){PaintButton(button, palette, options, ReferenceEquals(button, _export));if(button.Name=="DesktopLogClose")DesktopCloseButton.Apply(button,palette);}
            }
            if (_navigation != null)
            {
                PaintButton(_navigation, palette, options, false);
                _navigation.Height = 38; _navigation.MinHeight = 38; _navigation.FontSize = 14;
                _navigation.Resources["ButtonBackgroundPointerOver"] = DesktopVisuals.Brush(palette.Hover);
                _navigation.Background = DesktopVisuals.Brush(_active ? palette.Selection : 0x00000000);
                _navigation.BorderThickness = new Thickness(3,0,0,0);
                _navigation.BorderBrush = DesktopVisuals.Brush(_active ? palette.Accent : 0x00000000);
                AutomationProperties.SetItemStatus(_navigation, _active ? "当前位置" : "");
                if (_active)
                    foreach (var button in UiElements.Descendants(_settings).OfType<Button>().Where(b => b.Tag is string tag && tag.EndsWith("SettingsSection", StringComparison.Ordinal)))
                    {
                        button.Background = DesktopVisuals.Brush(0x00000000);
                        button.BorderBrush = DesktopVisuals.Brush(0x00000000);
                        AutomationProperties.SetItemStatus(button, "");
                    }
            }
        }
        static void PaintButton(Button button, DesktopThemePalette palette, DesktopThemeOptions options, bool primary)
        {
            uint foreground = primary ? (Brightness(palette.Accent) > 160 ? 0xFF16181Du : 0xFFFFFFFFu) : palette.Text;
            button.Foreground = DesktopVisuals.Brush(foreground); button.Background = DesktopVisuals.Brush(primary ? palette.Accent : palette.Hover);
            button.BorderBrush = DesktopVisuals.Brush(palette.Outline); button.BorderThickness = new Thickness(1);
            button.CornerRadius = new(Math.Min(options.Radius, 10)); button.MinHeight = 36; button.Padding = new Thickness(12, 7, 12, 7);
            foreach (string key in new[] { "ButtonForeground", "ButtonForegroundPointerOver", "ButtonForegroundPressed" }) button.Resources[key] = DesktopVisuals.Brush(foreground);
            button.Resources["ButtonBackgroundPointerOver"] = DesktopVisuals.Brush(primary ? palette.Accent : palette.Selection);
            button.Resources["ButtonBackgroundPressed"] = DesktopVisuals.Brush(primary ? palette.Accent : palette.Selection);
        }
        static double Brightness(uint c) => ((c >> 16) & 255) * .2126 + ((c >> 8) & 255) * .7152 + (c & 255) * .0722;
        static IEnumerable<DependencyObject> Logical(DependencyObject root)
        {
            yield return root;
            IEnumerable<DependencyObject> children = root switch
            { Panel panel => panel.Children, Border border when border.Child != null => new[] { border.Child }, ContentControl control when control.Content is DependencyObject content => new[] { content }, _ => Array.Empty<DependencyObject>() };
            foreach (var child in children) foreach (var nested in Logical(child)) yield return nested;
        }
        void Show()
        {
            if (!_attached || _active || _originalPane == null || !_settings.IsLoaded) return;
            try
            {
                _generation++; _lifetime = new CancellationTokenSource(); _active = true;
                // Bind an already populated snapshot while the panel is still
                // hidden. Do not animate/replay all historical rows on open.
                var snapshot = _feed.Snapshot();
                _rows = new ObservableCollection<LogRow>(snapshot.Rows.Reverse());
                _list.ItemsSource = _rows;
                _sequence = snapshot.Sequence; _pending = null; _pendingIndex = 0;
                _lastStatus = snapshot.Status;
                _export.IsEnabled = !_exporting;
                _originalVisibility = _originalPane.Visibility;
                _originalPane.Visibility = Visibility.Collapsed; _root.Visibility = Visibility.Visible;
                DesktopTheme.Navigation(_page); ApplyTheme();
                SettingsWheelGuard.Disable(_page);
                _timer.Start(); _ = RefreshAsync();
                if (_follow) Follow(); else RestoreAnchor(_hiddenAnchor);
                UpdateStatus();
            }
            catch (Exception error) { Hide(); Warn("日志页面显示未完成", error); }
        }
        internal void Hide()
        {
            if (!_active) return;
            _hiddenAnchor = _follow ? null : CaptureAnchor();
            _active = false; _generation++; _timer.Stop();
            _lifetime?.Cancel(); _lifetime?.Dispose(); _lifetime = null;
            _root.Visibility = Visibility.Collapsed;
            if (_originalPane != null) _originalPane.Visibility = _originalVisibility;
            DesktopTheme.Navigation(_page); ApplyTheme(); SettingsWheelGuard.Enable(_page);
        }
        async Task RefreshAsync()
        {
            if (!_active || _reading || _lifetime == null || !_root.IsLoaded) return;
            int generation = _generation; var token = _lifetime.Token; _reading = true;
            try
            {
                if (_pending == null)
                {
                    _pending = _feed.Snapshot(_sequence);
                    _pendingIndex = Math.Max(0, _pending.Rows.Count - MaxRows);
                }
                var batch = _pending;
                // A user may open settings before the initial disk read finishes.
                // Hydrate the still-empty list once, without replaying history.
                if (_sequence == 0 && _rows.Count == 0 && _pendingIndex == 0 && batch.Rows.Count > 0)
                {
                    _rows = new ObservableCollection<LogRow>(batch.Rows.Reverse());
                    _list.ItemsSource = _rows; _pendingIndex = batch.Rows.Count;
                    if (_follow) Follow();
                }
                while (_pendingIndex < batch.Rows.Count)
                {
                    if (!_active || generation != _generation || token.IsCancellationRequested) return;
                    int viewRevision = _viewRevision;
                    var anchor = _follow ? null : CaptureAnchor();
                    _adjustingView = true;
                    try
                    {
                        UpdateScrollMode();
                        LogDisplayUpdatePolicy.Apply(_rows, batch.Rows, ref _pendingIndex, MaxRows);
                        // Settle virtualization before exposing the next frame.
                        // The native panel keeps retained review rows in place.
                        // Only an evicted anchor needs a nearest-row fallback.
                        if (_follow) Follow();
                        else if (viewRevision == _viewRevision && anchor != null && !_rows.Contains(anchor.Row)) RestoreAnchor(anchor);
                    }
                    finally { _adjustingView = false; }
                    _lastStatus = batch.Status; UpdateStatus();
                    if (_pendingIndex < batch.Rows.Count) await YieldUi();
                }
                if (!_active || generation != _generation || token.IsCancellationRequested) return;
                _sequence = batch.Sequence; _pending = null; _pendingIndex = 0;
                _lastStatus = batch.Status; UpdateStatus();
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                if (_active && generation == _generation) { _lastStatus = "本地读取未完成，将自动重试。异常类型：" + error.GetType().Name; UpdateStatus(); }
            }
            finally { _reading = false; }
        }
        Task YieldUi()
        {
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_settings.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => completion.TrySetResult())) completion.TrySetResult();
            return completion.Task;
        }
        void SetFollowing(bool follow) { _follow = follow; _pause.Content = follow ? "暂停自动滚动" : "恢复自动滚动"; UpdateScrollMode(); }
        void UpdateScrollMode()
        {
            if (_list.ItemsPanelRoot is ItemsStackPanel panel)
                panel.ItemsUpdatingScrollMode = _follow ? ItemsUpdatingScrollMode.KeepScrollOffset : ItemsUpdatingScrollMode.KeepItemsInView;
        }
        void Follow(bool animate=false)
        {
            if (!_active || !_follow || _rows.Count == 0) return;
            bool wasAdjusting = _adjustingView; _adjustingView = true;
            try { if(_listScroll!=null)_listScroll.ChangeView(null,0,null,!animate);else _list.ScrollIntoView(_rows[0]); }
            finally { _adjustingView = wasAdjusting; }
        }
        sealed record ViewAnchor(LogRow Row, double Y);
        ViewAnchor? CaptureAnchor()
        {
            if (_listScroll == null || !_listScroll.IsLoaded) return null;
            foreach (var container in UiElements.Descendants(_list).OfType<ListViewItem>())
            {
                double y = container.TransformToVisual(_listScroll).TransformPoint(new Windows.Foundation.Point()).Y;
                if (y + container.ActualHeight > 0 && y < _listScroll.ViewportHeight && container.Content is LogRow row)
                    return new(row, y);
            }
            return null;
        }
        void RestoreAnchor(ViewAnchor? anchor)
        {
            if (anchor == null || _listScroll == null || !_listScroll.IsLoaded || _rows.Count == 0) return;
            bool wasAdjusting = _adjustingView; _adjustingView = true;
            try
            {
                bool retained = _rows.Contains(anchor.Row);
                var row = retained ? anchor.Row : _rows[^1];
                _list.ScrollIntoView(row); _list.UpdateLayout();
                if (_list.ContainerFromItem(row) is FrameworkElement container)
                {
                    double y = container.TransformToVisual(_listScroll).TransformPoint(new Windows.Foundation.Point()).Y;
                    double offset = _listScroll.VerticalOffset + y - (retained ? anchor.Y : 0);
                    _listScroll.ChangeView(null, Math.Clamp(offset, 0, _listScroll.ScrollableHeight), null, true);
                }
            }
            finally { _adjustingView = wasAdjusting; }
        }
        void UpdateStatus() => _status.Text = _lastStatus + $" 显示 {_rows.Count:N0} / 10,000 条。" + (_follow ? " 正在跟随最新记录。" : " 已暂停自动滚动，列表继续更新。");
        async Task ExportAsync()
        {
            if (!_active || _exporting || _lifetime == null) return;
            int generation = _generation; var token = _lifetime.Token; _exporting = true; _export.IsEnabled = false;
            try
            {
                var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.Downloads, SuggestedFileName = $"映屿-原始日志-{DateTime.Now:yyyyMMdd-HHmmss}" };
                picker.FileTypeChoices.Add("原始日志压缩包", new List<string> { ".zip" });
                InitializeWithWindow.Initialize(picker, Microsoft.UI.Win32Interop.GetWindowFromWindowId(_root.XamlRoot.ContentIslandEnvironment.AppWindowId));
                var file = await picker.PickSaveFileAsync();
                if (file == null || !_active || generation != _generation || token.IsCancellationRequested) return;
                var result = await Task.Run(() => LogExport.WriteAsync(file.Path, token), token);
                if (_active && generation == _generation) { _lastStatus = $"已导出 {result.Files} 份原始日志、{result.Rows} 行记录。"; UpdateStatus(); }
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                if (_active && generation == _generation) { _lastStatus = "日志导出未完成，原日志保留。异常类型：" + error.GetType().Name; UpdateStatus(); }
            }
            finally { _exporting = false; if (_active) SafeUi(() => _export.IsEnabled = true, "日志导出按钮恢复未完成"); }
        }
        void SafeUi(Action action, string failure)
        {
            try { action(); }
            catch (Exception error) { if (_uiWarnings++ < 3) Warn(failure, error); }
        }
        static TextBlock Text(string text, double size, bool secondary = false) => new()
        {
            Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap,
            Tag = secondary ? "YingyuLogSecondary" : "YingyuLogText", Opacity = 1, FontWeight = size >= 24 ? FontWeights.SemiBold : FontWeights.Normal
        };
        static Button ActionButton(string title) => new() { Content = title, Padding = new Thickness(18, 10, 18, 10), CornerRadius = new CornerRadius(8), FontSize = 14 };
        static Border Card(UIElement content, Thickness padding) => new()
        {
            Tag = "YingyuLogCard", Child = content, Padding = padding, CornerRadius = new CornerRadius(18),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 29, 30, 35)),
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(28, 255, 255, 255)), BorderThickness = new Thickness(1)
        };
        static Grid Columns()
        {
            var grid = new Grid { ColumnSpacing = 18 };
            foreach (double width in new[] { 112d, 172d, 68d }) grid.ColumnDefinitions.Add(new() { Width = new GridLength(width) });
            grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); return grid;
        }
    }
}
