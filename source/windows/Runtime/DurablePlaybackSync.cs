using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

// Account ownership is captured while the shell is current, never inferred from
// whichever account happens to be visible when an asynchronous stop completes.
public static class DurablePlaybackSync
{
    sealed record Owner(EmbySession Session,PendingPlaybackSyncStore Store);
    sealed record Latest(string Session,long Position,bool Confirmed,long Serial,PlaybackRequest Request,Saved? Record=null);
    internal sealed record Saved(PendingPlaybackSyncStore Store,PendingPlaybackSyncEntry Entry);
    static readonly ConditionalWeakTable<EmbyApiClient,Owner> Owners=new();
    static readonly ConcurrentDictionary<string,Latest> LatestStops=new();
    static long nextStop;
    static string Key(EmbyApiClient client,PlaybackRequest request)=>System.Text.Json.JsonSerializer.Serialize(new[]{client.ServerUrl,Access.Get<string?>(client,"_userId"),request.ItemId});
    public static void Bind(object page)
    {
        var client=Access.Get<EmbyApiClient?>(page,"_client");var account=Access.Get<EmbySession?>(page,"_session");
        if(client==null||account==null)return;
        Owners.Remove(client);Owners.Add(client,new(account,Access.Get<PendingPlaybackSyncStore>(page,"_pendingPlaybackSyncStore")));
    }
    public static Task? UnstartedStop(object session)
    {
        if(Access.Get<bool>(session,"_hasStartedPlayback"))return null;
        // No first frame and no started report means no new watching position.
        // Do not replace an existing resume point with an initialization zero.
        Access.Set(session,"_stoppedReported",true);
        return Task.CompletedTask;
    }
    internal static bool ShouldSave(EmbyApiClient client,PlaybackRequest request)
        =>!LatestStops.TryGetValue(Key(client,request),out var latest)
            ||latest.Session==request.PlaySessionId&&latest.Position==request.PositionTicks&&!latest.Confirmed;
    public static Task SaveLocalAndPending(object session,double position,double duration,PlaybackStopReason? reason,PlaybackRequest request)
    {
        var client=Access.Get<EmbyApiClient>(session,"_embyClient");
        // Invoke the original method synchronously first: it captures this media
        // item before TrySwitchAsync can replace session._item at its next await.
        var local=(Task)Access.Call(session,"SaveLocalPlaybackAsync",position,duration,reason)!;
        return Task.WhenAll(local,SavePending());
        async Task SavePending()
        {
            try{await Save(client,request,reason==PlaybackStopReason.NaturalEnd);}
            catch(Exception error){PlaybackTransport.Write("Warning","Playback.Sync","停止进度预先落盘失败，原本机记录与上报仍继续；"+error.GetType().Name);}
        }
    }
    internal static async Task<Saved?> Save(EmbyApiClient client,PlaybackRequest request,bool completed)
    {
        if(!Owners.TryGetValue(client,out var owner)||Access.Get<string?>(client,"_userId")!=owner.Session.UserId)
        {
            PlaybackTransport.Write("Warning","Playback.Sync","停止上报缺少匹配的账户保存上下文，沿用原本机观看记录与活动回执。 ");
            return null;
        }
        var key=Key(client,request);
        if(LatestStops.TryGetValue(key,out var prior)&&ReferenceEquals(prior.Request,request)&&prior.Record!=null)return prior.Record;
        if(LatestStops.Count>4096)LatestStops.Clear();
        var current=new Latest(request.PlaySessionId,request.PositionTicks,false,Interlocked.Increment(ref nextStop),request);
        LatestStops[key]=current;
        var entry=await ResumeDeviceSync.Persist(owner.Store,owner.Session,client,request,completed);
        var saved=new Saved(owner.Store,entry);
        LatestStops.TryUpdate(key,current with{Record=saved},current);
        PlaybackTransport.Write("Info","Playback.Sync","停止进度已在网络请求前写入持久待同步队列。 ");
        return saved;
    }
    internal static async Task Confirm(EmbyApiClient client,PlaybackRequest request,Saved? saved)
    {
        if(saved!=null)await ResumeDeviceSync.Remove(saved.Store,saved.Entry,CancellationToken.None);
        var key=Key(client,request);
        if(LatestStops.TryGetValue(key,out var current)&&ReferenceEquals(current.Request,request))
            LatestStops.TryUpdate(key,current with{Confirmed=true},current);
    }
    // Item-only deletion used to let a delayed successful stop erase a newer
    // pending session. The verified stop now removes its exact durable entry.
    public static Task Refresh(object page,string itemId)
        =>(Task)Access.Call(page,"RefreshPendingPlaybackSyncStatusAsync",CancellationToken.None)!;
}
