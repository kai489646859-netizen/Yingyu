using System.Globalization;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

// Geometry only. Never changes sid, visibility, timing, glyph scale, video
// aspect, media, renderer or HDR. Controls appearing never move subtitles.
internal static class SubtitlePlacement
{
    static readonly ConditionalWeakTable<object,State> Sessions=new();
    static readonly ConditionalWeakTable<object,State> Overlays=new();
    internal static void Bind(object session)
    {
        if(Access.Get<object?>(session,"_overlay") is not FrameworkElement overlay)return;
        if(Overlays.TryGetValue(overlay,out var old))old.Detach();
        var state=new State(session,overlay);Sessions.Remove(session);Sessions.Add(session,state);Overlays.Remove(overlay);Overlays.Add(overlay,state);
    }
    internal static void Notify(object session,MpvClientNotifyEventArgs e)
    {if(e.Id is MpvClientEventId.PlaybackRestart or MpvClientEventId.TrackCountChanged or MpvClientEventId.PositionChanged&&Sessions.TryGetValue(session,out var state))state.Queue();}
    internal static void Tools(object overlay,UIElement content)
    {
        if(!Overlays.TryGetValue(overlay,out var state))return;
        if(content is ScrollViewer{Content:UIElement child})content=child;
        if(content is not StackPanel panel)return;
        // Replace the old unverified numeric position entry; its size/delay
        // siblings and handlers stay. There must be one position editor.
        foreach(var number in panel.Children.OfType<NumberBox>().Concat(panel.Children.OfType<Expander>().Select(e=>e.Content).OfType<StackPanel>().SelectMany(group=>group.Children.OfType<NumberBox>())))if(number.Header?.ToString()?.StartsWith("字幕位置",StringComparison.Ordinal)==true)number.Visibility=Visibility.Collapsed;
        var status=new TextBlock{TextWrapping=TextWrapping.Wrap,FontSize=13};
        var slider=new Slider{Minimum=0,Maximum=state.Bitmap?150:100,StepFrequency=1,SmallChange=1,LargeChange=5,Header="字幕垂直位置"};
        var body=new StackPanel{Spacing=12};body.Children.Add(status);body.Children.Add(slider);
        var reset=new Button{Content="恢复默认位置",HorizontalAlignment=HorizontalAlignment.Stretch};body.Children.Add(reset);
        bool painting=false;void Paint(){painting=true;try{state.Apply();slider.Maximum=state.Bitmap?150:100;slider.IsEnabled=state.Ready;slider.Value=state.Position;status.Text=state.Ready?$"当前位置：{state.Position:0}%":"等待字幕轨道就绪";}finally{painting=false;}}
        slider.ValueChanged+=(_,e)=>{if(painting)return;try{state.Set(e.NewValue);status.Text=$"当前位置：{state.Position:0}%";}catch(Exception){status.Text="位置未能应用，已保留原设置。";Paint();}};
        reset.Click+=(_,_)=>{state.Reset();Paint();};
        var section=new Expander{Header="字幕位置",Content=body,HorizontalAlignment=HorizontalAlignment.Stretch};section.Expanding+=(_,_)=>Paint();panel.Children.Insert(0,section);
        var p=DesktopThemePalette.Resolve(DesktopTheme.Options,true);slider.Foreground=DesktopVisuals.Brush(DesktopReadability.Progress(p));
        Paint();
    }
    sealed class State
    {
        readonly object session;readonly FrameworkElement overlay;readonly MpvClient? client;readonly int generation;
        readonly Dictionary<string,(string Before,string Written)> owned=new();
        bool queued,detached;long last;double lastLive;string track="";internal double? Manual;internal bool Bitmap,Ready;internal double Position=100;
        internal State(object session,FrameworkElement overlay){this.session=session;this.overlay=overlay;client=Access.Get<MpvClient?>(session,"_mpvClient");generation=Access.Get<int>(session,"_mediaGeneration");lastLive=Access.Get<double>(session,"_liveSubtitlePosition");overlay.SizeChanged+=Resize;overlay.Unloaded+=Unload;}
        bool Current=>!detached&&!NativeDolby.IsClosing(session)&&client is {IsDisposed:false}&&ReferenceEquals(client,Access.Get<MpvClient?>(session,"_mpvClient"))&&generation==Access.Get<int>(session,"_mediaGeneration");
        void Resize(object sender,SizeChangedEventArgs args)=>Queue(true);
        void Unload(object sender,RoutedEventArgs args)=>Detach();
        internal void Detach(){if(Current)Restore();detached=true;overlay.SizeChanged-=Resize;overlay.Unloaded-=Unload;}
        internal void Queue(bool force=false)
        {
            if(!Current||queued||!force&&Environment.TickCount64-last<1000)return;queued=true;
            if(!overlay.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>{queued=false;if(!Current)return;try{Apply();}catch(Exception e){PlaybackTransport.Write("Warning","Playback.Subtitles","字幕位置适配未完成，保留原排版；"+e.GetType().Name);}}))queued=false;
        }
        string Read(string key)=>Current?PlaybackTransport.Get(client!,key):"";
        static bool Equal(string a,string b)=>a==b||double.TryParse(a,NumberStyles.Float,CultureInfo.InvariantCulture,out var x)&&double.TryParse(b,NumberStyles.Float,CultureInfo.InvariantCulture,out var y)&&double.IsFinite(x)&&double.IsFinite(y)&&Math.Abs(x-y)<.0001;
        void Write(string key,string value)
        {
            if(!Current)return;string before=Read(key);if(Equal(before,value))return;
            if(string.IsNullOrWhiteSpace(before)||before=="unknown"||before=="unavailable")return;
            var prior=owned.GetValueOrDefault(key);if(prior.Written!=null&&!Equal(before,prior.Written)){owned.Remove(key);return;}
            if(PlaybackTransport.Set(client!,key,value)<0||!Equal(Read(key),value))
            {PlaybackTransport.Set(client!,key,before);throw new InvalidOperationException("Subtitle placement not acknowledged");}
            owned[key]=(prior.Written==null?before:prior.Before,Read(key));
            PlaybackFeatureLog.Write(session,"subtitle-placement","readback-confirmed",double.TryParse(value,NumberStyles.Float,CultureInfo.InvariantCulture,out var number)?number:null);
        }
        void Restore()
        {
            if(client is not {IsDisposed:false})return;
            foreach(var pair in owned.ToArray())try{if(Equal(PlaybackTransport.Get(client,pair.Key),pair.Value.Written)&&PlaybackTransport.Set(client,pair.Key,pair.Value.Before)<0)PlaybackTransport.Write("Warning","Playback.Subtitles","字幕排版恢复未被接受，保留当前会话状态。");}catch(Exception e){PlaybackTransport.Write("Warning","Playback.Subtitles","字幕排版恢复未完成；"+e.GetType().Name);}
            owned.Clear();
        }
        internal void Apply()
        {
            if(!Current)return;last=Environment.TickCount64;
            string sid=Read("sid"),codec=Read("current-tracks/sub/codec").ToLowerInvariant();Ready=int.TryParse(sid,out var id)&&id>0&&codec.Length>0;
            if(!Ready){if(track.Length>0){Restore();track="";}return;}
            string next=sid+":"+codec;if(track!=next){Restore();track=next;}
            Bitmap=codec is "hdmv_pgs_subtitle" or "pgs" or "dvd_subtitle" or "dvb_subtitle";
            double requested=Access.Get<ExperiencePreferences>(session,"_experience").SubtitlePosition;
            double live=Access.Get<double>(session,"_liveSubtitlePosition");
            if(double.IsFinite(live)&&Math.Abs(live-lastLive)>.001){Manual=Math.Clamp(live,0,Bitmap?150:100);lastLive=live;owned.Remove("sub-pos");}
            if(Manual is {} manual){double target=Math.Clamp(manual,0,Bitmap?150:100);Write("sub-pos",target.ToString("0.###",CultureInfo.InvariantCulture));Position=target;return;}
            // Respect a deliberate legacy centered/higher user preference.
            if(Math.Abs(requested-100)>.01){Restore();Position=requested;return;}
            if(Bitmap)
            {
                // Native PGS/DVD moves bottom-region dialogue only and clamps
                // within its canvas. No stretching or synthetic OCR/text layer.
                Write("sub-pos","108");Position=double.TryParse(Read("sub-pos"),NumberStyles.Float,CultureInfo.InvariantCulture,out var actual)?actual:100;
            }
            else
            {
                if(codec is not ("ass" or "ssa")){Write("sub-use-margins","yes");Write("sub-margin-y",Math.Round(Math.Clamp(overlay.ActualHeight*.018,12,28)).ToString("0",CultureInfo.InvariantCulture));}
                Position=double.TryParse(Read("sub-pos"),NumberStyles.Float,CultureInfo.InvariantCulture,out var actual)?actual:100;
            }
        }
        internal void Set(double value){if(!Current||!Ready||!double.IsFinite(value))return;double next=Math.Clamp(value,0,Bitmap?150:100);Write("sub-pos",next.ToString("0.###",CultureInfo.InvariantCulture));Manual=next;Position=next;Access.Set(session,"_liveSubtitlePosition",next);lastLive=next;}
        internal void Reset(){if(!Current)return;Manual=null;lastLive=Access.Get<ExperiencePreferences>(session,"_experience").SubtitlePosition;Access.Set(session,"_liveSubtitlePosition",lastLive);Restore();}
    }
}
