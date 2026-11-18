using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
using System.Text.Json;

namespace Yingyu.Update;

public static class ResumeSync
{
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<EmbyItem,object> Pending=new();
    sealed class AutoPending { internal string Stamp="";internal DateTimeOffset RetryAt; }
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<object,AutoPending> Auto=new();
    internal static void RequestPending(object page,EmbySession session,IReadOnlyList<PendingPlaybackSyncEntry> entries)
    {
        if(entries.Count==0)return;
        string stamp=JsonSerializer.Serialize(new object[]{session.ServerId,session.UserId,entries.OrderBy(e=>e.Playback.ItemId).Select(e=>new object[]{e.Playback.ItemId,e.Playback.PlaySessionId,e.Playback.PositionTicks,e.UpdatedAt.UtcTicks}).ToArray()});
        var state=Auto.GetOrCreateValue(page);if(state.Stamp==stamp&&DateTimeOffset.UtcNow<state.RetryAt)return;state.Stamp=stamp;state.RetryAt=DateTimeOffset.UtcNow.AddMinutes(1);
        Access.Set(page,"_playbackSyncRequested",true);
    }

    internal static bool IsPending(EmbyItem item)=>Pending.TryGetValue(item,out _);
    public static IReadOnlyList<EmbyItem> DisplayItems(IReadOnlyList<EmbyItem> items,bool landscape)
        => landscape ? ResumeSeriesMergePolicy.Collapse(items.Where(i=>ResumeServerHistory.Show(i)||ResumeServerHistory.HomeCompleted(i)),18) : items;
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

    internal static EmbyItem WithDuration(EmbyItem item, long? duration)
    {
        if (item.RunTimeTicks is > 0 || duration is not > 0 ||
            (item.UserData?.PlaybackPositionTicks ?? 0) >= duration.Value)
            return item;
        var json = JsonSerializer.SerializeToNode(item)!.AsObject();
        json["RunTimeTicks"] = duration.Value;
        var copy = json.Deserialize<EmbyItem>()!;
        copy.UserData = item.UserData;
        CopyPendingMarker(item, copy);
        return copy;
    }

    internal static long? MetadataDuration(JsonElement value)
    {
        static long? Runtime(JsonElement row)
            => row.ValueKind == JsonValueKind.Object &&
                row.TryGetProperty("RunTimeTicks", out var field) && field.ValueKind == JsonValueKind.Number && field.TryGetInt64(out long ticks) && ticks > 0
                    ? ticks : null;
        if (Runtime(value) is {} duration) return duration;
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("MediaSources", out var sources)
            || sources.ValueKind != JsonValueKind.Array) return null;
        var runtimes = sources.EnumerateArray().Select(Runtime).Distinct().Take(2).ToArray();
        return runtimes.Length == 1 ? runtimes[0] : null;
    }

    static bool NeedsPosition(EmbyItem item)
        => item.Type is not ("Series" or "Season")
            && (item.UserData is null || item.UserData is { Played: false, PlaybackPositionTicks: 0 });

    static Task<IReadOnlyList<EmbyItem>> ReadLocalHistory(object page)
        => (Task<IReadOnlyList<EmbyItem>>)Access.Call(page, "ReadLocalPlaybackHistoryAsync")!;

    static EmbyItem FillMissingPosition(EmbyItem item, IReadOnlyList<EmbyItem> history)
    {
        bool partial=item.Type is not ("Series" or "Season")&&item.UserData is {PlaybackPositionTicks:>0}
            &&ResumeServerHistory.Show(item);
        if (!NeedsPosition(item)&&!partial) return item;
        var saved = history.FirstOrDefault(candidate =>
            string.Equals(candidate.Id, item.Id, StringComparison.OrdinalIgnoreCase));
        if (saved?.UserData is not { Played: false, PlaybackPositionTicks: > 0, LastPlayedDate: { } savedAt } progress
            || partial&&(savedAt<DateTimeOffset.UtcNow.AddMinutes(-15)||item.UserData?.LastPlayedDate is null)
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
        var durations = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        if(missing.Count>0)
        {
            string ids=Uri.EscapeDataString(string.Join(',',missing));
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(6));
                var data = await new EmbyPeopleApi(client, session.UserId).Get(
                    $"Users/{Uri.EscapeDataString(session.UserId)}/Items?Ids={ids}&Limit=18&EnableUserData=true&Fields=Overview,RunTimeTicks,MediaSources,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags",
                    timeout.Token);
                if (data.TryGetProperty("Items", out var values) && values.ValueKind == JsonValueKind.Array)
                    foreach (var value in values.EnumerateArray().Take(18))
                    {
                        var item = JsonSerializer.Deserialize<EmbyItem>(value.GetRawText(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                        if (item == null || !missing.Contains(item.Id, StringComparer.OrdinalIgnoreCase)) continue;
                        metadata[item.Id] = item;
                        if (MetadataDuration(value) is {} duration) durations[item.Id] = duration;
                    }
            }
            catch (Exception error) when (error is HttpRequestException or IOException or JsonException or OperationCanceledException)
            {
                PlaybackTransport.Write("Info", "Library.Resume", "补充续播时长未完成，保留当前续播记录；" + error.GetType().Name);
            }
            if (!ReferenceEquals(client, Access.Get<EmbyApiClient?>(page, "_client")) || !ReferenceEquals(session, Access.Get<EmbySession?>(page, "_session"))) throw new OperationCanceledException();
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
            var projected = WithDuration(item, durations.TryGetValue(item.Id, out long duration) ? duration : full?.RunTimeTicks);
            if (projected.RunTimeTicks is > 0 || library.Versions.ContainsKey(scope + "|" + item.Id)) return projected;
            return WithDuration(item, history.FirstOrDefault(i => i.Id.Equals(item.Id, StringComparison.OrdinalIgnoreCase) && i.RunTimeTicks > 0)?.RunTimeTicks);
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
        ResumeServerHistory.AppendNext(page,session,client,merged,history,edits);
        if(Access.Get<DateTimeOffset>(page,"_lastLocalResumeUpdateAt")!=localRevision)throw new OperationCanceledException();
        return ResumeSeriesMergePolicy.Collapse(merged.Where(i=>ResumeServerHistory.Show(i)||ResumeServerHistory.HomeCompleted(i)),18);
    }

    public static async Task<EmbyItemsResponse> HistoryEpisodes(EmbyApiClient client,int limit,CancellationToken token,object page)
    {
        var session=Access.Get<EmbySession?>(page,"_session");
        bool Current()=>ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client"))
            &&ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"));
        var response=await client.GetResumeAsync(limit,token);
        if(!Current())throw new OperationCanceledException();
        var local=await ReadLocalHistory(page);
        if(!Current())throw new OperationCanceledException();
        // Keep the dedicated history by episode ID. A series-level resume API
        // may expose only its latest episode even if older episodes have progress.
        var items=response.Items.Concat(local.Where(i=>i.Type=="Episode"&&i.UserData?.LastPlayedDate is not null
            &&(i.UserData.Played||i.UserData.PlaybackPositionTicks>0))).Where(i=>!string.IsNullOrWhiteSpace(i.Id))
            .GroupBy(i=>i.Id,StringComparer.OrdinalIgnoreCase).Select(NewestEpisode)
            .OrderByDescending(i=>i.UserData?.LastPlayedDate).Take(100).ToList();
        return new(){Items=items,TotalRecordCount=items.Count};
    }

    public static EmbyItem NewestEpisode(IEnumerable<EmbyItem> rows)
    {
        var ordered = rows.OrderByDescending(row => row.UserData?.LastPlayedDate)
            .ThenByDescending(row => row.UserData is { Played: true, PlaybackPositionTicks: 0 }).ToArray();
        return WithDuration(ordered[0], ordered.FirstOrDefault(row => row.RunTimeTicks > (ordered[0].UserData?.PlaybackPositionTicks ?? 0))?.RunTimeTicks);
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

    internal static void CopyPendingMarker(EmbyItem item,EmbyItem copy)
    {if(IsPending(item))Pending.GetValue(copy,_=>new object());}
}
