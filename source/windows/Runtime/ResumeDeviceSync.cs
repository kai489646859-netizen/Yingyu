using System.Collections.Concurrent;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Yingyu.Update;

// A cached observation is never an upload. Like Android progress.dart, only an
// unchanged server checkpoint permits a durable pending edit to override it.
public static class ResumeDeviceSync
{
    const BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
    sealed record Checkpoint(string Item,string? Title);
    static readonly ConditionalWeakTable<EmbyApiClient,ConcurrentDictionary<string,Checkpoint>> Captured=new();
    static readonly ConditionalWeakTable<EmbyApiClient,ConcurrentDictionary<string,string>> ObservedTitles=new();
    sealed record ActivityScope(string Server,string User,string Url);
    static readonly ConditionalWeakTable<object,ActivityScope> Activities=new();
    static readonly SemaphoreSlim Files=new(1,1);
    public sealed record Baseline(string Session,long Position,long At,string Observed,string? TitleObserved=null);
    static string User(EmbyApiClient client)=>Access.Get<string?>(client,"_userId")??"";
    static string CaptureKey(string user,string item,string play)=>JsonSerializer.Serialize(new[]{user,item,play});
    static string Key(PendingPlaybackSyncEntry e)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[]{e.ServerId.ToUpperInvariant(),e.UserId.ToUpperInvariant(),e.Playback.ItemId.ToUpperInvariant()}))));
    static string PathFor(PendingPlaybackSyncStore store)=>Path.Combine(Path.GetDirectoryName(Access.Get<string>(store,"_filePath"))!,"server-baselines-v1.json");
    public static string Fingerprint(EmbyItem item)=>item.UserData is {} u?JsonSerializer.Serialize(new object?[]{u.PlaybackPositionTicks,u.LastPlayedDate?.UtcTicks,u.Played,u.GetType().GetProperty("PlayCount")?.GetValue(u)}):"";
    static string TitleKey(EmbyItem item)=>item.Type.Equals("Episode",StringComparison.OrdinalIgnoreCase)&&!string.IsNullOrEmpty(item.SeriesId)?"series:"+item.SeriesId:"item:"+item.Id;
    static string TitleFingerprint(EmbyItem item)=>JsonSerializer.Serialize(new[]{item.Id,Fingerprint(item)});
    public static void Remember(EmbyApiClient client,IEnumerable<EmbyItem> server)
    {
        var data=ObservedTitles.GetValue(client,_=>new());if(data.Count>512)data.Clear();
        foreach(var item in server)data[CaptureKey(User(client),TitleKey(item),"")]=TitleFingerprint(item);
    }
    public static void Capture(EmbyApiClient client,EmbyItem item,string play)
    {
        var data=Captured.GetValue(client,_=>new());if(data.Count>256)data.Clear();
        var value=Fingerprint(item);string? title=null;if(ObservedTitles.TryGetValue(client,out var observed))observed.TryGetValue(CaptureKey(User(client),TitleKey(item),""),out title);
        if(value.Length>0&&play.Length>0)data.TryAdd(CaptureKey(User(client),item.Id,play),new(value,title));
    }
    internal static void CaptureStop(EmbyApiClient client,EmbyItem item,string play)
    {
        if(string.IsNullOrWhiteSpace(play)||string.IsNullOrWhiteSpace(item.Id))return;
        var data=Captured.GetValue(client,_=>new());string? title=null;
        if(ObservedTitles.TryGetValue(client,out var observed))observed.TryGetValue(CaptureKey(User(client),TitleKey(item),""),out title);
        data[CaptureKey(User(client),item.Id,play)]=new(Fingerprint(item),title);
    }
    public static void CaptureMedia(object session)
    {
        if(session.GetType().GetField("_embyClient",Flags)?.GetValue(session) is EmbyApiClient client
            &&session.GetType().GetField("_item",Flags)?.GetValue(session) is EmbyItem item
            &&session.GetType().GetField("_playbackInfo",Flags)?.GetValue(session) is PlaybackInfoResponse info)Capture(client,item,info.PlaySessionId);
    }
    public static void CaptureActivity(object page,object? sender,object args)
    {
        var session=Access.Get<EmbySession?>(page,"_session");var client=Access.Get<EmbyApiClient?>(page,"_client");
        if(session==null||client==null||sender?.GetType().GetField("_embyClient",Flags)?.GetValue(sender) is not EmbyApiClient source)return;
        if(source.ServerUrl!=client.ServerUrl||User(source)!=session.UserId||User(client)!=session.UserId)return;
        Activities.GetValue(args,_=>new(session.ServerId,session.UserId,client.ServerUrl));
    }
    public static bool CanApplyActivity(object page,object args)
    {
        var session=Access.Get<EmbySession?>(page,"_session");var client=Access.Get<EmbyApiClient?>(page,"_client");
        return session!=null&&client!=null&&Activities.TryGetValue(args,out var owner)&&owner.Server==session.ServerId&&owner.User==session.UserId&&owner.Url==client.ServerUrl&&User(client)==session.UserId;
    }
    static bool Same(PendingPlaybackSyncEntry e,Baseline b)=>b.Session==e.Playback.PlaySessionId&&b.Position==e.Playback.PositionTicks&&b.At==e.UpdatedAt.UtcTicks;
    public static bool CanProject(PendingPlaybackSyncEntry e,EmbyItem remote,IReadOnlyDictionary<string,Baseline> bases,IEnumerable<EmbyItem> server)
    {
        if(!bases.TryGetValue(Key(e),out var b)||b==null||!Same(e,b)||string.IsNullOrEmpty(b.Observed)||b.Observed!=Fingerprint(remote))return false;
        var title=server.FirstOrDefault(i=>ResumeSeriesMergePolicy.RepresentsSameTitle(i,remote));
        return title==null||title.Id==remote.Id||b.TitleObserved!=null&&b.TitleObserved==TitleFingerprint(title);
    }
    public static async Task<Dictionary<string,Baseline>> LoadBaselines(PendingPlaybackSyncStore store)
    {
        await Files.WaitAsync();try{return Read(PathFor(store));}finally{Files.Release();}
    }
    static Dictionary<string,Baseline> Read(string path)
    {
        if(!File.Exists(path))return new();
        try{return JsonSerializer.Deserialize<Dictionary<string,Baseline>>(File.ReadAllText(path))??new();}
        catch(Exception e) when(e is IOException or UnauthorizedAccessException or JsonException){Warn("进度核对基线不可用，保留待同步记录",e);return new();}
    }
    static void Write(string path,Dictionary<string,Baseline> data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path+".tmp",JsonSerializer.Serialize(data));File.Move(path+".tmp",path,true);
    }
    public static async Task Save(object page,PlaybackRequest playback,bool completed)
    {
        var session=Access.Get<EmbySession?>(page,"_session");var client=Access.Get<EmbyApiClient?>(page,"_client");if(session==null||client==null)return;
        var store=Access.Get<PendingPlaybackSyncStore>(page,"_pendingPlaybackSyncStore");var entry=new PendingPlaybackSyncEntry(session.ServerId,session.UserId,playback,DateTimeOffset.UtcNow,completed);
        try{
            await Files.WaitAsync();try{
                await store.UpsertAsync(entry);
                if(Captured.TryGetValue(client,out var captures)&&captures.TryGetValue(CaptureKey(session.UserId,playback.ItemId,playback.PlaySessionId),out var baseline)){
                    var path=PathFor(store);var data=Read(path);data[Key(entry)]=new(playback.PlaySessionId,playback.PositionTicks,entry.UpdatedAt.UtcTicks,baseline.Item,baseline.Title);Write(path,data);
                }
            }finally{Files.Release();}
            if(!Current(page,session,client))return;
            Access.Set(page,"_playbackSyncRequested",true);
            await (Task)Access.Call(page,"RefreshPendingPlaybackSyncStatusAsync",CancellationToken.None)!;
            if(Access.Get<bool>(page,"_playbackSyncRequested")&&!Playing(page))await Drain(page);
        }catch(Exception e){Warn("待同步进度保留核对未完成",e);}
    }
    static bool Playing(object page)=>page.GetType().GetProperty("IsPlaybackActive",Flags)?.GetValue(page) is true;
    static bool Current(object page,EmbySession session,EmbyApiClient client)=>ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))&&ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))&&User(client)==session.UserId;
    static bool SameEntry(PendingPlaybackSyncEntry a,PendingPlaybackSyncEntry b)=>a.ServerId==b.ServerId&&a.UserId==b.UserId&&a.Playback.ItemId==b.Playback.ItemId&&a.Playback.PlaySessionId==b.Playback.PlaySessionId&&a.Playback.PositionTicks==b.Playback.PositionTicks&&a.UpdatedAt==b.UpdatedAt;
    static async Task<bool> Exists(PendingPlaybackSyncStore store,PendingPlaybackSyncEntry e,CancellationToken token)=>(await store.LoadAsync(e.ServerId,e.UserId,token)).Any(x=>SameEntry(x,e));
    static async Task Remove(PendingPlaybackSyncStore store,PendingPlaybackSyncEntry e,CancellationToken token)
    {
        await Files.WaitAsync(token);try{
            if(!await Exists(store,e,token))return;
            await store.RemoveAsync(e.ServerId,e.UserId,e.Playback.ItemId,e.Playback.PlaySessionId,token);
            var path=PathFor(store);var data=Read(path);if(data.TryGetValue(Key(e),out var b)&&b!=null&&Same(e,b)){data.Remove(Key(e));Write(path,data);}
        }finally{Files.Release();}
    }
    static void Status(object page,string text)=>Access.Get<TextBlock>(page,"PendingPlaybackSyncText").Text=text;
    static bool Confirmed(EmbyItem remote,PendingPlaybackSyncEntry e)=>ResumeStopSync.Confirmed(remote,e.Playback.PositionTicks,e.Completed);
    public static async Task Drain(object page)
    {
        if(Access.Get<bool>(page,"_playbackSyncInProgress")||!Access.Get<bool>(page,"_playbackSyncRequested")||Playing(page))return;
        var session=Access.Get<EmbySession?>(page,"_session");var client=Access.Get<EmbyApiClient?>(page,"_client");if(session==null||client==null)return;
        var store=Access.Get<PendingPlaybackSyncStore>(page,"_pendingPlaybackSyncStore");
        Access.Set(page,"_playbackSyncInProgress",true);Access.Set(page,"_playbackSyncRequested",false);
        Access.Get<CancellationTokenSource?>(page,"_playbackSyncCts")?.Cancel();Access.Get<CancellationTokenSource?>(page,"_playbackSyncCts")?.Dispose();
        using var source=new CancellationTokenSource();Access.Set(page,"_playbackSyncCts",source);var token=source.Token;
        Access.Get<Button>(page,"SyncPlaybackToEmbyButton").IsEnabled=false;Access.Get<ProgressRing>(page,"PlaybackSyncProgressRing").IsActive=true;Access.Get<ProgressRing>(page,"PlaybackSyncProgressRing").Visibility=Visibility.Visible;
        int done=0,conflicts=0;
        bool Active()=>!token.IsCancellationRequested&&Current(page,session,client)&&!Playing(page);
        try{
            await (Task)Access.Call(page,"WaitForPlaybackControlPlaneRecoveryAsync")!;
            if(!Active())return;
            var entries=await store.LoadAsync(session.ServerId,session.UserId,token);if(!Active())return;
            if(entries.Count==0){await (Task)Access.Call(page,"RefreshResumeItemsAsync",true)!;if(Active())Status(page,"继续观看已按当前服务器账号刷新。");return;}
            var fresh=await client.GetResumeAsync(cancellationToken:token);if(!Active())return;
            foreach(var e in entries){
                if(!Active())return;
                var remote=await client.GetItemAsync(e.Playback.ItemId,token);if(!Active()||!await Exists(store,e,token))return;
                if(!Confirmed(remote,e)){
                    if(!CanProject(e,remote,await LoadBaselines(store),fresh.Items)){conflicts++;continue;}
                    if(!Active())return;
                    await client.ReportPlaybackStoppedInBackgroundAsync(e.Playback,token);if(!Active())return;
                    remote=await client.GetItemAsync(e.Playback.ItemId,token);if(!Active()||!await Exists(store,e,token))return;
                    if(!Confirmed(remote,e)){
                        // Preserve the complete fresh user-data object, including fields
                        // absent from the old Windows DTO (e.g. PlayCount and Rating).
                        var raw=await new EmbyPeopleApi(client,session.UserId).Get($"Users/{Uri.EscapeDataString(session.UserId)}/Items/{Uri.EscapeDataString(e.Playback.ItemId)}",token);
                        if(!Active()||!await Exists(store,e,token))return;
                        var latest=JsonSerializer.Deserialize<EmbyItem>(raw.GetRawText(),new JsonSerializerOptions{PropertyNameCaseInsensitive=true})!;
                        if(!Confirmed(latest,e)){
                            if(Fingerprint(latest)!=Fingerprint(remote)){conflicts++;continue;}
                            await Correct(client,session.UserId,e,raw,token);if(!Active())return;
                            remote=await client.GetItemAsync(e.Playback.ItemId,token);if(!Active())return;
                        }else remote=latest;
                    }
                }
                if(Confirmed(remote,e)){await Remove(store,e,token);done++;}
            }
            if(!Active())return;
            await (Task)Access.Call(page,"RefreshPendingPlaybackSyncStatusAsync",token)!;
            var remaining=(await store.LoadAsync(session.ServerId,session.UserId,token)).Count;if(!Active())return;
            Status(page,remaining>0?$"已确认 {done} 条；仍有 {remaining} 条保留在本机"+(conflicts>0?"，服务器记录已变化或缺少核对基线。":"，等待服务器确认。"):$"已回读确认 {done} 条进度，正在更新继续观看。");
            await (Task)Access.Call(page,"RefreshResumeItemsAsync",true)!;
        }catch(OperationCanceledException){}
        catch(Exception e){if(Current(page,session,client)){if(e is EmbyApiException)Access.Set(page,"_playbackControlPlaneRecoveryUntil",PlaybackControlPlaneRecoveryPolicy.GetRecoveryUntil(DateTimeOffset.UtcNow));Status(page,"同步未完成，进度仍保留在本机。");}Warn("继续观看同步未完成",e);}
        finally{
            if(ReferenceEquals(source,Access.Get<CancellationTokenSource?>(page,"_playbackSyncCts"))){
                Access.Set(page,"_playbackSyncInProgress",false);Access.Set(page,"_playbackSyncCts",null);
                Access.Get<Button>(page,"SyncPlaybackToEmbyButton").IsEnabled=true;Access.Get<ProgressRing>(page,"PlaybackSyncProgressRing").IsActive=false;Access.Get<ProgressRing>(page,"PlaybackSyncProgressRing").Visibility=Visibility.Collapsed;
            }
        }
    }
    static async Task Correct(EmbyApiClient client,string userId,PendingPlaybackSyncEntry e,JsonElement raw,CancellationToken token)
    {
        if(raw.ValueKind!=JsonValueKind.Object||!raw.TryGetProperty("UserData",out var user)||user.ValueKind!=JsonValueKind.Object||!user.TryGetProperty("PlaybackPositionTicks",out _)||!user.TryGetProperty("Played",out _)||!user.TryGetProperty("IsFavorite",out _)||!user.TryGetProperty("PlayCount",out _))throw new InvalidDataException("服务器未提供完整用户数据，保留待同步记录");
        var body=JsonNode.Parse(user.GetRawText())!.AsObject();body["PlaybackPositionTicks"]=e.Completed?0:e.Playback.PositionTicks;body["Played"]=e.Completed||(e.Playback.PositionTicks>0&&user.GetProperty("Played").GetBoolean());
        var create=typeof(EmbyApiClient).GetMethods(Flags).Single(m=>m.Name=="CreateRequest"&&m.GetParameters().Length==3&&m.GetParameters()[1].ParameterType==typeof(string));
        using var request=(HttpRequestMessage)create.Invoke(client,new object[]{HttpMethod.Post,$"Users/{Uri.EscapeDataString(userId)}/Items/{Uri.EscapeDataString(e.Playback.ItemId)}/UserData",true})!;
        request.Content=new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json");
        var send=typeof(EmbyApiClient).GetMethods(Flags).Single(m=>m.Name=="SendNoContentAsync"&&m.GetParameters().Length==3);
        await (Task)send.Invoke(client,new object[]{request,token,ServerRequestPriority.Background})!;
    }
    static void Warn(string text,Exception e)=>PlaybackTransport.Write("Warning","Playback.Sync",text+"；"+e.GetType().Name);
}
