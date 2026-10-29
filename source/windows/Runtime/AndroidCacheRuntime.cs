using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

public static class AndroidCacheRuntime
{
    static readonly ConditionalWeakTable<object, State> Pages = new();
    static readonly HashSet<object> Pauses = new();
    static readonly object Sync = new();
    static AndroidImageOptions? settings;
    public static AndroidImageOptions Options
    {
        get
        {
            lock (Sync)
            {
                if (settings != null) return settings;
                try { settings = JsonSerializer.Deserialize<AndroidImageOptions>(File.ReadAllText(PolicyPath))?.Validate(); }
                catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { }
                return settings ??= new();
            }
        }
    }
    static string PolicyPath => Path.Combine(CachePaths.UserDataRoot, "image-policy.json");
    public static bool IsPaused { get { lock (Sync) return Pauses.Count > 0; } }
    public static void Pause(object owner, bool value)
    {
        bool paused;
        lock (Sync) { if (value) Pauses.Add(owner); else Pauses.Remove(owner); paused = Pauses.Count > 0; }
        AndroidCacheImages.Scheduler.Pause(paused);
        BrowseCachePolicy.Pause(paused);
    }
    public static void Save(AndroidImageOptions value)
    {
        var next = value.Validate();
        Directory.CreateDirectory(Path.GetDirectoryName(PolicyPath)!);
        string temporary = PolicyPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(next)); File.Move(temporary, PolicyPath, true);
        lock (Sync) settings = next;
    }
    public static void Configure(object page) => Pages.GetValue(page, key => new State(key));
    public static Task DisabledInitialization() => Task.CompletedTask;
    sealed class State
    {
        readonly object page;
        readonly FrameworkElement element;
        readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
        bool wasPaused, attached;
        readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        public State(object page)
        {
            this.page = page; element = (FrameworkElement)page;
            timer = element.DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromMilliseconds(100); timer.IsRepeating = true;
            timer.Tick += (_, _) => Check();
            element.Loaded += (_, _) => { Attach(); timer.Start(); Check(); };
            // A discarded page must release its owner. Its existing unload
            // path cancels page requests; keeping this owner would pause a
            // subsequently created page forever.
            element.Unloaded += (_, _) => { timer.Stop(); Pause(this, false); };
            if (element.IsLoaded) { Attach(); timer.Start(); Check(); }
        }
        bool ActivePlayback => (bool)(page.GetType().GetProperty("IsPlaybackActive", Flags)?.GetValue(page) ?? false);
        void Check()
        {
            var handle = (IntPtr)(page.GetType().GetProperty("MainWindowHandle", Flags)?.GetValue(page) ?? IntPtr.Zero);
            bool paused = !element.IsLoaded || ActivePlayback || (handle != IntPtr.Zero && IsIconic(handle));
            Pause(this, paused);
            if (wasPaused == paused) return;
            wasPaused = paused;
            var cache = Access.Get<PosterCacheService>(page, "_posterCache");
            if (paused) cache.PauseNetworkRequests();
            else
            {
                cache.ResumeNetworkRequests(); Access.Call(page, "ResetPosterLoads"); Access.Call(page, "ReloadMissingPosters");CachedArtwork.WarmCurrent(page);
            }
        }
        void Attach()
        {
            if (attached) return; attached = true;
            foreach (string name in new[] { "ArtworkInitializationOverlay", "ArtworkInitializationModeCombo", "InitializeArtworkCacheButton", "ArtworkInitializationSettingsText", "ArtworkSizeCombo", "PosterRefreshFrequencyCombo", "CacheSyncIntervalCombo" })
                if (page.GetType().GetField(name, Flags)?.GetValue(page) is FrameworkElement old) old.Visibility = Visibility.Collapsed;
            var section = Access.Get<Border>(page, "CacheSettingsSection");
            var panel = new StackPanel { Spacing = 14 };
            panel.Children.Add(new TextBlock { Text = "图片与浏览缓存", FontSize = 20 });
            panel.Children.Add(new TextBlock { Text = "已缓存图片可在进入屏幕前读取，不受下载速度、请求间隔及下载并发限制；缺少缓存的图片仅在进入屏幕后按加载设置下载。", TextWrapping = TextWrapping.Wrap });
            Choice(panel, "图片加载速度", new[] { ("快速 · 0.4 秒", 400), ("均衡 · 1 秒", 1000), ("慢速 · 2 秒", 2000) }, Options.SpacingMilliseconds,
                value => Save(Options with { SpacingMilliseconds = value }));
            Choice(panel, "每秒图片请求上限", new[] { ("1 次", 1), ("2 次", 2), ("3 次", 3), ("不限", 0) }, Options.RequestLimit,
                value => Save(Options with { RequestLimit = value }));
            Choice(panel, "图片缓存容量", new[] { ("1 GB", 1), ("5 GB", 5), ("10 GB", 10) }, Options.CacheGB,
                value => { Save(Options with { CacheGB = value }); _ = ApplyLimit(); });
            Choice(panel, "详情大图自动清理", new[] { ("从不自动清理", 0), ("15 天未使用", 15), ("30 天未使用", 30), ("60 天未使用", 60) }, Options.AutoCleanDays,
                value => { Save(Options with { AutoCleanDays = value }); _ = ApplyLimit(); });
            Choice(panel, "浏览资料自动刷新", new[] { ("5 分钟", 5), ("15 分钟", 15), ("30 分钟", 30) }, BrowseCachePolicy.RefreshMinutes,
                value => BrowseCachePolicy.RefreshMinutes = value);
            Choice(panel, "视频片段缓存", VideoCacheSettings.Choices.Select(pair => (pair.Value, pair.Key)).ToArray(), VideoCacheSettings.LimitGB,
                VideoCacheSettings.Configure);
            Action(panel, "刷新缓存用量", async () =>
            {
                var stats = await AndroidCacheImages.Statistics(new object(), CancellationToken.None);
                status.Text = $"图片 {stats.FileCount:N0} 张 · {stats.TotalBytes / 1048576.0:0.0} MiB；视频片段 {VideoCacheSettings.UsedBytes / 1048576.0:0.0} MiB";
            }, false);
            Action(panel, "清理海报缓存", async () => { await AndroidCacheImages.ClearPosters(new object(), CancellationToken.None); Access.Call(page, "ResetPosterLoads"); }, true);
            Action(panel, "清理详情大图", AndroidCacheImages.ClearArtwork, true);
            Action(panel, "清理浏览资料", BrowseCachePolicy.ClearAsync, true);
            Action(panel, "清理视频片段", () => { VideoCacheSettings.Clear(); return Task.CompletedTask; }, true);
            panel.Children.Add(status); section.Child = panel;
        }
        async Task ApplyLimit()
        { try { await AndroidCacheImages.Enforce(new object(), CancellationToken.None); } catch (Exception error) { status.Text = "图片缓存调整失败：" + error.Message; } }
        void Choice(StackPanel parent, string title, (string Label, int Value)[] choices, int selected, Action<int> save)
        {
            var combo = new ComboBox { Header = title, MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Left };
            foreach (var choice in choices) combo.Items.Add(new ComboBoxItem { Content = choice.Label, Tag = choice.Value });
            combo.SelectedIndex = Math.Max(0, Array.FindIndex(choices, item => item.Value == selected));
            combo.SelectionChanged += (_, _) =>
            {
                try { save((int)((ComboBoxItem)combo.SelectedItem).Tag); status.Text = "设置已保存"; }
                catch (Exception error) { status.Text = "设置保存失败：" + error.Message; }
            };
            parent.Children.Add(combo);
        }
        void Action(StackPanel parent, string title, Func<Task> action, bool confirm)
        {
            var button = new Button { Content = title };
            button.Click += async (_, _) =>
            {
                if (confirm && ActivePlayback) { status.Text = "请在播放结束后清理缓存。"; return; }
                if (confirm)
                {
                    var dialog = new ContentDialog { XamlRoot = element.XamlRoot, Title = title,
                        Content = "只删除所选缓存，账号、设置和观看进度保留。", PrimaryButtonText = "清理", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
                    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
                }
                button.IsEnabled = false;
                try { await action(); if (confirm) status.Text = "已完成"; }
                catch (Exception error) { status.Text = "操作未完成：" + error.Message; }
                finally { button.IsEnabled = true; }
            };
            parent.Children.Add(button);
        }
    }
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr handle);
}
