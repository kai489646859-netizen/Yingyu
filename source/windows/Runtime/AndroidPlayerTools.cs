using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// Android menu.dart order; original desktop actions retain their event handlers.
internal static class AndroidPlayerTools
{
    static readonly ConditionalWeakTable<object, AudioState> Audio = new();
    static readonly ConditionalWeakTable<object, PictureState> Pictures = new();
    sealed class PictureState { internal int Generation; internal double Preset; }
    sealed class AudioState { internal int Generation; internal string? Written; internal int Mode; }
    internal static UIElement Build(object session, object overlay, UIElement original,bool subtitlesFirst=false)
        => new Menu(session, overlay, original,subtitlesFirst).Root;

    sealed class Menu
    {
        readonly object session, overlay;
        readonly MpvClient client;
        readonly int generation;
        readonly FrameworkElement element;
        readonly StackPanel body = new() { Spacing=8 };
        readonly TextBlock title = new() { Text="播放器菜单",FontSize=14,TextWrapping=TextWrapping.Wrap };
        readonly TextBlock status = new() { FontSize=13,TextWrapping=TextWrapping.Wrap };
        readonly Button back = new() { Content="返回",Visibility=Visibility.Collapsed,MinWidth=64 };
        readonly List<(string Label,UIElement View)> pages = new();
        readonly List<UIElement> originalStatus = new();
        internal Grid Root { get; } = new() { MinWidth=0,MaxWidth=360,RowSpacing=10,Margin=new(0) };
        bool Current => client is {IsDisposed:false} && generation==Access.Get<int>(session,"_mediaGeneration")
            && ReferenceEquals(client,Access.Get<MpvClient?>(session,"_mpvClient"))
            && !(bool)session.GetType().GetProperty("_isClosing",BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic)!.GetValue(session)!;
        internal Menu(object session,object overlay,UIElement original,bool subtitlesFirst)
        {
            this.session=session;this.overlay=overlay;client=Access.Get<MpvClient>(session,"_mpvClient");generation=Access.Get<int>(session,"_mediaGeneration");element=(FrameworkElement)overlay;
            Root.Width=Math.Max(1,Math.Min(336,element.ActualWidth-72));
            Root.Height=Math.Max(1,Math.Min(480,element.ActualHeight-160));
            Root.RowDefinitions.Add(new(){Height=GridLength.Auto});Root.RowDefinitions.Add(new(){Height=new(1,GridUnitType.Star)});Root.RowDefinitions.Add(new(){Height=GridLength.Auto});
            var header=new StackPanel{Orientation=Orientation.Horizontal,Spacing=12};header.Children.Add(back);header.Children.Add(title);Root.Children.Add(header);
            var scroll=new ScrollViewer{Content=body,MaxHeight=Math.Max(1,Math.Min(480,element.ActualHeight-190)),VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};Grid.SetRow(scroll,1);Root.Children.Add(scroll);
            var footer=new StackPanel{Spacing=6};footer.Children.Add(status);Grid.SetRow(footer,2);Root.Children.Add(footer);
            var source=new List<UIElement>();
            void Extract(UIElement view)
            {
                if(view is ScrollViewer{Content:UIElement child}){((ScrollViewer)view).Content=null;Extract(child);}
                else if(view is StackPanel panel){var entries=panel.Children.ToArray();panel.Children.Clear();foreach(var item in entries)Extract(item);}
                else if(view is Expander expander && expander.Header?.ToString()!="字幕位置" && expander.Content is UIElement content){expander.Content=null;Extract(content);}
                else source.Add(view);
            }
            Extract(original);
            var intro=Pane();var subtitles=Pane();var extras=Pane();var windows=Pane();var information=Pane();UIElement? position=null;
            int section=0;
            foreach(var item in source)
            {
                string text=item switch{Button b=>b.Content?.ToString()??"",NumberBox n=>n.Header?.ToString()??"",ComboBox c=>c.Header?.ToString()??"",TextBlock label=>label.Text,_=>""};
                if(item is Expander e&&e.Header?.ToString()=="字幕位置"){position=e;e.IsExpanded=true;continue;}
                if(item is NumberBox&&text.StartsWith("字幕",StringComparison.Ordinal))continue;
                if(item is NumberBox skipNumber && (text.Contains("片头") || text.Contains("片尾")))
                {
                    intro.Children.Add(SkipTimeEditor.Build(skipNumber,text.Contains("片尾"),()=>
                    {
                        if(!Current)throw new InvalidOperationException("播放会话已改变，请重新打开菜单。");
                        var raw=Read("time-pos");
                        if(!double.TryParse(raw,NumberStyles.Float,CultureInfo.InvariantCulture,out double current)||!double.IsFinite(current)||current<0)
                            current=Access.Get<double>(session,"_position");
                        return (current,Access.Get<double>(session,"_duration"));
                    },message=>status.Text=message));section=1;continue;
                }
                if(item is Button actionButton){StyleRow(actionButton);string category=text.Contains("字幕")?"desktop-subtitles":text.Contains("跳过")?"intro-save":text.Contains("定时")?"sleep":text.Contains("窗口")?"window":"desktop-action";actionButton.Click+=(_,_)=>PlaybackFeatureLog.Write(session,category,"requested");}
                if(item is Button save && text=="记住本剧跳过时间")
                {
                    save.Content="保存片头片尾";
                    save.HorizontalAlignment=HorizontalAlignment.Stretch;
                    save.HorizontalContentAlignment=HorizontalAlignment.Center;
                    save.MinHeight=42;
                    save.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;
                    save.Background=DesktopVisuals.Brush(0xFF5059BD);
                    save.Foreground=DesktopVisuals.Brush(0xFFFFFFFF);
                    save.Resources["ButtonBackgroundPointerOver"]=DesktopVisuals.Brush(0xFF5C66CF);
                    save.Resources["ButtonBackgroundPressed"]=DesktopVisuals.Brush(0xFF414AA3);
                    intro.Children.Add(save);
                    section=1;
                    continue;
                }
                if(item is TextBlock metadata&&text.StartsWith("播放信息",StringComparison.Ordinal))metadata.Text="片源信息（服务器提供）\n"+text;
                if(text.Contains("片头")||text.Contains("片尾")||text.Contains("本剧"))section=1;
                else if(text.Contains("睡眠")||text.Contains("定时")||text.Contains("窗口"))section=2;
                else if(text.StartsWith("播放信息")||text.Contains("实时解码"))section=3;
                if(item is TextBlock t&&string.IsNullOrEmpty(t.Text)){originalStatus.Add(item);continue;}
                (text.Contains("窗口")?windows:section switch{0=>subtitles,1=>intro,2=>extras,_=>information}).Children.Add(item);
            }
            foreach(var item in originalStatus)footer.Children.Add(item);
            var outputFact=new TextBlock{TextWrapping=TextWrapping.Wrap};information.Children.Insert(0,outputFact);information.Loaded+=(_,_)=>{if(Current)outputFact.Text="当前播放方式："+MediaNotice.PlaybackMessage(session,NetworkBluray.MenuTitles(session).Count>0);};
            pages.Add(("片头片尾",intro));
            pages.Add(("章节选择",Chapters()));
            pages.Add(("弹幕",PlayerDanmaku.Menu(session)));
            subtitles.Children.Insert(0,Action("选择本地字幕文件…",()=>DesktopSubtitles.Pick(session)));
            subtitles.Children.Insert(1,new TextBlock{Text="也可将字幕文件直接拖入播放画面",FontSize=12,TextWrapping=TextWrapping.Wrap});
            subtitles.Children.Add(new Expander{Header="字幕延迟",HorizontalAlignment=HorizontalAlignment.Stretch,Content=Adjustment("sub-delay","_liveSubtitleDelay",-3600,3600,0.1,0,"字幕延迟（秒；正数晚出现）",new[]{-1d,-.1,.1,1})});
            if(position!=null)subtitles.Children.Add(position);
            subtitles.Children.Add(new Expander{Header="字幕大小",HorizontalAlignment=HorizontalAlignment.Stretch,Content=Adjustment("sub-scale","_liveSubtitleScale",.6,2,.1,1,"字幕大小（倍）",new[]{-.1,.1})});
            pages.Add(("画面明暗",Picture()));pages.Add(("音量均衡",Balance()));
            if(NetworkBluray.MenuTitles(session).Count>0)pages.Add(("原盘播放",Disc()));
            pages.Insert(0,("字幕",subtitles));
            if(extras.Children.Count>0)pages.Add(("定时停止",extras));
            if(windows.Children.Count>0)pages.Add(("窗口",windows));
            pages.Add(("跳到指定时间",TimeJump()));
            back.Click+=(_,_)=>Home();Home();
            if(subtitlesFirst)
            {
                var entry=pages.FirstOrDefault(p=>p.Label=="字幕");
                if(entry.View is not null){body.Children.Clear();title.Visibility=Visibility.Visible;title.Text=entry.Label;back.Visibility=Visibility.Visible;body.Children.Add(entry.View);}
            }
        }
        static StackPanel Pane()=>new(){Spacing=12};
        static void StyleRow(Button button)
        {
            button.Background=DesktopVisuals.Brush(0);button.BorderThickness=new(0);button.CornerRadius=new(5);button.Padding=new(10,8,10,8);button.MinHeight=34;button.FontSize=13;
            button.Resources["ButtonBackgroundPointerOver"]=DesktopVisuals.Brush(0xFF40444D);button.Resources["ButtonBackgroundPressed"]=DesktopVisuals.Brush(0xFF4C515D);
        }
        string Read(string key){if(!Current)throw new InvalidOperationException("播放会话已改变，请重新打开菜单。");return PlaybackTransport.Get(client,key);}
        static bool Equal(string a,string b)=>a==b||double.TryParse(a,NumberStyles.Float,CultureInfo.InvariantCulture,out var x)&&double.TryParse(b,NumberStyles.Float,CultureInfo.InvariantCulture,out var y)&&double.IsFinite(x)&&double.IsFinite(y)&&Math.Abs(x-y)<.0001;
        void Write(string key,string value,bool fileLocal=false)
        {
            string before=Read(key);string property=fileLocal?"file-local-options/"+key:key;
            try{if(PlaybackTransport.Set(client,property,value)<0||!Equal(Read(key),value))throw new InvalidOperationException("播放器未确认该设置。");PlaybackFeatureLog.Write(session,"set-"+key,"readback-confirmed",double.TryParse(value,NumberStyles.Float,CultureInfo.InvariantCulture,out var n)?n:null);}
            catch{if(Current&&(PlaybackTransport.Set(client,property,before)<0||!Equal(Read(key),before)))throw new InvalidOperationException("设置恢复未被确认，请退出本次播放后重试。");throw;}
        }
        Button Action(string label,Func<Task> action)
        {
            var button=new Button{Content=label,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Left};StyleRow(button);
            button.Click+=async(_,_)=>{if(!button.IsEnabled)return;button.IsEnabled=false;long began=Environment.TickCount64;string pane=title.Text switch{"章节选择"=>"chapters","字幕延迟"=>"subtitle-delay","字幕大小"=>"subtitle-size","字幕位置"=>"subtitle-position","原盘播放"=>"disc-list","画面明暗"=>"picture","音量均衡"=>"audio-balance",_=>"menu"};try{if(!Current)throw new InvalidOperationException("播放会话已改变。");PlaybackFeatureLog.Write(session,pane,"started");await action();PlaybackFeatureLog.Write(session,pane,"accepted",Environment.TickCount64-began);}catch(Exception e){status.Text=e is InvalidOperationException?e.Message:"操作未完成，请重新打开菜单。";PlaybackFeatureLog.Write(session,pane,"failed",Environment.TickCount64-began,e.GetType().Name);}finally{button.IsEnabled=Current;}};return button;
        }
        void Home()
        {
            body.Children.Clear();status.Text="";title.Visibility=Visibility.Visible;title.Text="播放设置";back.Visibility=Visibility.Collapsed;
            var statistics=Action("影视信息（实时统计）  ›",()=>{PlayerMenus.CloseTools(overlay);PlayerMediaInfo.Toggle(session);return Task.CompletedTask;});
            ToolTipService.SetToolTip(statistics,"点击显示或隐藏实时播放统计");body.Children.Add(statistics);
            var grid=new Grid{ColumnSpacing=8,RowSpacing=8};grid.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});grid.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});
            int index=0;
            foreach(var page in pages)
            {
                var entry=page;var button=Action(entry.Label,()=>{body.Children.Clear();title.Visibility=Visibility.Visible;title.Text=entry.Label;back.Visibility=Visibility.Visible;body.Children.Add(entry.View);return Task.CompletedTask;});
                button.MinHeight=52;button.HorizontalContentAlignment=HorizontalAlignment.Center;button.Background=DesktopVisuals.Brush(0x15FFFFFF);
                int row=index/2;if(row>=grid.RowDefinitions.Count)grid.RowDefinitions.Add(new(){Height=GridLength.Auto});Grid.SetRow(button,row);Grid.SetColumn(button,index++%2);grid.Children.Add(button);
            }
            body.Children.Add(grid);
        }
        UIElement Adjustment(string property,string? field,double min,double max,double step,double reset,string caption,double[] deltas)
        {
            var pane=Pane();var value=new TextBlock{TextWrapping=TextWrapping.Wrap};pane.Children.Add(value);
            NumberBox? editor=null;bool painting=false;
            double Get(){if(!double.TryParse(Read(property),NumberStyles.Float,CultureInfo.InvariantCulture,out var n)||!double.IsFinite(n))throw new InvalidOperationException("等待轨道就绪后再调整。");return n;}
            void Set(double n){n=Math.Clamp(n,min,max);Write(property,n.ToString("0.###",CultureInfo.InvariantCulture),field==null);if(field!=null)Access.Set(session,field,n);value.Text=caption+"："+Get().ToString("0.##",CultureInfo.InvariantCulture);if(editor!=null){painting=true;try{editor.Value=Get();}finally{painting=false;}}}
            var steps=new Grid{ColumnSpacing=6};int stepColumn=0;
            foreach(double delta in deltas){double d=delta;steps.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});var change=Action((d>0?"+":"")+d.ToString("0.##",CultureInfo.InvariantCulture),()=>{Set(Get()+d);return Task.CompletedTask;});change.MinWidth=0;change.Padding=new(4,6,4,6);change.HorizontalContentAlignment=HorizontalAlignment.Center;Grid.SetColumn(change,stepColumn++);steps.Children.Add(change);}pane.Children.Add(steps);
            pane.Children.Add(Action("恢复默认",()=>{Set(reset);return Task.CompletedTask;}));
            var number=new NumberBox{Header=caption,Minimum=min,Maximum=max,SmallChange=step,SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Inline};
            editor=number;
            try{number.Value=Get();value.Text=caption+"："+number.Value.ToString("0.##",CultureInfo.InvariantCulture);}catch(InvalidOperationException e){value.Text=e.Message;}
            number.ValueChanged+=(_,e)=>{if(painting||!double.IsFinite(e.NewValue))return;try{Set(e.NewValue);}catch(Exception error){status.Text=error.Message;PlaybackFeatureLog.Write(session,"set-"+property,"failed",null,error.GetType().Name);painting=true;try{if(Current)number.Value=Get();}catch(Exception){}finally{painting=false;}}};pane.Children.Add(number);return pane;
        }
        UIElement TimeJump()
        {
            var pane=Pane();var input=new TextBox{Header="时间（时:分:秒 或 分:秒）",PlaceholderText="01:23:45"};pane.Children.Add(input);
            pane.Children.Add(Action("跳转",async()=>{
                double duration=Access.Get<double>(session,"_duration");
                if(!DesktopTime.TryParse(input.Text,out var seconds)||!double.IsFinite(duration)||duration<=0||seconds>duration)throw new InvalidOperationException("请输入影片时长内的有效时间。");
                await (Task)Access.Call(session,"SeekAsync",seconds)!;status.Text="已请求定位到 "+PlayerInfoData.Clock(seconds);
            }));return pane;
        }
        UIElement Chapters()
        {
            var pane=Pane();var list=new StackPanel{Spacing=4};pane.Children.Add(list);
            void Refresh()
            {
                list.Children.Clear();var chapters=new List<(string,double)>();
                if(int.TryParse(Read("chapter-list/count"),out var count)&&count is >0 and <=2048)for(int i=0;i<count;i++)if(double.TryParse(Read($"chapter-list/{i}/time"),NumberStyles.Float,CultureInfo.InvariantCulture,out var time)&&double.IsFinite(time)&&time>=0)chapters.Add((Read($"chapter-list/{i}/title"),time));
                if(chapters.Count==0)chapters.AddRange(NetworkBluray.MenuChapters(session).Select(c=>(c.Name,c.Seconds)));
                foreach(var entry in chapters.Select((c,i)=>(c,i))){var chapter=entry.c;string name=string.IsNullOrWhiteSpace(chapter.Item1)?$"第 {entry.i+1} 章":chapter.Item1;list.Children.Add(Action(PlayerInfoData.Clock(chapter.Item2)+"  "+name,async()=>{await (Task)Access.Call(session,"SeekAsync",chapter.Item2)!;status.Text="已请求精确定位到 "+name;}));}
                if(chapters.Count==0)list.Children.Add(new TextBlock{Text="当前资源未提供章节",TextWrapping=TextWrapping.Wrap});
            }
            pane.Children.Add(Action("刷新章节",()=>{Refresh();return Task.CompletedTask;}));pane.Loaded+=(_,_)=>{try{Refresh();}catch(Exception){status.Text="章节未能读取，请刷新或重新打开菜单。";}};return pane;
        }
        static void PaintChoice(Button button,string label,bool selected)
        {
            button.Content=selected?label+"  ·  当前":label;
            button.FontWeight=selected?Microsoft.UI.Text.FontWeights.SemiBold:Microsoft.UI.Text.FontWeights.Normal;
            button.Background=DesktopVisuals.Brush(selected?0xFF4B53A4:0x15FFFFFF);
            button.Resources["ButtonBackgroundPointerOver"]=DesktopVisuals.Brush(selected?0xFF5660BD:0xFF40444D);
            button.Resources["ButtonBackgroundPressed"]=DesktopVisuals.Brush(selected?0xFF444D99:0xFF4C515D);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,label);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(button,selected?"当前选项":"");
        }
        UIElement Picture()
        {
            var pane=Pane();pane.Children.Add(new TextBlock{Text="默认保留原始画面；以下调整仅在手动选择后应用于本次播放。",TextWrapping=TextWrapping.Wrap});
            var choices=new List<(Button Button,double Value,string Label)>();bool pending=false;
            void Refresh()
            {
                double value=Pictures.TryGetValue(session,out var state)&&state.Generation==generation?state.Preset:0;
                foreach(var choice in choices)PaintChoice(choice.Button,choice.Label,choice.Value==value);
            }
            foreach(var (value,label) in new[]{(0d,"原始画面"),(5d,"轻度提亮"),(10d,"中度提亮"),(15d,"明显提亮")})
            {
                var button=new Button{HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Left};
                StyleRow(button);button.MinHeight=40;
                choices.Add((button,value,label));pane.Children.Add(button);
                button.Click+=(_,_)=>{
                    if(pending||!Current)return;pending=true;
                    foreach(var choice in choices)choice.Button.IsEnabled=false;
                    status.Text="正在应用画面明暗…";
                    PlaybackFeatureLog.Write(session,"picture","started");_ = Complete();
                    async Task Complete()
                    {
                        long began=Environment.TickCount64;Exception? failure=null;
                        try{await PictureAdjustment.Apply(session,value).ConfigureAwait(false);PlaybackFeatureLog.Write(session,"picture",Current?"accepted":"superseded",Environment.TickCount64-began);}
                        catch(Exception error){failure=error;PlaybackFeatureLog.Write(session,"picture","failed",Environment.TickCount64-began,error.GetType().Name);}
                        finally{element.DispatcherQueue.TryEnqueue(()=>{
                            pending=false;if(!Current)return;
                            if(failure==null){var confirmed=Pictures.GetOrCreateValue(session);confirmed.Generation=generation;confirmed.Preset=value;}
                            foreach(var choice in choices)choice.Button.IsEnabled=true;
                            Refresh();
                            status.Text=failure==null?"画面明暗："+label:failure is InvalidOperationException?failure.Message:"画面明暗未能应用，请重新打开菜单。";
                        });}
                    }
                };
            }
            Refresh();pane.Loaded+=(_,_)=>Refresh();
            return pane;
        }
        UIElement Balance()
        {
            var pane=Pane();var choices=new List<(Button Button,int Value,string Label)>();
            void Refresh()
            {
                int mode=Audio.TryGetValue(session,out var state)&&state.Generation==generation?state.Mode:0;
                foreach(var choice in choices)PaintChoice(choice.Button,choice.Label,choice.Value==mode);
            }
            foreach(var (mode,label) in new[]{(0,"原始声音"),(1,"轻柔均衡"),(2,"标准均衡"),(3,"夜间模式")})
            {
                var button=Action(label,()=>{SetBalance(mode);Refresh();status.Text="音量均衡："+label;return Task.CompletedTask;});
                button.MinHeight=40;choices.Add((button,mode,label));pane.Children.Add(button);
            }
            Refresh();pane.Loaded+=(_,_)=>Refresh();return pane;
        }
        static List<string> Filters(string text)
        {
            if(text.Length==0)return new();var bytes=Encoding.UTF8.GetBytes(text);var result=new List<string>();int start=0;
            for(int i=0;i<bytes.Length;i++){if(bytes[i]==37){int end=Array.IndexOf(bytes,(byte)37,i+1);if(end<0||!int.TryParse(Encoding.ASCII.GetString(bytes,i+1,end-i-1),out int count)||count<0||end+1L+count>bytes.Length)throw new InvalidOperationException("当前音频滤镜无法确认。");i=end+count;}
                else if(bytes[i]==44){result.Add(Encoding.UTF8.GetString(bytes,start,i-start));start=i+1;}}
            result.Add(Encoding.UTF8.GetString(bytes,start,bytes.Length-start));if(result.Any(string.IsNullOrEmpty))throw new InvalidOperationException("当前音频滤镜无法确认。");return result;
        }
        void SetBalance(int mode)
        {
            if(Read("audio-out-params/format").StartsWith("spdif",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("音频直通时无法应用均衡，请使用解码输出。");
            var state=Audio.GetOrCreateValue(session);if(state.Generation!=generation){state.Generation=generation;state.Written=null;state.Mode=0;}
            string before=Read("af");if(mode==state.Mode)return;
            if(state.Written!=null&&before!=state.Written)throw new InvalidOperationException("音频设置已改变，请重新打开影片后调整。");
            var prior=Filters(before);if(state.Written==null&&prior.Any(f=>f.StartsWith("@yingyu_balance:",StringComparison.Ordinal)))throw new InvalidOperationException("已有均衡设置的状态未确认。");
            var other=prior.Where(f=>!f.StartsWith("@yingyu_balance:",StringComparison.Ordinal)).ToList();var desired=other.ToList();
            if(mode!=0){var p=mode switch{1=>("0.125","2","1.4","300"),2=>("0.09","3","2","350"),_=>("0.063","5","2.4","450")};string graph=$"acompressor=threshold={p.Item1}:ratio={p.Item2}:attack=8:release={p.Item4}:makeup={p.Item3}:knee=2.828:link=maximum:detection=rms,alimiter=limit=0.94:attack=5:release=80:level=false:latency=true";desired.Add($"@yingyu_balance:lavfi=graph=%{Encoding.UTF8.GetByteCount(graph)}%{graph}");}
            try{if(PlaybackTransport.Set(client,"file-local-options/af",string.Join(',',desired))<0)throw new InvalidOperationException("播放器未接受音量均衡。");string actual=Read("af");var entries=Filters(actual);if(!entries.Where(f=>!f.StartsWith("@yingyu_balance:",StringComparison.Ordinal)).SequenceEqual(other)||entries.Count(f=>f.StartsWith("@yingyu_balance:",StringComparison.Ordinal))!=(mode==0?0:1))throw new InvalidOperationException("音量均衡未被完整确认。");state.Written=actual;state.Mode=mode;}
            catch{if(Current&&(PlaybackTransport.Set(client,"file-local-options/af",before)<0||Read("af")!=before))throw new InvalidOperationException("音量均衡恢复失败，请退出本次播放后重试。");throw;}
        }
        UIElement Disc()
        {
            var pane=Pane();var all=new CheckBox{Content="显示全部播放列表（含不足 3 分钟的短片）"};var list=Pane();pane.Children.Add(new TextBlock{Text="选择其他播放列表将从头播放",TextWrapping=TextWrapping.Wrap});pane.Children.Add(all);pane.Children.Add(list);
            void Refresh(){list.Children.Clear();foreach(var entry in NetworkBluray.MenuTitles(session).Where(t=>all.IsChecked==true||t.Selected||t.Seconds>=180)){var title=entry;list.Children.Add(Action((title.Selected?"✓ ":"")+$"播放列表 {title.Playlist:00000} · {PlayerInfoData.Clock(title.Seconds)}",async()=>{await NetworkBluray.SelectMenuTitle(session,title.Index);Refresh();status.Text="已请求播放所选列表。";}));}}
            all.Checked+=(_,_)=>Refresh();all.Unchecked+=(_,_)=>Refresh();Refresh();return pane;
        }
    }
}
