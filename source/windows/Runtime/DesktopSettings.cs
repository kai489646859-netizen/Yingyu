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
        public string Section="AccountSettingsSection";
        public bool LayingOut;
        public DanmakuPreferences? Danmaku;
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
    public static void Open(object page)
    {
        Pages.GetValue(page,_=>new()).Section="AccountSettingsSection";
        LogCenterLauncher.Leave(page);
        if(Find(page,"ExperienceSettingsSearch") is TextBox search)search.Text="";
        Apply(page,false);
    }
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
                section.MaxWidth=1040;section.HorizontalAlignment=HorizontalAlignment.Stretch;section.Margin=new Thickness(0,0,0,16);
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
                    content.HorizontalAlignment=HorizontalAlignment.Left;content.MaxWidth=1040;content.Margin=new Thickness(0);
                    double width=Math.Min(1040,Math.Max(0,scroll.ActualWidth-48));
                    if(!double.IsFinite(content.Width)||Math.Abs(content.Width-width)>.5)content.Width=width;
                }
            }
            if(state.Danmaku is null&&Find(page,"ExperienceSettingsSection") is Border experience
                &&experience.Child is FrameworkElement experienceContent)
            {
                state.Danmaku=new DanmakuPreferences();
                if(experienceContent is StackPanel settingsPanel)settingsPanel.Children.Insert(0,state.Danmaku.View);
                else
                {
                    experience.Child=null;
                    var wrapper=new StackPanel{Spacing=12};
                    wrapper.Children.Add(state.Danmaku.View);wrapper.Children.Add(experienceContent);
                    experience.Child=wrapper;
                }
            }
            HideEpisodeDisplay(page);
            SettingsPresentation.Apply((FrameworkElement)page);
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
            Layout(page);if(current=="ExperienceSettingsSection")state.Danmaku?.Refresh();state.Queue();OnlineOnly(page);DesktopPeople.Settings(page);DesktopTheme.Navigation(page);
        }
        catch(Exception e){Report(e);}
    }
    public static string Keywords(string name)=>name switch
    {
        "AccountSettingsSection"=>"账户 账号 服务器 登录 代理 网络 进度 同步 翻译 在线 英文 日语",
        "AppearanceSettingsSection"=>"外观 窗口 主题 配色 海报 密度 圆角 个性化 动画",
        "ExperienceSettingsSection"=>"播放 字幕 音轨 延迟 大小 位置 下一集 选集 首页 栏目 快捷键 弹幕 精选 自动匹配 哔哩哔哩 腾讯 爱奇艺 芒果 弹幕速度 不透明度 显示区域 背景框 时间偏移 自建备用服务",
        "CacheSettingsSection"=>"缓存 同步 刷新 图片 海报 存储 演员 容量",
        "DiagnosticsSettingsSection"=>"日志 诊断 反馈 导出",
        _=>"关于 版本"
    };
    static void HideEpisodeDisplay(object page)
    {
        if(Find(page,"EpisodeDisplayCombo") is not {} editor
            ||Find(page,"ExperienceSettingsSection") is not {} section)return;

        // This preference belongs to the detail-page layout. Keep its saved
        // value and handler, and remove the entire label/description/control.
        editor.Visibility=Visibility.Collapsed;
        for(var node=editor.Parent as FrameworkElement;node is not null&&!ReferenceEquals(node,section);
            node=node.Parent as FrameworkElement)
        {
            if(node is Panel panel&&panel.Children.Contains(editor)
                &&panel.Children.All(child=>ReferenceEquals(child,editor)||child is TextBlock)
                &&panel.Children.OfType<TextBlock>().Any(text=>text.Text=="选集显示方式"))
            {
                panel.Visibility=Visibility.Collapsed;
                break;
            }
        }
        foreach(var text in UiElements.Descendants(section).OfType<TextBlock>())
            if(text.Text=="选集显示方式"||text.Text.StartsWith("选择详情页的选集排列方式",StringComparison.Ordinal))
                text.Visibility=Visibility.Collapsed;
    }

    sealed class DanmakuPreferences
    {
        internal StackPanel View{get;}=new(){Spacing=8,Margin=new(0,0,0,16)};
        readonly TextBlock status=new(){TextWrapping=TextWrapping.Wrap};
        readonly List<Action<DanmakuOptions>> bind=[];
        readonly List<Control> editors=[];
        readonly TextBox api=new(){Header="自建备用服务（选填，每行一个地址）",MaxLength=2600,
            MinHeight=72,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap};
        DanmakuOptions saved=new();
        bool busy;

        internal DanmakuPreferences()
        {
            View.Children.Add(new TextBlock{Text="弹幕",FontSize=20});
            View.Children.Add(new TextBlock{Text=DanmakuOptions.BuiltInSourcesText,TextWrapping=TextWrapping.Wrap});
            Toggle("显示弹幕",o=>o.Enabled,(o,v)=>o.Enabled=v);
            Toggle("自动在线匹配",o=>o.Automatic,(o,v)=>o.Automatic=v);
            Toggle("精选弹幕",o=>o.Featured,(o,v)=>o.Featured=v);
            Toggle("滚动弹幕",o=>o.Scroll,(o,v)=>o.Scroll=v);
            Toggle("顶部固定弹幕",o=>o.Top,(o,v)=>o.Top=v);
            Toggle("底部固定弹幕",o=>o.Bottom,(o,v)=>o.Bottom=v);
            Toggle("随播放窗口自动适配字号",o=>o.AdaptiveSize,(o,v)=>o.AdaptiveSize=v);
            Toggle("显示文字背景框",o=>o.Background,(o,v)=>o.Background=v);
            Number("不透明度（%）",15,100,5,o=>o.Opacity*100,(o,v)=>o.Opacity=v/100);
            Number("基础字号",14,40,1,o=>o.FontSize,(o,v)=>o.FontSize=v);
            Number("显示区域（%）",20,100,5,o=>o.Area*100,(o,v)=>o.Area=v/100);
            Number("弹幕速度（倍）",.45,2.25,.05,o=>Math.Round(9/o.TravelSeconds,2),(o,v)=>o.TravelSeconds=9/v);
            Number("时间偏移（秒，正数晚出现）",-3600,3600,.1,o=>o.Delay,(o,v)=>o.Delay=v);
            Button("恢复默认显示",()=>Change(o=>
            {
                var defaults=new DanmakuOptions();
                o.Opacity=defaults.Opacity;
                o.FontSize=defaults.FontSize;
                o.AdaptiveSize=defaults.AdaptiveSize;
                o.Background=defaults.Background;
                o.Area=defaults.Area;
                o.TravelSeconds=defaults.TravelSeconds;
                o.Scroll=defaults.Scroll;
                o.Top=defaults.Top;
                o.Bottom=defaults.Bottom;
            }));

            Add(api);
            Button("保存服务地址",()=>
            {
                string text=api.Text;
                Change(o=>o.CompatibleApi=text,refreshApi:true);
            });
            Button("清空弹幕缓存",ClearCache);
            View.Children.Add(new TextBlock
            {
                Text="当前影片的在线搜索、候选选择和本地 XML 导入可在播放器中操作。",
                TextWrapping=TextWrapping.Wrap,Opacity=.72
            });
            View.Children.Add(status);
            View.Loaded+=(_,_)=>Refresh();
        }

        void Add(Control control)
        {
            control.IsEnabled=false;
            editors.Add(control);
            View.Children.Add(control);
        }

        void Toggle(string label,Func<DanmakuOptions,bool> read,Action<DanmakuOptions,bool> write)
        {
            var toggle=new ToggleSwitch{Header=label};
            Add(toggle);
            bind.Add(o=>toggle.IsOn=read(o));
            toggle.Toggled+=(_,_)=>
            {
                bool value=toggle.IsOn;
                Change(o=>write(o,value));
            };
        }

        void Number(string label,double min,double max,double step,Func<DanmakuOptions,double> read,Action<DanmakuOptions,double> write)
        {
            var input=new NumberBox{Header=label,Minimum=min,Maximum=max,SmallChange=step,
                SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Compact,HorizontalAlignment=HorizontalAlignment.Left};
            Add(input);
            bind.Add(o=>input.Value=read(o));
            input.ValueChanged+=(_,args)=>
            {
                double value=args.NewValue;
                if(double.IsFinite(value))Change(o=>write(o,Math.Clamp(value,min,max)));
            };
        }

        void Button(string label,Action action)
        {
            var button=new Button{Content=label};
            Add(button);
            button.Click+=(_,_)=>action();
        }

        void Busy(bool value)
        {
            busy=value;
            foreach(var control in editors)control.IsEnabled=!value;
        }

        void Paint()
        {
            foreach(var apply in bind)apply(saved);
        }

        internal async void Refresh()
        {
            if(busy)return;
            Busy(true);
            try
            {
                saved=await DanmakuStorage.ReadOptions(CancellationToken.None);
                api.Text=saved.CompatibleApi;
                Paint();
                status.Text="";
            }
            catch(Exception e){status.Text="暂时无法读取弹幕设置";Report(e);}
            finally{Busy(false);}
        }

        async void Change(Action<DanmakuOptions> edit,bool refreshApi=false)
        {
            if(busy)return;
            Busy(true);
            try
            {
                await DanmakuStorage.UpdateOptions(edit);
                saved=await DanmakuStorage.ReadOptions(CancellationToken.None);
                PlayerDanmaku.ApplySettings(edit);
                if(refreshApi)api.Text=saved.CompatibleApi;
                Paint();
                status.Text="";
            }
            catch(Exception e){Paint();status.Text="未能保存弹幕设置";Report(e);}
            finally{Busy(false);}
        }

        async void ClearCache()
        {
            if(busy)return;
            Busy(true);
            try
            {
                await DanmakuStorage.Clear();
                status.Text="弹幕缓存已清空";
            }
            catch(Exception e){status.Text="暂时无法清空弹幕缓存";Report(e);}
            finally{Busy(false);}
        }
    }
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
