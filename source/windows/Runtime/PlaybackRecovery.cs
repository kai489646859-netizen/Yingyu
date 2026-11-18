using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using Richasy.MpvKernel.Core;
using Richasy.MpvKernel.Core.Enums;
using Richasy.MpvKernel.Core.Models;

namespace Yingyu.Update;

public static class PlaybackRecovery
{
    sealed class State(int generation)
    {
        internal readonly int Generation = generation;
        internal double Position;
        internal bool AutomaticUsed;
    }
    static readonly ConditionalWeakTable<object,State> States = new();

    static bool Current(object session,State state) => !NativeDolby.IsClosing(session)
        && !Access.Get<bool>(session,"_switching") && Access.Get<int>(session,"_mediaGeneration")==state.Generation;

    internal static void Prepare(object session,MpvPlayOptions options)
    {
        if(Access.Get<bool>(session,"_manualRetryRunning")&&States.TryGetValue(session,out var state)&&Current(session,state))
            options.StartPosition=StartAt(options.StartPosition,Volatile.Read(ref state.Position));
    }
    internal static double? StartAt(double? original,double position)
        => double.IsFinite(position)&&position>0?position:original;

    internal static void Observe(object session,MpvClient client,MpvClientNotifyEventArgs e)
    {
        if(!States.TryGetValue(session,out var state)||state.Generation!=Access.Get<int>(session,"_mediaGeneration"))return;
        if(e.Id==MpvClientEventId.PositionChanged && e.Data is double position && double.IsFinite(position)
            && position>=0 && Access.Get<bool>(session,"_hasStartedPlayback")
            && !Access.Get<bool>(session,"_manualRetryRunning")
            && PlaybackTransport.Get(client,"seeking")=="no" && PlaybackTransport.Get(client,"paused-for-cache")!="yes"
            && (position>0 || Volatile.Read(ref state.Position)<=0))
            Volatile.Write(ref state.Position,position);
    }

    internal static void Bind(object session)
    {
        int generation=Access.Get<int>(session,"_mediaGeneration");
        if(States.TryGetValue(session,out var prior)&&prior.Generation==generation)return;
        States.Remove(session);States.Add(session,new State(generation));
    }

    public static void Offer(object session)
    {
        try
        {
            if(!States.TryGetValue(session,out var state)||!Current(session,state))return;
            Access.Set(session,"_startupTerminalFailure",true);
            var uri=Access.Get<Uri>(session,"_playbackUri");
            if(!state.AutomaticUsed&&!Access.Get<bool>(session,"_manualRetryRunning")
                &&uri.Scheme is ("http" or "https" or "yingyu-bd"))
            {
                state.AutomaticUsed=true;
                Access.Call(session,"OnRetryPlaybackRequested",session,EventArgs.Empty);
            }
        }
        catch(Exception error)
        { PlaybackTransport.Write("Warning","Playback.Recovery","无法自动重连："+error.GetType().Name); }
    }
    public static async Task RetryRoute(object session)
    {
        if(!States.TryGetValue(session,out var state)||!Current(session,state))return;
        var uri=Access.Get<Uri>(session,"_playbackUri");
        Access.Set(session,"_trackPreferencesAppliedItemId",null);
        if(!uri.IsFile&&(uri.Scheme is "bd" or "yingyu-bd"||NetworkBluray.IsFallbackSession(session)))
        {
            var resolution=(Task<MediaUriResolution>)Access.Call(session,"ResolvePlaybackUriSafelyAsync",false)!;
            await (Task)Access.Call(session,"PlayCurrentItemAsync",resolution,(int?)state.Generation)!;
        }
        else await (Task)Access.Call(session,"RefreshPlaybackRouteAsync")!;
    }
}
