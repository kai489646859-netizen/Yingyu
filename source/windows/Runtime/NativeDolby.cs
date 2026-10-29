using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

// Evidence comes from the native output, never from a container DV label.
public static class NativeDolby
{
    internal readonly record struct Status(bool Available,bool Active,int Reason,ulong Epoch,int Profile,ulong Packed,ulong Presented,ulong FelComposed,ulong FelPresented,bool Complete,bool Fatal,int NativeResult,bool UiSafe,bool OsdBlocked,int OutputStage,int OutputResult,int CapsVersion,uint OutputFlags,uint OutputTechnology,int InitialCapsResult)
    {
        internal bool Confirmed=>Available&&Active&&Complete&&!Fatal&&Presented>0;
        internal string Connection=>OutputTechnology switch{5=>"HDMI",10=>"DisplayPort",11=>"内置 DisplayPort",6=>"内置 LVDS",0xffffffff=>"连接类型未提供",_=>"其他显示连接"};
        internal string OutputDecision=>(OutputFlags&4)==0?"not-queried":(OutputFlags&8)==0?"no-tv-led-capability":(OutputFlags&16)==0?"low-latency-only":Confirmed?"native-presented":"tv-led-capability-reported";
        internal string OutputCheck=>"上次核对："+Connection+" · "+(OutputDecision switch{"not-queried"=>"尚未完成驱动能力查询","no-tv-led-capability"=>"驱动查询成功，未报告 TV-led 杜比能力","low-latency-only"=>"仅报告低延迟杜比，当前内置后端尚未支持","native-presented"=>"原生杜比已实际呈现",_=>"已报告 TV-led 能力，尚未确认原生呈现"});
        internal string Refusal=>Reason==4?OutputStage switch{1 or 2 or 10=>"系统显示状态查询失败",4=>"驱动未能识别当前显示输出",7=>Connection+" 输出未报告 TV-led 杜比能力",_=>Why(Reason)}:Reason==8&&OutputStage is 5 or 6?"驱动的杜比能力查询失败":Why(Reason);
        internal string Summary=>Confirmed?"Dolby Vision 原生输出"+(FelPresented>0?" · FEL 已参与画面重建":""):Fatal?"杜比画面不完整，已暂停":"SDR/HDR 转换 · "+Refusal;
        internal string Diagnostic=>$"pipeline=mpv-color-managed; nativeTransport=disabled; integrityKnown={Available}; integrityEpoch={Epoch}; profile={Profile}; complete={Complete}; fatal={Fatal}; integrityReason={Reason}";
    }
    static readonly ConditionalWeakTable<object,UiState> Uis=new();
    static readonly ConditionalWeakTable<object,object> ClosingSessions=new();
    static readonly List<WeakReference<UiState>> Live=new();
    static readonly ConditionalWeakTable<object,SampleState> Samples=new();
    static readonly ConditionalWeakTable<FlyoutBase,object> Popups=new();
    sealed class SampleState{internal string Last="";internal long LastAt;internal Status Value;}
    internal static Status Read(object session)
    {
        if(IsClosing(session)||!Samples.TryGetValue(session,out var state))return default;
        lock(state)return state.Value;
    }
    static Status ReadCore(object session)
    {
        if(IsClosing(session))return default;
        var client=Access.Get<MpvClient?>(session,"_mpvClient");if(client is null||client.IsDisposed)return default;
        string value=PlaybackTransport.Get(client,"native-dolby-status");
        if(value.Length==0||value.Length>2048)return default;
        try{
            using var json=JsonDocument.Parse(value);var r=json.RootElement;
            ulong N(string key)=>r.TryGetProperty(key,out var v)&&v.TryGetUInt64(out var n)?n:0;
            int I(string key)=>r.TryGetProperty(key,out var v)&&v.TryGetInt32(out var n)?n:0;
            return new(N("abi")==0x10001,N("active")!=0,I("reason"),N("epoch"),I("profile"),N("packed"),N("presented"),N("felComposed"),N("felPresented"),N("complete")!=0,N("fatal")!=0,I("nativeResult"),N("uiSafe")!=0,N("osdBlocked")!=0,I("outputStage"),I("outputResult"),I("capsVersion"),(uint)N("outputFlags"),(uint)N("outputTechnology"),I("initialCapsResult"));
        }catch(JsonException){return default;}
    }
    internal static string Why(int reason)=>reason switch{
        0=>"正在核对输出",1=>"播放控制或弹窗显示中",2=>"当前为窗口播放",3=>"播放器未处于前台",4=>"输出链路未接受原生杜比",5=>"原生杜比组件或 NVAPI 不可用",6=>"桌面 HDR 模式开启中",7=>"当前输出时序未被接受",8=>"驱动未确认杜比信令",9=>"当前杜比配置不在支持范围",10=>"缺少本帧杜比元数据",11=>"本帧杜比元数据无效",12=>"缺少必需增强层",13=>"基础层与增强层时间戳不完整",14=>"当前像素布局不支持原生载体",15=>"增强层或画面上传失败",16=>"增强层重建器不可用",17=>"杜比画面重建失败",18=>"杜比元数据打包失败",19=>"杜比载体呈现失败",20=>"当前字幕色彩需要 HDR 渲染",21=>"字幕或提示合成失败",22=>"原生输出设备重建中",23=>"当前画面裁剪或旋转不支持原生载体",24=>"原生输出恢复失败",25=>"用户画面明暗调整已启用",26=>"当前连接未接受 TV-led 杜比传输",27=>"当前输出仅报告低延迟杜比，内置后端尚不支持",28=>"按 HDR（测试）设置转换输出",_=>"输出尚未确认"};
    internal static void Bind(object session)
    {
        Samples.Remove(session);Samples.Add(session,new());
        ClosingSessions.Remove(session);
        // HDR10 policy: keep completeness/failure sampling, without granting
        // native carrier permission or tracking UI for display mode changes.
    }
    internal static void Popup(object overlay,FlyoutBase popup)
    {
        if(Popups.TryGetValue(popup,out _))return;Popups.Add(popup,new());
        popup.Opening+=(_,_)=>{if(Uis.TryGetValue(overlay,out var s))s.Block();};
        popup.Closed+=(_,_)=>{if(Uis.TryGetValue(overlay,out var s))s.Sync();};
    }
    internal static void Sample(object session)
    {
        if(IsClosing(session)||!Samples.TryGetValue(session,out var s))return;
        var value=ReadCore(session);
        lock(s)s.Value=value;
        string signature=$"{value.Available}/{value.Active}/{value.Reason}/{value.Epoch}/{value.Fatal}/{value.FelPresented>0}/{value.OutputStage}/{value.OutputResult}/{value.CapsVersion}/{value.OutputFlags}/{value.OutputTechnology}";
        long now=Environment.TickCount64;
        if(signature!=s.Last||now-s.LastAt>=30000){s.Last=signature;s.LastAt=now;PlaybackFeatureLog.Native(session,value);MediaNotice.RearmOutput(session);}
        if(Access.Get<object?>(session,"_overlay") is FrameworkElement ui)
            ui.DispatcherQueue.TryEnqueue(()=>{if(Uis.TryGetValue(ui,out var state))state.Sync(value.Reason==1);});
    }
    internal static void ShowNativeNotice(object session,string text)
    {
        var client=Access.Get<MpvClient?>(session,"_mpvClient");if(client is null||client.IsDisposed)return;
        // A packed carrier cannot be overlaid with ordinary WinUI pixels.
        // mpv's own OSD is included BEFORE the native carrier packing.
        if(DolbyVision.ShowText(client,text)<0)PlaybackFeatureLog.Write(session,"native-notice","failed",null,"NativeOsdRejected");
    }
    internal static bool IsClosing(object session)
    {
        if(ClosingSessions.TryGetValue(session,out _))return true;
        if(session.GetType().GetProperty("_isClosing",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic)?.GetValue(session) is true)return true;
        var window=Access.Get<object?>(session,"_window");
        return window?.GetType().GetProperty("IsDisposed")?.GetValue(window) is true;
    }
    public static void BeginClose(object session)
    {
        if(Access.Get<MpvClient?>(session,"_mpvClient") is {} pictureClient)PictureAdjustment.Cancel(pictureClient);
        ClosingSessions.GetValue(session,_=>new());
        if(Access.Get<object?>(session,"_overlay") is FrameworkElement overlay&&Uis.TryGetValue(overlay,out var state))state.Stop();
    }
    public static void WindowClosing(object window)
    {
        foreach(var weak in Live.ToArray())if(weak.TryGetTarget(out var state)&&ReferenceEquals(state.Window,window))state.Stop();
    }
    sealed class UiState
    {
        readonly FrameworkElement overlay;readonly Grid root;
        readonly Dictionary<UIElement,(long Visibility,long Opacity)> hooked=new();
        internal WeakReference<object>? Session;internal bool? Last;internal object? Window;
        volatile bool closed;bool attached;long lastWrite,lastTrace;string lastBlock="";
        internal UiState(FrameworkElement overlay)
        {
            this.overlay=overlay;root=Access.Get<Grid>(overlay,"RootGrid");
            overlay.Unloaded+=Unloaded;overlay.Loaded+=Loaded;
        }
        internal void Bind(object session)
        {
            Session=new(session);Window=Access.Get<object?>(session,"_window");closed=false;Last=null;lastWrite=0;
            Attach();Sync();
        }
        void Attach(){if(attached||closed)return;attached=true;overlay.LayoutUpdated+=Layout;}
        void Detach()
        {
            overlay.LayoutUpdated-=Layout;attached=false;
            foreach(var pair in hooked)try{pair.Key.UnregisterPropertyChangedCallback(UIElement.VisibilityProperty,pair.Value.Visibility);pair.Key.UnregisterPropertyChangedCallback(UIElement.OpacityProperty,pair.Value.Opacity);}catch(System.Runtime.InteropServices.COMException error){PlaybackTransport.Write("Warning","Playback.NativeDolby.UI","退出解绑已失效界面；HRESULT=0x"+error.HResult.ToString("X8"));}
            hooked.Clear();
        }
        void Layout(object? sender,object e)=>Sync();
        void Loaded(object sender,RoutedEventArgs e){if(!closed){Attach();Sync();}}
        void Unloaded(object sender,RoutedEventArgs e)
        {
            // XamlSource.Dispose runs before client.IsDisposed becomes true.
            // Never call a synchronous mpv getter/setter from this callback.
            Detach();
        }
        internal void Stop()
        {
            if(closed)return;closed=true;
            if(overlay.DispatcherQueue.HasThreadAccess)Detach();else overlay.DispatcherQueue.TryEnqueue(Detach);
            if(Session?.TryGetTarget(out var session)!=true||session is null)return;
            ClosingSessions.GetValue(session,_=>new());
            var client=Access.Get<MpvClient?>(session,"_mpvClient");
            int result=client is {IsDisposed:false}?DolbyVision.SignalUi(client,false):0;
            PlaybackFeatureLog.Write(session,"native-close","ui-detached-async",result);
        }
        internal void Block()=>Set(false,false);
        static bool Painted(Brush? brush)
        {
            if(brush is null||brush.Opacity<=0)return false;
            return brush switch {SolidColorBrush solid=>solid.Color.A!=0,GradientBrush gradient=>gradient.GradientStops.Any(s=>s.Color.A!=0),_=>true};
        }
        bool Visible(UIElement e)=>Visible(e,0);
        bool Visible(UIElement e,int depth)
        {
            if(depth>64)return true;
            if(e.Visibility!=Visibility.Visible||e.Opacity<=0)return false;
            if(e is FrameworkElement f&&(f.ActualWidth<=0||f.ActualHeight<=0))return false;
            if(e.Clip is RectangleGeometry clip&&(clip.Rect.Width<=0||clip.Rect.Height<=0))return false;
            if(e is FrameworkElement element){
                // Layout slots may remain allocated after a template/transition
                // has moved all its paint outside the video viewport.
                var bounds=element.TransformToVisual(root).TransformBounds(new Windows.Foundation.Rect(0,0,element.ActualWidth,element.ActualHeight));
                if(bounds.Right<=0||bounds.Bottom<=0||bounds.Left>=root.ActualWidth||bounds.Top>=root.ActualHeight)return false;
            }
            bool Child(UIElement child)=>Visible(child,depth+1);
            bool TemplatePaint(){
                int count=VisualTreeHelper.GetChildrenCount(e);
                for(int i=0;i<count;i++)if(VisualTreeHelper.GetChild(e,i) is UIElement child&&Child(child))return true;
                return false;
            }
            return e switch {
                Panel p=>Painted(p.Background)||p.Children.Any(Child),
                Border b=>Painted(b.Background)||((b.BorderThickness.Left+b.BorderThickness.Top+b.BorderThickness.Right+b.BorderThickness.Bottom)>0&&Painted(b.BorderBrush))||(b.Child!=null&&Child(b.Child)),
                Microsoft.UI.Xaml.Shapes.Shape shape=>Painted(shape.Fill)||(shape.StrokeThickness>0&&Painted(shape.Stroke)),
                TextBlock text=>!string.IsNullOrWhiteSpace(text.Text)&&Painted(text.Foreground),
                Image image=>image.Source!=null,
                FontIcon icon=>!string.IsNullOrEmpty(icon.Glyph)&&Painted(icon.Foreground),
                ToolTip tip=>tip.IsOpen&&TemplatePaint(),
                Popup popup=>popup.IsOpen&&popup.Child is UIElement child&&Child(child),
                ContentPresenter presenter=>Painted(presenter.Background)||TemplatePaint(),
                Control control=>Painted(control.Background)||((control.BorderThickness.Left+control.BorderThickness.Top+control.BorderThickness.Right+control.BorderThickness.Bottom)>0&&Painted(control.BorderBrush))||TemplatePaint(),
                _=>true
            };
        }
        bool Layer(string name)=>Visible(Access.Get<UIElement>(overlay,name));
        internal void Sync(bool reconcile=false)
        {
            if(closed||!overlay.IsLoaded||Session?.TryGetTarget(out var session)!=true||session is null)return;
            if(IsClosing(session)){Stop();return;}
            foreach(var child in UiElements.Descendants(root).OfType<UIElement>())
                if(!hooked.ContainsKey(child)){
                    long v=child.RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>Sync());
                    long o=child.RegisterPropertyChangedCallback(UIElement.OpacityProperty,(_,_)=>Sync());
                    hooked.Add(child,(v,o));
                }
            bool popup=overlay.XamlRoot!=null&&VisualTreeHelper.GetOpenPopupsForXamlRoot(overlay.XamlRoot).Any(p=>p.IsOpen);
            bool chrome=Layer("ChromeLayer"),feedback=Layer("ActionFeedbackBorder"),status=Layer("PlaybackStatusPanel");
            bool dialog=Access.Get<bool>(overlay,"_desktopDialogOpen");
            bool paintedRoot=Painted(root.Background),paintedChildren=root.Children.Any(Visible);
            bool safe=overlay.XamlRoot!=null&&!popup&&!dialog&&!paintedRoot&&!paintedChildren;
            string Detail(UIElement node,int depth){
                // Only fixed control kinds/indices: never include UI text, Name,
                // Tag, media metadata, paths, URLs or account identifiers.
                string kind=node.GetType().Name;
                if(depth>=6)return kind;
                var children=node is Panel panel?panel.Children.Cast<UIElement>():node is Border{Child:UIElement child}?new[]{child}:Enumerable.Range(0,VisualTreeHelper.GetChildrenCount(node)).Select(i=>VisualTreeHelper.GetChild(node,i)).OfType<UIElement>();
                var visible=children.Select((child,index)=>(child,index)).Where(x=>Visible(x.child)).Take(4).Select(x=>$"{x.index}:{Detail(x.child,depth+1)}");
                string descendants=string.Join(",",visible);return descendants.Length==0?kind:kind+"["+descendants+"]";
            }
            string blockers=string.Join("|",root.Children.Select((child,index)=>(child,index)).Where(x=>Visible(x.child)).Take(6).Select(x=>$"{x.index}:{Detail(x.child,0)}"));
            if(blockers.Length>768)blockers=blockers[..768];
            string block=$"chrome={chrome}; feedback={feedback}; status={status}; dialog={dialog}; popup={popup}; rootPaint={paintedRoot}; childPaint={paintedChildren}; rootBrush={root.Background?.GetType().Name??"none"}; blockers={blockers}";
            long now=Environment.TickCount64;
            if(block!=lastBlock||now-lastTrace>=30000){lastBlock=block;lastTrace=now;PlaybackTransport.Write("Info","Playback.NativeDolby.UI",$"版本=0.5.8; safe={safe}; {block}。");}
            Set(safe,reconcile&&safe);
        }
        void Set(bool safe,bool reconcile)
        {
            if(closed||Session?.TryGetTarget(out var session)!=true||session is null||IsClosing(session))return;
            long now=Environment.TickCount64;
            if(Last==safe&&(!reconcile||now-lastWrite<1000))return;
            var client=Access.Get<MpvClient?>(session,"_mpvClient");if(client is null||client.IsDisposed)return;
            if(!safe&&Samples.TryGetValue(session,out var sample))lock(sample)sample.Value=sample.Value with{Active=false,Reason=1,UiSafe=false};
            // Never wait for core -> VO -> Win32/display messages on the UI
            // thread. This applies to completion overlays as well as closing.
            if(DolbyVision.SignalUi(client,safe)>=0){Last=safe;lastWrite=now;}
        }
    }
}
