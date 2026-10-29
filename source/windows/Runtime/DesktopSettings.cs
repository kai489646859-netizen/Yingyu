using System.Reflection;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

public static class DesktopSettings
{
    static readonly ConditionalWeakTable<object,Selection> Pages=new();
    sealed class Selection
    {
        public string Section="AppearanceSettingsSection";
        public bool LayingOut;
        ScrollViewer? scroll;
        WeakReference<object>? owner;
        bool queued;
        public void Attach(object page,ScrollViewer target)
        {
            if(ReferenceEquals(scroll,target))return;
            if(scroll!=null){scroll.Loaded-=Loaded;scroll.SizeChanged-=Resized;}
            scroll=target;owner=new(page);scroll.Loaded+=Loaded;scroll.SizeChanged+=Resized;
        }
        void Loaded(object sender,RoutedEventArgs args)=>Queue();
        void Resized(object sender,SizeChangedEventArgs args)
        {if(Math.Abs(args.NewSize.Width-args.PreviousSize.Width)>.5)Queue();}
        public void Queue()
        {
            if(queued||scroll==null)return;
            queued=true;
            if(!scroll.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>
            {
                queued=false;
                if(owner?.TryGetTarget(out var page)==true)Layout(page);
            }))queued=false;
        }
    }
    static readonly string[] Names=["AccountSettingsSection","AppearanceSettingsSection","ExperienceSettingsSection","CacheSettingsSection","DiagnosticsSettingsSection","AboutSettingsSection"];
    static FrameworkElement? Find(object page,string name)=>page.GetType().GetField(name,BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic)?.GetValue(page) as FrameworkElement
        ?? (page as FrameworkElement)?.FindName(name) as FrameworkElement;
    public static void Open(object page)=>Apply(page,false);
    public static void Category(object page)=>Apply(page,true);
    public static void Filter(object page)=>Apply(page,false);
    public static void Layout(object page)
    {
        var state=Pages.GetValue(page,_=>new());
        if(state.LayingOut)return;
        state.LayingOut=true;
        try
        {
            // Keep a readable desktop column as the window grows. These are
            // existing section containers; their controls and bindings stay put.
            foreach(string name in Names)if(Find(page,name) is {} section)
            {
                section.MaxWidth=880;section.HorizontalAlignment=HorizontalAlignment.Stretch;section.Margin=new Thickness(0,0,0,16);
                if(section is Border border)border.Padding=new Thickness(24);
            }
            // Their live replacements are the desktop mode selector and the
            // cache page. Remove only the now-empty legacy label/control row.
            foreach(string name in new[]{"ThemeCombo","ArtworkSizeCombo","PosterRefreshFrequencyCombo"})
                if(Find(page,name) is {Visibility:Visibility.Collapsed,Parent:Grid row} hidden
                    &&row.ColumnDefinitions.Count==2&&row.Children.Contains(hidden)
                    &&row.Children.Where(child=>!ReferenceEquals(child,hidden)).All(child=>child is TextBlock
                        ||child is StackPanel labels&&labels.Children.All(label=>label is TextBlock)))
                    row.Visibility=Visibility.Collapsed;
            if(Find(page,"SettingsContentScrollViewer") is ScrollViewer scroll)
            {
                // Open runs before the previously hidden settings view has its
                // real width. Resolve again when this viewport is laid out,
                // instead of waiting for an unrelated theme change to do it.
                state.Attach(page,scroll);
                scroll.Padding=new Thickness(24,8,24,24);scroll.HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled;scroll.HorizontalScrollMode=ScrollMode.Disabled;
                if(scroll.Content is FrameworkElement content && scroll.ActualWidth>0)
                {
                    content.HorizontalAlignment=HorizontalAlignment.Center;content.MaxWidth=880;content.Margin=new Thickness(0);
                    double width=Math.Min(880,Math.Max(0,scroll.ActualWidth-48));
                    if(!double.IsFinite(content.Width)||Math.Abs(content.Width-width)>.5)content.Width=width;
                }
            }
        }
        catch(Exception e){Report(e);}
        finally{state.LayingOut=false;}
    }
    static void Apply(object page,bool category)
    {
        try
        {
            var state=Pages.GetValue(page,_=>new());
            if(category&&Access.Get<FrameworkElement?>(page,"_settingsNavigationTarget") is {} target&&Names.Contains(target.Name))state.Section=target.Name;
            string query=(Find(page,"ExperienceSettingsSearch") as TextBox)?.Text.Trim()??"";
            var matches=Names.Where(name=>query.Length==0||Keywords(name).Contains(query,StringComparison.OrdinalIgnoreCase)).ToList();
            string? current=matches.Contains(state.Section)?state.Section:matches.FirstOrDefault();
            foreach(string name in Names)if(Find(page,name) is {} section)section.Visibility=name==current?Visibility.Visible:Visibility.Collapsed;
            if(Find(page,"SettingsNoResultsText") is {} empty)empty.Visibility=current==null?Visibility.Visible:Visibility.Collapsed;
            if(query.Length==0&&current!=null)state.Section=current;
            if(Find(page,"SettingsContentScrollViewer") is ScrollViewer scroll)scroll.ChangeView(null,0,null,true);
            Layout(page);state.Queue();OnlineOnly(page);DesktopPeople.Settings(page);DesktopTheme.Navigation(page);
        }
        catch(Exception e){Report(e);}
    }
    public static string Keywords(string name)=>name switch
    {
        "AccountSettingsSection"=>"账户 账号 服务器 登录 代理 网络 进度 同步 翻译 在线 英文 日语",
        "AppearanceSettingsSection"=>"外观 窗口 主题 配色 海报 密度 圆角 个性化 动画",
        "ExperienceSettingsSection"=>"播放 字幕 音轨 延迟 大小 位置 下一集 选集 首页 栏目 快捷键",
        "CacheSettingsSection"=>"缓存 同步 刷新 图片 海报 存储 演员 容量",
        "DiagnosticsSettingsSection"=>"日志 诊断 反馈 导出",
        _=>"关于 版本"
    };
    static void OnlineOnly(object page)
    {
        foreach(string name in new[]{"TranslationModeCombo","OfflineTranslationStatus","ImportOfflineTranslationButton"})if(Find(page,name) is {} element)element.Visibility=Visibility.Collapsed;
        if(Find(page,"AccountSettingsSection") is {} section)
        foreach(var item in UiElements.Descendants(section))
        {
            if(item is Button button&&(button.Content?.ToString()?.Contains("离线")??false))button.Visibility=Visibility.Collapsed;
            if(item is TextBlock text)
            {
                if(text.Text=="翻译方式")text.Visibility=Visibility.Collapsed;
                else if(text.Text.Contains("离线")||text.Text.Contains("语言包"))text.Text="简介使用在线翻译，无需语言包；失败时保留原文，可稍后重试。";
            }
        }
    }
    static void Report(Exception e){try{PlaybackTransport.Write("Warning","Desktop.Settings","设置界面未完全调整，保留可用控件；"+e.GetType().Name);}catch(Exception){}}
}
