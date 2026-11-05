using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using System.Text.Json;

namespace Yingyu.Update;

public static class ResumeSync
{
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<EmbyItem,object> Pending=new();
    sealed class AutoPending { internal string Stamp="";internal DateTimeOffset RetryAt; }
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<object,AutoPending> Auto=new();
    static void RequestPending(object page,EmbySession session,IReadOnlyList<PendingPlaybackSyncEntry> entries)
    {
        if(entries.Count==0)return;
        string stamp=JsonSerializer.Serialize(new object[]{session.ServerId,session.UserId,entries.OrderBy(e=>e.Playback.ItemId).Select(e=>new object[]{e.Playback.ItemId,e.Playback.PlaySessionId,e.Playback.PositionTicks,e.UpdatedAt.UtcTicks}).ToArray()});
        var state=Auto.GetOrCreateValue(page);if(state.Stamp==stamp&&DateTimeOffset.UtcNow<state.RetryAt)return;state.Stamp=stamp;state.RetryAt=DateTimeOffset.UtcNow.AddMinutes(1);
        Access.Set(page,"_playbackSyncRequested",true);
    }

    internal static bool IsPending(EmbyItem item)=>Pending.TryGetValue(item,out _);
    public static IReadOnlyList<EmbyItem> DisplayItems(IReadOnlyList<EmbyItem> items,bool landscape)
        => landscape ? ResumeSeriesMergePolicy.Collapse(items.Where(ResumeServerHistory.Show),18) : items;
    public static IReadOnlyList<EmbyItem> ServerItems(IEnumerable<EmbyItem> server,
        IEnumerable<EmbyItem> observations, int limit)
        => limit <= 0 ? [] : ResumeSeriesMergePolicy.Collapse(server, limit);
    // The resume readers used to mutate the fresh response from ordinary disk
    // history before History saw it. Preserve the response; History applies the
    // durable upload queue once, on copies, including explicit zero/completion.
    public static Task KeepServer(object page, IEnumerable<EmbyItem> items) => Task.CompletedTask;
    public static Task<IReadOnlyList<EmbyItem>> NoCachedPending(object page)
        => Task.FromResult<IReadOnlyList<EmbyItem>>([]);
    // Ordinary history is an observation, not a pending edit. The actual upload
    // queue below is the only source allowed to override a server observation.
    public static IReadOnlyList<EmbyItem> Merge(IEnumerable<EmbyItem> server,
        IEnumerable<(EmbyItem Item, bool Completed, DateTimeOffset At)> pending, int limit = 18)
    {
        var result = server.ToList();
        foreach (var edit in pending.OrderBy(e => e.At))
        {
            bool Same(EmbyItem item) => ResumeSeriesMergePolicy.RepresentsSameTitle(item, edit.Item);
            if (result.Any(item => Same(item) && item.UserData?.LastPlayedDate > edit.At)) continue;
            result.RemoveAll(Same);
            if (!edit.Completed) result.Insert(0, edit.Item);
        }
        return ResumeSeriesMergePolicy.Collapse(result.Where(ResumeServerHistory.Show), limit);
    }

    static bool NeedsPosition(EmbyItem item)
        => item.Type is not ("Series" or "Season")
            && (item.UserData is null || item.UserData is { Played: false, PlaybackPositionTicks: 0 });

    static Task<IReadOnlyList<EmbyItem>> ReadLocalHistory(object page)
        => (Task<IReadOnlyList<EmbyItem>>)Access.Call(page, "ReadLocalPlaybackHistoryAsync")!;

    static EmbyItem FillMissingPosition(EmbyItem item, IReadOnlyList<EmbyItem> history)
    {
        if (!NeedsPosition(item)) return item;
        var saved = history.FirstOrDefault(candidate =>
            string.Equals(candidate.Id, item.Id, StringComparison.OrdinalIgnoreCase));
        if (saved?.UserData is not { Played: false, PlaybackPositionTicks: > 0, LastPlayedDate: { } savedAt } progress
            || item.UserData?.LastPlayedDate >= savedAt
            || (item.RunTimeTicks is > 0 && progress.PlaybackPositionTicks >= item.RunTimeTicks.Value))
            return item;

        // Restore only playback fields on a copy. Keep raw server observations
        // and the pending upload/fingerprint checks independent of this fallback.
        var copy = JsonSerializer.SerializeToNode(item)!.AsObject();
        var data = copy["UserData"] as System.Text.Json.Nodes.JsonObject;
        if (data is null)
        {
            data = new System.Text.Json.Nodes.JsonObject();
            copy["UserData"] = data;
        }
        data["PlaybackPositionTicks"] = progress.PlaybackPositionTicks;
        data["LastPlayedDate"] = savedAt;
        if (item.RunTimeTicks is not > 0 && saved.RunTimeTicks is > 0)
            copy["RunTimeTicks"] = saved.RunTimeTicks.Value;
        data["PlayedPercentage"] = progress.PlayedPercentage;
        return copy.Deserialize<EmbyItem>()!;
    }

    internal static async Task<EmbyItem> RestoreForQuickPlay(object page, EmbyItem item)
    {
        if (!NeedsPosition(item)) return item;
        var session = Access.Get<EmbySession?>(page, "_session");
        var client = Access.Get<EmbyApiClient?>(page, "_client");
        if (session is null || client is null) return item;
        var history = await ReadLocalHistory(page);
        if (!ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))
            || !ReferenceEquals(client, Access.Get<EmbyApiClient?>(page, "_client")))
            throw new OperationCanceledException();
        return FillMissingPosition(item, history);
    }

    public static async Task<IReadOnlyList<EmbyItem>> History(object page, IEnumerable<EmbyItem> server)
    {
        var session = Access.Get<EmbySession?>(page, "_session");
        var client = Access.Get<EmbyApiClient?>(page, "_client");
        if (session == null || client == null) return server.ToList();
        var localRevision=Access.Get<DateTimeOffset>(page,"_lastLocalResumeUpdateAt");
        var store = Access.Get<PendingPlaybackSyncStore>(page, "_pendingPlaybackSyncStore");
        var entries = await store.LoadAsync(session.ServerId, session.UserId);
        if (!ReferenceEquals(client, Access.Get<EmbyApiClient?>(page, "_client")) || !ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))) throw new OperationCanceledException();
        RequestPending(page,session,entries);
        var observed = server.ToList();
        observed=(await ResumeServerHistory.Read(page,session,client,observed)).ToList();
        if(!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))||!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session")))throw new OperationCanceledException();
        ResumeDeviceSync.Remember(client,observed);
        var baselines = await ResumeDeviceSync.LoadBaselines(store);
        if (!ReferenceEquals(client, Access.Get<EmbyApiClient?>(page, "_client")) || !ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))) throw new OperationCanceledException();
        var metadata = new Dictionary<string,EmbyItem>(StringComparer.OrdinalIgnoreCase);
        foreach(var entry in entries.OrderByDescending(e=>e.UpdatedAt))
        {
            var item=observed.FirstOrDefault(i=>i.Id.Equals(entry.Playback.ItemId,StringComparison.OrdinalIgnoreCase));
            if(item!=null)metadata[entry.Playback.ItemId]=item;
        }
        var missing=entries.OrderByDescending(e=>e.UpdatedAt).Select(e=>e.Playback.ItemId).Concat(observed.Where(i=>i.RunTimeTicks is not >0&&i.UserData?.PlaybackPositionTicks>0).Select(i=>i.Id))
            .Where(id=>!metadata.TryGetValue(id,out var known)||known.RunTimeTicks is not >0).Distinct(StringComparer.OrdinalIgnoreCase).Take(18).ToList();
        if(missing.Count>0)
        {
            string ids=Uri.EscapeDataString(string.Join(',',missing));
            var data=await new EmbyPeopleApi(client,session.UserId).Get($"Users/{Uri.EscapeDataString(session.UserId)}/Items?Ids={ids}&Limit=18&EnableUserData=true&Fields=Overview,RunTimeTicks,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags",CancellationToken.None);
            if (!ReferenceEquals(client, Access.Get<EmbyApiClient?>(page, "_client")) || !ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))) throw new OperationCanceledException();
            if(data.TryGetProperty("Items",out var values)&&values.ValueKind==JsonValueKind.Array)
            foreach(var value in values.EnumerateArray())
            {
                var item=JsonSerializer.Deserialize<EmbyItem>(value.GetRawText(),new JsonSerializerOptions{PropertyNameCaseInsensitive=true});
                if(item!=null&&missing.Contains(item.Id,StringComparer.OrdinalIgnoreCase))metadata[item.Id]=item;
            }
        }
        var library=Access.Get<DesktopLibraryState>(page,"_desktopState");
        var scope=DesktopLibraryStore.Scope(session);
        var history=await ReadLocalHistory(page);
        if(!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))||!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session")))throw new OperationCanceledException();
        // Reuse the existing bounded metadata batch to recover missing duration.
        // Retain the current observation's user data and account reconciliation.
        observed=observed.Select(item=>{
            if(item.RunTimeTicks is >0)return item;
            metadata.TryGetValue(item.Id,out var full);
            long? duration=full?.RunTimeTicks;
            if(duration is not >0&&!library.Versions.ContainsKey(scope+"|"+item.Id))duration=history.FirstOrDefault(i=>i.Id==item.Id&&i.RunTimeTicks>0)?.RunTimeTicks;
            if(duration is not >0||item.UserData?.PlaybackPositionTicks>duration)return item;
            var copy=System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(item))!.AsObject();
            copy["RunTimeTicks"]=duration.Value;return copy.Deserialize<EmbyItem>()!;
        }).ToList();
        var edits = new List<(EmbyItem Item, bool Completed, DateTimeOffset At)>();
        foreach (var entry in entries)
        {
            if(!metadata.TryGetValue(entry.Playback.ItemId,out var item))continue;
            if(!ResumeDeviceSync.CanProject(entry,item,baselines,observed))continue;
            // Do not modify a cached/server object when projecting a local edit.
            var copy = JsonSerializer.Deserialize<EmbyItem>(JsonSerializer.Serialize(item))!;
            copy.UserData = (EmbyUserData)page.GetType().GetMethod("CreatePendingPlaybackUserData", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public)!.Invoke(null, [copy, copy.UserData, entry])!;
            if(item.UserData!=null&&copy.UserData.GetType().GetProperty("PlayCount") is {} count)count.SetValue(copy.UserData,count.GetValue(item.UserData));
            Pending.GetValue(copy,_=>new object());
            edits.Add((copy, entry.Completed, entry.UpdatedAt));
        }
        // These edits have already passed exact server-baseline and episode
        // checks. Do not veto them again using the device's wall clock.
        var merged=observed.Select(item => FillMissingPosition(item, history)).ToList();
        foreach(var edit in edits.OrderBy(e=>e.At)){
            merged.RemoveAll(i=>ResumeSeriesMergePolicy.RepresentsSameTitle(i,edit.Item)&&(!edit.Completed||i.Id.Equals(edit.Item.Id,StringComparison.OrdinalIgnoreCase)));
            if(!edit.Completed)merged.Insert(0,edit.Item);
        }
        if(Access.Get<DateTimeOffset>(page,"_lastLocalResumeUpdateAt")!=localRevision)throw new OperationCanceledException();
        return ResumeSeriesMergePolicy.Collapse(merged.Where(ResumeServerHistory.Show),18);
    }

    public static void Home(object page)
    {
        if(page is Microsoft.UI.Xaml.FrameworkElement){ResumeRefresh.Home(page);return;}
        if(Access.Get<string?>(page,"_activeSnapshotKey")!="home"||DateTimeOffset.UtcNow-Access.Get<DateTimeOffset>(page,"_lastResumeRefreshAt")<TimeSpan.FromMinutes(1))return;
        Observe((Task)Access.Call(page,"RefreshResumeItemsAsync",false)!);
    }
    static async void Observe(Task work)
    {
        try { await work; }
        catch (OperationCanceledException) { }
        catch (Exception error) { PlaybackTransport.Write("Warning", "Library.Resume", "继续观看核对未完成，保留已有内容；" + error.GetType().Name); }
    }
}
