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
            var update = new Button { Content = "检查更新" };
            var releaseLink = new HyperlinkButton { Content = "查看发布说明和安装包", Visibility = Visibility.Collapsed };
            var updateStatus = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 13 };
            var download = new Button { Content = "下载安装包", Visibility = Visibility.Collapsed };
            var pause = new Button { Content = "暂停下载", Visibility = Visibility.Collapsed };
            var install = new Button { Content = "安装更新", Visibility = Visibility.Collapsed };
            var progressBar = new ProgressBar { Minimum = 0, Maximum = 100, Visibility = Visibility.Collapsed };
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            actions.Children.Add(update); actions.Children.Add(download); actions.Children.Add(pause); actions.Children.Add(install);
            WindowsReleaseCheck.Release? release = null;
            CancellationTokenSource? transfer = null;
            update.Click += async (_, _) =>
            {
                update.IsEnabled = false;
                release = null;
                download.Visibility = install.Visibility = progressBar.Visibility = Visibility.Collapsed;
                releaseLink.Visibility = Visibility.Collapsed;
                updateStatus.Text = "正在查询 GitHub 的 Windows 发行版…";
                try
                {
                    release = await WindowsReleaseCheck.Check();
                    if (release is null)
                    {
                        updateStatus.Text = "GitHub 暂无比当前版本更新的 Windows 安装包。";
                        return;
                    }
                    updateStatus.Text = release.Installer is null
                        ? $"发现 Windows {release.Version}。该发布缺少可校验的安装包资料，请查看发布页。"
                        : $"发现 Windows {release.Version} · {release.Installer.Length / (1024d * 1024):0.#} MiB";
                    download.Content = "下载安装包";
                    if (release.Installer is not null) download.Visibility = Visibility.Visible;
                    releaseLink.NavigateUri = release.Page;
                    releaseLink.Visibility = Visibility.Visible;
                }
                catch (InvalidOperationException error) { updateStatus.Text = error.Message; }
                catch (Exception error) when (error is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
                { updateStatus.Text = "暂时无法查询 Windows 更新，请稍后重试。"; }
                finally { update.IsEnabled = true; }
            };
            pause.Click += (_, _) => { pause.IsEnabled = false; transfer?.Cancel(); };
            download.Click += async (_, _) =>
            {
                if (release?.Installer is not {} asset || transfer is not null) return;
                using var request = new CancellationTokenSource();
                transfer = request;
                update.IsEnabled = false;
                download.Visibility = install.Visibility = Visibility.Collapsed;
                pause.Visibility = progressBar.Visibility = Visibility.Visible;
                pause.IsEnabled = true;
                progressBar.Value = 0;
                updateStatus.Text = "正在准备下载…";
                var progress = new Progress<long>(bytes =>
                {
                    if (!ReferenceEquals(transfer, request) || request.IsCancellationRequested) return;
                    progressBar.Value = bytes * 100d / asset.Length;
                    updateStatus.Text = bytes == asset.Length ? "正在校验 SHA-256…"
                        : $"已下载 {bytes / (1024d * 1024):0.#} / {asset.Length / (1024d * 1024):0.#} MiB";
                });
                try
                {
                    await WindowsUpdateDownload.Fetch(asset, progress, request.Token);
                    progressBar.Value = 100;
                    updateStatus.Text = "安装包已下载并通过 SHA-256 校验。";
                    install.Visibility = Visibility.Visible;
                }
                catch (OperationCanceledException) when (request.IsCancellationRequested)
                {
                    updateStatus.Text = "已暂停，继续下载时会尝试使用已下载部分。";
                    download.Content = "继续下载";
                    download.Visibility = Visibility.Visible;
                }
                catch (Exception error) when (error is IOException or HttpRequestException or OperationCanceledException or UnauthorizedAccessException)
                {
                    updateStatus.Text = error is IOException ? error.Message : "下载安装包失败，请重试。";
                    download.Content = "重试下载";
                    download.Visibility = Visibility.Visible;
                }
                finally { transfer = null; pause.Visibility = Visibility.Collapsed; update.IsEnabled = true; }
            };
            install.Click += async (_, _) =>
            {
                if (release?.Installer is not {} asset || Body.XamlRoot is not {} root) return;
                update.IsEnabled = install.IsEnabled = false;
                try
                {
                    var dialog = new ContentDialog
                    {
                        XamlRoot = root, Title = $"安装 Windows {release.Version}",
                        Content = "安装程序会关闭映屿并覆盖更新。请先退出正在播放的影片，账号、进度与缓存保留在原目录。",
                        PrimaryButtonText = "打开安装程序", CloseButtonText = "稍后", DefaultButton = ContentDialogButton.Close
                    };
                    if (await ModalProtection.Show(dialog) != ContentDialogResult.Primary) return;
                    await WindowsUpdateDownload.Install(asset);
                    updateStatus.Text = "安装程序已启动，请完成覆盖安装。";
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException
                    or System.ComponentModel.Win32Exception or System.Runtime.InteropServices.COMException)
                {
                    updateStatus.Text = "无法启动已校验的安装包，可重新下载后重试。";
                    download.Content = "重新下载";
                    download.Visibility = Visibility.Visible;
                    install.Visibility = Visibility.Collapsed;
                }
                finally { update.IsEnabled = install.IsEnabled = true; }
            };
            content.Children.Add(actions);content.Children.Add(progressBar);
            content.Children.Add(updateStatus);content.Children.Add(releaseLink);
        }
    }
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    internal static void Apply(FrameworkElement page,DesktopThemePalette palette){
        if(Access.Get<object?>(page,"AboutSettingsSection") is not Border section)return;
        var state=States.GetValue(page,_=>new());
        if(!ReferenceEquals(section.Child,state.Body))section.Child=state.Body;
        section.MaxWidth=760;
        state.Version.Text="版本 "+typeof(AboutPresentation).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute),false).OfType<System.Reflection.AssemblyInformationalVersionAttribute>().Single().InformationalVersion.Split('+')[0];
        state.PathText.Text="数据目录："+CachePaths.UserDataRoot+"\n缓存目录："+CachePaths.CacheRoot;
        state.Card.Background=DesktopVisuals.Brush(palette.Surface);state.Card.BorderBrush=DesktopVisuals.Brush(palette.Outline);
        foreach(var text in UiElements.Descendants(state.Body).OfType<TextBlock>())text.Foreground=DesktopVisuals.Brush(text.FontSize>=15?palette.Text:palette.Secondary);
        // Settings' save footer does not describe the read-only About page.
        if(Access.Get<object?>(page,"SettingsView") is FrameworkElement settings)
            foreach(var text in UiElements.Descendants(settings).OfType<TextBlock>().Where(t=>t.Text=="设置会自动保存。"))text.Visibility=section.Visibility==Visibility.Visible?Visibility.Collapsed:Visibility.Visible;
    }
}
