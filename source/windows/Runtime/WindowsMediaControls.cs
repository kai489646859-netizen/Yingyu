using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Dispatching;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;
using Windows.Media;
using Windows.Media.Playback;

namespace Yingyu.Update;

internal static class WindowsMediaControls
{
    static readonly ConditionalWeakTable<object,State> Sessions=new();

    internal static void Bind(object session)
    {
        var dispatcher=Access.Get<DispatcherQueue>(session,"_dispatcher");
        void Attach()
        {
            if(NativeDolby.IsClosing(session))return;
            try
            {
                var state=Sessions.GetValue(session,s=>new State(s,dispatcher));
                state.Publish(MediaPlaybackStatus.Changing);
            }
            catch(Exception error)
            { PlaybackTransport.Write("Warning","Playback.SMTC","系统媒体面板不可用："+error.GetType().Name); }
        }
        if(dispatcher.HasThreadAccess)Attach();else dispatcher.TryEnqueue(Attach);
    }
    internal static void Observe(object session,MpvClientNotifyEventArgs e)
    {
        if(e.Id is not (MpvClientEventId.PlaybackRestart or MpvClientEventId.StateChanged)
            || !Sessions.TryGetValue(session,out var state))return;
        int generation=Access.Get<int>(session,"_mediaGeneration");
        var status=e.Data is MpvPlayerState playback ? playback switch
        {
            MpvPlayerState.Playing=>MediaPlaybackStatus.Playing,
            MpvPlayerState.Paused=>MediaPlaybackStatus.Paused,
            _=>MediaPlaybackStatus.Changing
        } : Access.Get<bool>(session,"_isPaused")?MediaPlaybackStatus.Paused:MediaPlaybackStatus.Playing;
        state.Dispatcher.TryEnqueue(()=>
        {
            if(generation==Access.Get<int>(session,"_mediaGeneration"))state.Publish(status);
        });
    }
    internal static void Close(object session)
    {
        if(!Sessions.TryGetValue(session,out var state))return;
        Sessions.Remove(session);
        if(state.Dispatcher.HasThreadAccess)state.Dispose();else state.Dispatcher.TryEnqueue(state.Dispose);
    }

    sealed class State : IDisposable
    {
        internal readonly DispatcherQueue Dispatcher;
        readonly WeakReference<object> session;
        readonly MediaPlayer bridge;
        readonly SystemMediaTransportControls controls;
        bool closed, busy;
        string? itemId;
        internal State(object owner,DispatcherQueue dispatcher)
        {
            session=new(owner);Dispatcher=dispatcher;
            bridge=new MediaPlayer();
            try
            {
                bridge.CommandManager.IsEnabled=false;
                controls=bridge.SystemMediaTransportControls;
                controls.IsEnabled=true;controls.IsPlayEnabled=true;controls.IsPauseEnabled=true;
                controls.ButtonPressed+=Pressed;
            }
            catch { bridge.Dispose();throw; }
        }
        internal void Publish(MediaPlaybackStatus status)
        {
            if(closed||!session.TryGetTarget(out var owner)||NativeDolby.IsClosing(owner))return;
            try
            {
                var item=Access.Get<EmbyItem>(owner,"_item");
                var playlist=Access.Get<IReadOnlyList<EmbyItem>?>(owner,"_playlist")??[];
                var adjacent=EpisodeNavigationPolicy.FindAdjacent(playlist,item.Id);
                controls.IsPreviousEnabled=adjacent.Previous!=null;
                controls.IsNextEnabled=adjacent.Next!=null;
                controls.PlaybackStatus=status;
                if(itemId==item.Id)return;
                var info=controls.DisplayUpdater;
                info.Type=MediaPlaybackType.Video;
                info.VideoProperties.Title=item.Name;
                info.VideoProperties.Subtitle=item.SeriesName??"映屿";
                info.Update();
                itemId=item.Id;
            }
            catch(Exception error)
            { PlaybackTransport.Write("Warning","Playback.SMTC","系统媒体状态未更新："+error.GetType().Name); }
        }
        void Pressed(SystemMediaTransportControls sender,SystemMediaTransportControlsButtonPressedEventArgs args)
        {
            var button=args.Button;
            Dispatcher.TryEnqueue(async()=>
            {
                if(closed||busy||!session.TryGetTarget(out var owner)||NativeDolby.IsClosing(owner)
                    ||Access.Get<bool>(owner,"_switching"))return;
                busy=true;
                try
                {
                    bool paused=Access.Get<bool>(owner,"_isPaused");
                    if(button==SystemMediaTransportControlsButton.Play&&paused
                        ||button==SystemMediaTransportControlsButton.Pause&&!paused)
                        await (Task)Access.Call(owner,"TogglePlayAsync")!;
                    else if(button is SystemMediaTransportControlsButton.Next or SystemMediaTransportControlsButton.Previous)
                    {
                        var item=Access.Get<EmbyItem>(owner,"_item");
                        var adjacent=EpisodeNavigationPolicy.FindAdjacent(Access.Get<IReadOnlyList<EmbyItem>?>(owner,"_playlist")??[],item.Id);
                        var target=button==SystemMediaTransportControlsButton.Next?adjacent.Next:adjacent.Previous;
                        if(target!=null)Access.Call(owner,"OnEpisodeRequested",owner,target.Id);
                    }
                }
                catch(Exception error)
                { PlaybackTransport.Write("Warning","Playback.SMTC","系统媒体控制未完成："+error.GetType().Name); }
                finally { busy=false; }
            });
        }
        public void Dispose()
        {
            closed=true;
            try
            {
                controls.ButtonPressed-=Pressed;
                controls.PlaybackStatus=MediaPlaybackStatus.Closed;
                controls.IsEnabled=false;
            }
            catch(System.Runtime.InteropServices.COMException) {}
            finally { bridge.Dispose(); }
        }
    }
}
