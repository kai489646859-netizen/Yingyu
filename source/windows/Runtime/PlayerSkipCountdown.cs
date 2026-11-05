using System.Reflection;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

// The session's original skip resolver and EOF/progress/episode switch paths
// remain authoritative. This owns only a cancellable presentation/delay.
public static class PlayerSkipCountdown
{
    static readonly ConditionalWeakTable<object,State> States=new();
    static readonly ConditionalWeakTable<object,State> Overlays=new();
    const BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
    public static void Bind(object session)
    {
        if(Access.Get<object?>(session,"_overlay") is not FrameworkElement overlay)return;
        var state=States.GetValue(session,s=>new State(s,overlay));
        state.EnsureMedia();
        Overlays.Remove(overlay);Overlays.Add(overlay,state);
    }
    public static void Observe(object session)
    {
        if(!States.TryGetValue(session,out var state)){Bind(session);if(!States.TryGetValue(session,out state))return;}
        state.Observe();
    }
    public static void Interrupt(object session)
    {
        if(States.TryGetValue(session,out var state)){state.StopSkip();state.ReadyForNext=false;state.ExpectedItem=null;state.StartAt=0;}
    }
    public static void Ready(object session)
    {
        if(!States.TryGetValue(session,out var state))return;
        state.DispatchReady();
    }
    public static void SeekApplied(object session)
    {
        try{PlayerDanmaku.Sought(session);if(States.TryGetValue(session,out var state))state.Applied();}
        catch(Exception e){PlaybackTransport.Write("Warning","Playback.Skip","定位显示同步未完成；"+e.GetType().Name);}
    }
    public static void BeforeSeek(object session){if(!States.TryGetValue(session,out var state)||!state.AutoSeeking)Interrupt(session);}
    public static void RememberNext(object session,string? item)
    {
        if(!States.TryGetValue(session,out var state))return;
        state.ExpectedItem=item??Access.Get<string?>(Access.Get<object>(session,"_nextEpisodeCountdown"),"_itemId");
        state.ExpectedUntil=Environment.TickCount64+60000;
    }
    internal static void PrepareStart(object session,MpvPlayOptions options)
    {
        if(!States.TryGetValue(session,out var state))return;
        var item=Access.Get<EmbyItem>(session,"_item");
        state.EnsureMedia();
        if(state.StartAt>0){options.StartPosition=Math.Max(options.StartPosition??0,state.StartAt);return;}
        if(state.ExpectedItem!=item.Id||Environment.TickCount64>state.ExpectedUntil)return;
        state.ExpectedItem=null;
        if(!item.Type.Equals("Episode",StringComparison.OrdinalIgnoreCase))return;
        var source=Access.Get<MediaSourceInfo>(session,"_source");
        var desktop=Access.Get<DesktopLibraryState>(session,"_desktopOptions");
        var scope=(string)session.GetType().GetProperty("SkipScope",Flags)!.GetValue(session)!;
        var manual=desktop.Skips.GetValueOrDefault(scope)??new SkipPreference();
        double duration=(item.RunTimeTicks??0)/10000000d;
        var intro=PlaybackSkipPolicy.Resolve((source.Chapters??[]).Concat(item.Chapters??[]),manual,duration).IntroEnd;
        if(intro is >0&&double.IsFinite(intro.Value)&&intro.Value<duration)
        {state.StartAt=intro.Value;options.StartPosition=Math.Max(options.StartPosition??0,intro.Value);}
    }
    public static bool AllowsNext(object session)=>!States.TryGetValue(session,out var state)||!state.CancelledCredits;
    public static bool StartNext(object session,string item)
    {
        if(!States.TryGetValue(session,out var state))return false;
        state.EnsureMedia();
        if(state.CancelledCredits)return true;
        if(!state.ReadyForNext||Environment.TickCount64>state.ReadyUntil){state.ReadyForNext=false;return false;}
        state.ReadyForNext=false;
        Access.Call(session,"PlayPendingNextEpisode",item);
        return true;
    }
    public static void ShowNext(object overlay,int seconds)
    {
        if(Overlays.TryGetValue(overlay,out var state))state.ShowNatural(seconds);
    }
    public static void HideNext(object overlay)
    {
        if(Overlays.TryGetValue(overlay,out var state))state.HideNatural();
        Access.Get<Button>(overlay,"PlayNextNowButton").Visibility=Visibility.Collapsed;
        Access.Get<Button>(overlay,"CancelNextButton").Visibility=Visibility.Collapsed;
    }
    sealed class State
    {
        readonly object session;readonly FrameworkElement overlay;
        readonly Grid layer=new(){HorizontalAlignment=HorizontalAlignment.Stretch,VerticalAlignment=VerticalAlignment.Stretch};
        readonly TextBlock label=new(){TextWrapping=TextWrapping.Wrap,FontSize=14,Foreground=DesktopVisuals.Brush(0xFFFFFFFF),MaxWidth=248};
        readonly Border panel,replay;readonly Button restart;readonly TextBlock replayText;
        readonly DispatcherQueueTimer replayTimer;bool replayOffered,restarting;int restartRevision;
        readonly DispatcherQueueTimer timer;
        int generation=int.MinValue,remaining;
        string? phase;
        double target;
        bool cancelledIntro,natural,issued;
        internal bool CancelledCredits,ReadyForNext,AutoSeeking;
        internal string? ExpectedItem;internal long ExpectedUntil,ReadyUntil;internal double StartAt;
        internal State(object session,FrameworkElement overlay)
        {
            this.session=session;this.overlay=overlay;
            var body=new StackPanel{Spacing=10};body.Children.Add(label);
            var actions=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,HorizontalAlignment=HorizontalAlignment.Right};
            var now=new Button{Content="立刻跳转",Padding=new(12,5,12,5),FontSize=12};
            var cancel=new Button{Content="取消",Padding=new(12,5,12,5),FontSize=12};
            now.Click+=(_,_)=>JumpNow();cancel.Click+=(_,_)=>Cancel();actions.Children.Add(now);actions.Children.Add(cancel);body.Children.Add(actions);
            panel=new Border{Name="PlayerAutoSkipPanel",HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Bottom,Margin=new(20,20,24,24),Padding=new(16),CornerRadius=new(8),Background=DesktopVisuals.Brush(0xEE202125),BorderBrush=DesktopVisuals.Brush(0x444E5058),BorderThickness=new(1),Child=body,Visibility=Visibility.Collapsed};
            layer.Children.Add(panel);
            var resumeBody=new Grid{ColumnSpacing=10};resumeBody.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});resumeBody.ColumnDefinitions.Add(new(){Width=GridLength.Auto});resumeBody.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            replayText=new TextBlock{FontSize=12,Foreground=DesktopVisuals.Brush(0xFFE6E7EA),VerticalAlignment=VerticalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis};resumeBody.Children.Add(replayText);
            restart=new Button{Content="重头播放",FontSize=12,Padding=new(4),MinWidth=0,MinHeight=28,Background=DesktopVisuals.Brush(0),BorderThickness=new(0),Foreground=DesktopVisuals.Brush(0xFF46C3F1)};Grid.SetColumn(restart,1);resumeBody.Children.Add(restart);restart.Click+=async(_,_)=>await Restart();
            var dismiss=new Button{Content="×",FontSize=16,Padding=new(4),MinWidth=24,MinHeight=28,Background=DesktopVisuals.Brush(0),BorderThickness=new(0),Foreground=DesktopVisuals.Brush(0xFFB6B8BE)};Grid.SetColumn(dismiss,2);resumeBody.Children.Add(dismiss);dismiss.Click+=(_,_)=>HideReplay();
            replay=new Border{Name="PlayerReplayNotice",HorizontalAlignment=HorizontalAlignment.Left,VerticalAlignment=VerticalAlignment.Bottom,Padding=new(12,6,8,6),CornerRadius=new(6),Background=DesktopVisuals.Brush(0xEE202125),BorderBrush=DesktopVisuals.Brush(0x444E5058),BorderThickness=new(1),Child=resumeBody,Visibility=Visibility.Collapsed};layer.Children.Add(replay);
            replayTimer=overlay.DispatcherQueue.CreateTimer();replayTimer.IsRepeating=false;replayTimer.Interval=TimeSpan.FromSeconds(8);replayTimer.Tick+=(_,_)=>HideReplay();
            overlay.SizeChanged+=(_,_)=>PlaceReplay();
            timer=overlay.DispatcherQueue.CreateTimer();timer.Interval=TimeSpan.FromSeconds(1);timer.IsRepeating=true;timer.Tick+=Tick;
            overlay.Loaded+=(_,_)=>Attach();
            overlay.Unloaded+=(_,_)=>{StopSkip();HideReplay();restartRevision++;restarting=false;ExpectedItem=null;ReadyForNext=false;natural=false;panel.Visibility=Visibility.Collapsed;};
            overlay.GetType().GetEvent("ControlsVisibilityChanged")!.AddEventHandler(overlay,new EventHandler<bool>((_,visible)=>{panel.Margin=new(20,20,24,visible?116:24);PlaceReplay();}));
            if(overlay.IsLoaded)Attach();
        }
        bool Closing=>(bool)session.GetType().GetProperty("_isClosing",Flags)!.GetValue(session)!;
        bool Current=>overlay.IsLoaded&&!Closing&&!Access.Get<bool>(session,"_switching")&&!Access.Get<bool>(session,"_manualSwitchPending")
            &&generation==Access.Get<int>(session,"_mediaGeneration")&&ReferenceEquals(overlay,Access.Get<object?>(session,"_overlay"));
        void Attach()
        {
            var root=Access.Get<Grid>(overlay,"RootGrid");
            Grid.SetRowSpan(layer,Math.Max(1,root.RowDefinitions.Count));Grid.SetColumnSpan(layer,Math.Max(1,root.ColumnDefinitions.Count));
            if(!root.Children.Contains(layer)){Canvas.SetZIndex(layer,80);root.Children.Add(layer);}
            panel.Margin=new(20,20,24,Access.Get<bool>(overlay,"_controlsVisible")?116:24);PlaceReplay();
        }
        internal void ResetMedia(){StopSkip();HideReplay();replayOffered=false;restarting=false;restart.IsEnabled=true;restartRevision++;generation=Access.Get<int>(session,"_mediaGeneration");StartAt=0;AutoSeeking=false;cancelledIntro=CancelledCredits=ReadyForNext=issued=natural=false;panel.Visibility=Visibility.Collapsed;}
        internal void EnsureMedia(){if(generation!=Access.Get<int>(session,"_mediaGeneration"))ResetMedia();}
        void PlaceReplay()
        {
            if(!overlay.IsLoaded)return;
            replay.MaxWidth=Math.Max(120,Math.Min(360,overlay.ActualWidth-40));
            replay.Margin=new(20,20,20,Access.Get<bool>(overlay,"_controlsVisible")?116:24);
        }
        internal void DispatchReady()
        {
            int expected=Access.Get<int>(session,"_mediaGeneration");
            overlay.DispatcherQueue.TryEnqueue(()=>{
                try{
                    if(expected!=Access.Get<int>(session,"_mediaGeneration"))return;EnsureMedia();
                    if(replayOffered||!Current||!Access.Get<bool>(session,"_hasStartedPlayback"))return;
                    replayOffered=true;double position=Access.Get<double>(session,"_position");
                    if(!double.IsFinite(position)||position<3)return;
                    replayText.Text="当前播放至 "+PlayerInfoData.Clock(position);PlaceReplay();replay.Visibility=Visibility.Visible;replayTimer.Start();
                }catch(Exception e){PlaybackTransport.Write("Warning","Playback.Skip","续播提示未显示；"+e.GetType().Name);}
            });
        }
        void HideReplay(){replayTimer.Stop();replay.Visibility=Visibility.Collapsed;}
        internal void Applied()
        {
            if(!Current)return;HideReplay();
            if(!restarting||Math.Abs(Access.Get<double>(session,"_position"))>.05)return;
            restarting=false;cancelledIntro=CancelledCredits=issued=natural=false;StopSkip();
            // Re-evaluate the original chapter/manual policy at the committed 0.
            // The normal three-second countdown remains cancellable and pauses
            // during pause or buffering; this never uses next-episode StartAt.
            Access.Call(session,"DesktopPlayerTick",(object?)null,(object?)null);
        }
        async Task Restart()
        {
            if(!Current||restarting)return;HideReplay();restart.IsEnabled=false;
            int expected=generation,revision=++restartRevision;restarting=true;StopSkip();natural=false;
            cancelledIntro=CancelledCredits=issued=ReadyForNext=false;ExpectedItem=null;StartAt=0;
            try{
                await (Task)Access.Call(session,"RunSafelyAsync",(Func<Task>)(async()=>{
                    if(!Current||expected!=generation||revision!=restartRevision)return;
                    await (Task)Access.Call(session,"SeekAsync",0d)!;
                    if(Current&&expected==generation&&revision==restartRevision&&Access.Get<bool>(session,"_isPaused"))await (Task)Access.Call(session,"TogglePlayAsync")!;
                }))!;
            }catch(Exception e){PlaybackTransport.Write("Warning","Playback.Skip","重头播放未完成；"+e.GetType().Name);}
            finally{if(expected==generation&&revision==restartRevision){restarting=false;restart.IsEnabled=true;}}
        }
        string? Region()
        {
            var text=Access.Get<Button>(overlay,"SkipButton").Content?.ToString();
            if(!Access.Get<double?>(session,"_skipTarget").HasValue)return null;
            return text=="跳过片头"?"intro":text=="跳过片尾"?"credits":null;
        }
        internal void Observe()
        {
            EnsureMedia();
            string? region=Region();
            Access.Get<Button>(overlay,"SkipButton").Visibility=Visibility.Collapsed;
            if(!Current){StopSkip();return;}
            if(natural||restarting)return;
            if(region==null){StopSkip();issued=false;return;}
            if(region=="intro"&&cancelledIntro||region=="credits"&&CancelledCredits){StopSkip();return;}
            double next=Access.Get<double?>(session,"_skipTarget")!.Value;
            if(phase==region&&Math.Abs(target-next)<.05)return;
            if(issued)return;
            StopSkip();phase=region;target=next;remaining=3;
            panel.Visibility=Visibility.Visible;Paint();timer.Start();
        }
        void Paint()
        {
            var item=Access.Get<EmbyItem>(session,"_item");
            bool auto=(bool)Access.Get<object>(session,"_experience").GetType().GetProperty("AutoNext")!.GetValue(Access.Get<object>(session,"_experience"))!;
            label.Text=phase=="intro"?$"{remaining} 秒后跳过片头":auto&&item.Type.Equals("Episode",StringComparison.OrdinalIgnoreCase)&&!Access.Get<bool>(session,"_sleepAfterEpisode")?$"{remaining} 秒后跳过片尾并自动续播":$"{remaining} 秒后跳过片尾";
        }
        void Tick(DispatcherQueueTimer sender,object args)
        {
            try
            {
                if(!Current||natural){StopSkip();return;}
                if(Region()!=phase||Access.Get<double?>(session,"_skipTarget") is not {} value||Math.Abs(value-target)>.05){StopSkip();return;}
                // Pause/buffering never consumes countdown time or launches a seek.
                if(Access.Get<bool>(session,"_isPaused")){Paint();return;}
                var client=Access.Get<Richasy.MpvKernel.Core.MpvClient?>(session,"_mpvClient");
                if(client==null||PlaybackTransport.Get(client,"paused-for-cache")=="yes")return;
                if(--remaining>0){Paint();return;}
                ExecuteSkip();
            }
            catch(Exception){StopSkip();ReadyForNext=false;PlaybackTransport.Write("Warning","Playback.Skip","自动跳过未完成，已保留本集播放。 ");}
        }
        void JumpNow()
        {
            try
            {
                if(!Current)return;
                if(natural)Access.Call(session,"PlayPendingNextEpisode",(object?)null);
                else if(phase!=null&&Region()==phase)ExecuteSkip();
            }
            catch(Exception){StopSkip();ReadyForNext=false;PlaybackTransport.Write("Warning","Playback.Skip","跳转未完成，请重试。 ");}
        }
        void ExecuteSkip()
        {
            bool credits=phase=="credits";double destination=target;
            issued=true;StopSkip();ReadyForNext=credits;ReadyUntil=Environment.TickCount64+15000;
            _=Seek(destination);
        }
        async Task Seek(double destination)
        {
            int requestedGeneration=generation;
            try
            {
                if(!Current)return;
                AutoSeeking=true;
                await (Task)Access.Call(session,"RunSafelyAsync",(Func<Task>)(async()=>
                {
                    if(requestedGeneration!=Access.Get<int>(session,"_mediaGeneration")||!Current)return;
                    try{await (Task)Access.Call(session,"SeekAsync",destination)!;}
                    catch{if(generation==requestedGeneration)ReadyForNext=false;throw;}
                }))!;
            }
            catch(Exception){if(generation==requestedGeneration)ReadyForNext=false;PlaybackTransport.Write("Warning","Playback.Skip","自动定位失败，保留本集。 ");}
            finally{if(generation==requestedGeneration)AutoSeeking=false;}
        }
        internal void StopSkip(){timer.Stop();phase=null;if(!natural)panel.Visibility=Visibility.Collapsed;}
        internal void ShowNatural(int seconds)
        {
            EnsureMedia();StopSkip();natural=true;
            Access.Call(overlay,"UpdatePlayingState",false);
            // Separate from the centered loading/error panel and playback chrome.
            Access.Get<Border>(overlay,"PlaybackStatusPanel").Visibility=Visibility.Collapsed;
            Access.Get<Button>(overlay,"PlayNextNowButton").Visibility=Visibility.Collapsed;
            Access.Get<Button>(overlay,"CancelNextButton").Visibility=Visibility.Collapsed;
            label.Text=$"本集已结束 · {seconds} 秒后播放下一集";
            panel.Visibility=Visibility.Visible;
        }
        internal void HideNatural(){natural=false;panel.Visibility=Visibility.Collapsed;}
        void Cancel()
        {
            if(natural||phase=="credits")CancelledCredits=true;
            else if(phase=="intro")cancelledIntro=true;
            ReadyForNext=false;StopSkip();natural=false;panel.Visibility=Visibility.Collapsed;
            Access.Call(session,"CancelNextEpisode");
        }
    }
}
