using System.Runtime.CompilerServices;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
namespace Yingyu.Update;

// Read-side projection only. Never reports playback, writes UserData, changes
// completion, or turns ordinary cached observations into pending edits.
public static class ResumeServerHistory
{
    sealed class State
    {
        internal EmbySession? Session;internal EmbyApiClient? Client;internal DateTimeOffset At;
        internal Task<IReadOnlyList<EmbyItem>>? Reading;
        internal Task<IReadOnlyList<EmbyItem>>? Next;
        internal IReadOnlyList<EmbyItem> NextItems=[];
    }
    static readonly ConditionalWeakTable<object,State> States=new();
    static readonly ConditionalWeakTable<EmbyItem,object> CompletedCards=new();
    internal static bool HomeCompleted(EmbyItem item)=>!Show(item)
        &&(CompletedCards.TryGetValue(item,out _)||item.UserData is {PlaybackPositionTicks:0,PlayedPercentage:100});
    static bool Playable(EmbyItem item)=>item.Type is "Movie" or "Episode";
    static EmbyUserData Completed(EmbyUserData progress,EmbyUserData? saved)=>new()
    {
        Played=true,PlaybackPositionTicks=0,PlayedPercentage=100,LastPlayedDate=progress.LastPlayedDate,
        IsFavorite=saved?.IsFavorite??progress.IsFavorite,PlayCount=saved?.PlayCount??progress.PlayCount
    };

    public static bool ApplyLiveActivity(List<EmbyItem> items,EmbyUserData progress)
    {
        if(!progress.Played)
        {
            foreach(var item in items)CompletedCards.Remove(item);
            return progress.PlaybackPositionTicks>0;
        }
        foreach(var item in items)
        {
            item.UserData=Completed(progress,item.UserData);
            CompletedCards.GetValue(item,_=>new object());
        }
        return true;
    }

    public static void TrackLiveActivity(Dictionary<string,(EmbyItem Item,DateTimeOffset At)> pending,
        string id,(EmbyItem Item,DateTimeOffset At) activity)
    {
        if(activity.Item.UserData?.Played==true)pending.Remove(id);
        else pending[id]=activity;
    }

    static EmbyItem CompletedCard(EmbyItem item)
    {
        if(item.UserData is not {} data)return item;
        // Keep the source observation and its upload fingerprint intact.
        var copy=JsonSerializer.Deserialize<EmbyItem>(JsonSerializer.Serialize(item))!;
        copy.UserData=Completed(data,data);
        ResumeSync.CopyPendingMarker(item,copy);
        CompletedCards.GetValue(copy,_=>new object());
        return copy;
    }
    internal static bool Rewatch(EmbyItem item)=>item.UserData is {Played:true,PlaybackPositionTicks:>0} data
        &&(item.RunTimeTicks is not >0||data.PlaybackPositionTicks<item.RunTimeTicks.Value);
    internal static bool Show(EmbyItem item)=>item.UserData?.Played!=true||Rewatch(item);
    static bool HasViewingHistory(EmbyItem item)=>Playable(item)&&!string.IsNullOrWhiteSpace(item.Id)
        &&(item.UserData is {PlaybackPositionTicks:>0} progress
            &&(item.RunTimeTicks is not >0||progress.PlaybackPositionTicks<item.RunTimeTicks.Value)
            ||item.UserData is {Played:true,PlaybackPositionTicks:0});
    static Dictionary<string,int> ServerOrder(IEnumerable<EmbyItem> history)
    {
        var order=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
        foreach(var item in history.Where(HasViewingHistory))order.TryAdd(item.Id,order.Count);
        return order;
    }
    static bool IsNewer(EmbyItem item,EmbyItem current,Dictionary<string,int> order)
    {
        var at=item.UserData?.LastPlayedDate;
        var before=current.UserData?.LastPlayedDate;
        return at.HasValue&&before.HasValue?at.Value>before.Value
            :order.TryGetValue(item.Id,out var rank)&&order.TryGetValue(current.Id,out var currentRank)&&rank<currentRank;
    }
    static string Key(EmbyItem item)=>item.Type.Equals("Episode",StringComparison.OrdinalIgnoreCase)&&!string.IsNullOrWhiteSpace(item.SeriesId)?"series:"+item.SeriesId:"item:"+item.Id;
    internal static async Task<IReadOnlyList<EmbyItem>> Read(object page,EmbySession session,EmbyApiClient client,IReadOnlyList<EmbyItem> resume)
    {
        var state=States.GetOrCreateValue(page);var now=DateTimeOffset.UtcNow;
        if(!ReferenceEquals(state.Session,session)||!ReferenceEquals(state.Client,client))
        {state.Session=session;state.Client=client;state.Reading=null;state.Next=null;state.NextItems=[];state.At=default;}
        // Coalesce only overlapping/near-identical homepage reads. Foreground
        // resume refresh is already rate-limited; there is no new timer/poller.
        if(state.Reading==null||state.Reading.IsCompleted&&now-state.At>TimeSpan.FromSeconds(5))
        {
            if(state.Next?.IsCompletedSuccessfully==true)state.NextItems=state.Next.Result;
            state.At=now;state.Reading=Fetch(session,client);state.Next=FetchNext(session,client);
        }
        IReadOnlyList<EmbyItem> recent;var reading=state.Reading;
        try{recent=await reading;}
        catch(Exception error)
        {
            if(ReferenceEquals(state.Reading,reading))state.Reading=null;
            try{PlaybackTransport.Write("Warning","Library.Resume","服务端重看记录核对未完成，保留原继续观看读取；"+error.GetType().Name);}catch(Exception){}
            return resume;
        }
        if(!ReferenceEquals(session,Access.Get<EmbySession?>(page,"_session"))||!ReferenceEquals(client,Access.Get<EmbyApiClient?>(page,"_client")))throw new OperationCanceledException();
        return Merge(resume,recent);
    }

    internal static bool Waiting(EmbyItem item)=>item.Type=="Episode"
        &&item.UserData is {Played:false,PlaybackPositionTicks:0};

    internal static void AppendNext(object page,EmbySession session,EmbyApiClient client,
        List<EmbyItem> displayed,IReadOnlyList<EmbyItem> history,IReadOnlyList<(EmbyItem Item,bool Completed,DateTimeOffset At)> edits)
    {
        bool sameAccount=States.TryGetValue(page,out var state)&&ReferenceEquals(state.Session,session)
            &&ReferenceEquals(state.Client,client);
        IReadOnlyList<EmbyItem> recent=sameAccount&&state!.Reading is {IsCompletedSuccessfully:true} reading?reading.Result:[];
        IReadOnlyList<EmbyItem> next=sameAccount?(state!.Next is {IsCompletedSuccessfully:true} following?following.Result:state.NextItems):[];
        var rows = new Dictionary<string, EmbyItem>(StringComparer.OrdinalIgnoreCase);
        var order = ServerOrder(recent);
        foreach (var item in displayed.Where(row => Show(row) || HomeCompleted(row)))
            if (!string.IsNullOrWhiteSpace(item.Id)) rows.TryAdd(Key(item), item);

        void Offer(EmbyItem item, bool local = false)
        {
            var key = Key(item);
            var at = item.UserData?.LastPlayedDate;
            if (rows.TryGetValue(key, out var current))
            {
                if (local && HomeCompleted(current) && current.Id.Equals(item.Id, StringComparison.OrdinalIgnoreCase)) return;
                var before = current.UserData?.LastPlayedDate;
                bool newer = IsNewer(item,current,order);
                bool sameLocal = local && current.Id.Equals(item.Id, StringComparison.OrdinalIgnoreCase)
                    && (!before.HasValue || at.HasValue && at.Value >= before.Value);
                if (!newer && !sameLocal) return;
            }
            rows[key] = CompletedCard(item);
        }

        var historyTitles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in recent)
        {
            if (!HasViewingHistory(item) || !historyTitles.Add(Key(item))) continue;
            if (item.UserData.PlaybackPositionTicks == 0) Offer(item);
        }
        foreach (var item in history.Where(item => Playable(item) && item.UserData?.Played == true)
            .Concat(edits.Where(edit => edit.Completed).Select(edit => edit.Item)))
            if (item.UserData?.LastPlayedDate is not null) Offer(item, local: true);

        displayed.Clear();
        displayed.AddRange(rows.Values.OrderBy(item => order.GetValueOrDefault(item.Id, int.MaxValue))
            .ThenByDescending(item => item.UserData?.LastPlayedDate));
        foreach (var item in next)
        {
            if (!Waiting(item) || string.IsNullOrWhiteSpace(item.SeriesId)) continue;
            var key = Key(item);
            if (!historyTitles.Contains(key) && item.IndexNumber is not >1 && item.ParentIndexNumber is not >1) continue;
            if (rows.TryAdd(key, item)) displayed.Add(item);
        }
    }
    static async Task<IReadOnlyList<EmbyItem>> FetchNext(EmbySession session,EmbyApiClient client)
    {
        try{
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(6));
            var json=await new EmbyPeopleApi(client,session.UserId).Get($"Shows/NextUp?UserId={Uri.EscapeDataString(session.UserId)}&Limit=18&EnableUserData=true&EnableImages=true&ImageTypeLimit=1&EnableImageTypes=Primary,Thumb,Backdrop&Fields=RunTimeTicks,Overview,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags",timeout.Token);
            if(!json.TryGetProperty("Items",out var rows)||rows.ValueKind!=JsonValueKind.Array)return [];
            var options=new JsonSerializerOptions{PropertyNameCaseInsensitive=true};
            return rows.EnumerateArray().Take(18).Select(v=>JsonSerializer.Deserialize<EmbyItem>(v.GetRawText(),options)).OfType<EmbyItem>().Where(i=>!string.IsNullOrWhiteSpace(i.Id)).ToArray();
        }catch(Exception error){PlaybackTransport.Write("Info","Library.Resume","下一集资料暂不可用，保留已有继续观看；"+error.GetType().Name);return [];}
    }
    static async Task<IReadOnlyList<EmbyItem>> Fetch(EmbySession session,EmbyApiClient client)
    {
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(8));
        string path=$"Users/{Uri.EscapeDataString(session.UserId)}/Items?Limit=48&Recursive=true&IncludeItemTypes=Movie,Episode&MediaTypes=Video&SortBy=DatePlayed,SortName&SortOrder=Descending&GroupItemsIntoCollections=false&EnableTotalRecordCount=false&EnableUserData=true&EnableImages=true&ImageTypeLimit=1&EnableImageTypes=Primary,Thumb,Backdrop&Fields=ProviderIds,Overview,RunTimeTicks,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,Genres,OfficialRating,ProductionYear,CommunityRating";
        var json=await new EmbyPeopleApi(client,session.UserId).Get(path,timeout.Token);
        if(!json.TryGetProperty("Items",out var values)||values.ValueKind!=JsonValueKind.Array)throw new InvalidDataException("Missing recent history rows");
        var options=new JsonSerializerOptions{PropertyNameCaseInsensitive=true};
        return values.EnumerateArray().Take(48).Select(v=>JsonSerializer.Deserialize<EmbyItem>(v.GetRawText(),options)).OfType<EmbyItem>().Where(i=>!string.IsNullOrWhiteSpace(i.Id)).ToArray();
    }
    static IReadOnlyList<EmbyItem> Merge(IReadOnlyList<EmbyItem> resume,IReadOnlyList<EmbyItem> history)
    {
        var result=resume.Where(Show).ToList();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var durations = resume.Concat(history).Where(item => item.RunTimeTicks is > 0)
            .ToLookup(item => item.Id, StringComparer.OrdinalIgnoreCase);
        var order=ServerOrder(history);
        foreach(var candidate in history)
        {
            // Consume the newest title observation before filtering progress:
            // a latest completed-zero row must suppress older partial episodes.
            string key=Key(candidate);if(!HasViewingHistory(candidate)||!seen.Add(key)||candidate.UserData!.PlaybackPositionTicks<=0)continue;
            int index = result.FindIndex(item => Key(item).Equals(key, StringComparison.OrdinalIgnoreCase));
            if (index < 0)
            {
                result.Add(candidate);
                continue;
            }
            if (IsNewer(candidate, result[index], order)) result[index] = candidate;
        }
        for (int i = 0; i < result.Count; i++)
        {
            var row = result[i];
            if (row.RunTimeTicks is > 0 || row.UserData is not { PlaybackPositionTicks: > 0 } progress) continue;
            var runtime = durations[row.Id].FirstOrDefault(observation => observation.RunTimeTicks > progress.PlaybackPositionTicks);
            result[i] = ResumeSync.WithDuration(row, runtime?.RunTimeTicks);
        }
        return ResumeSeriesMergePolicy.Collapse(result.Where(Show),result.Count);
    }
    internal static string Caption(EmbyItem item,string fallback)
    {
        var numbers=EpisodeLabels.DisplayNumbers(item);
        string episode=(numbers.Season is {} season?$"第 {season} 季 · ":"")+(numbers.Episode is {} number?$"第 {number} 集 · ":"");
        if(Waiting(item))return episode+"待播放";
        if(item.Type is "Series" or "Season")return fallback.Replace("已看完","已看至当前进度");
        if(item.UserData is null)return fallback;
        if(!Show(item))return episode+"已看完";
        if(item.UserData.PlaybackPositionTicks<=0||!Show(item))return fallback;
        string Stamp(long ticks){var time=TimeSpan.FromTicks(Math.Max(0,ticks));return time.TotalHours>=1?$"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}":$"{(int)time.TotalMinutes}:{time.Seconds:00}";}
        return episode+"继续 "+Stamp(item.UserData!.PlaybackPositionTicks)+(item.RunTimeTicks is >0?" / "+Stamp(item.RunTimeTicks.Value):"");
    }
}
