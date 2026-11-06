using System.Runtime.CompilerServices;
using System.Text.Json;
using EmbyDesktop.Core.Models;
using EmbyDesktop.Core.Services;
namespace Yingyu.Update;

// Read-side projection only. Never reports playback, writes UserData, changes
// completion, or turns ordinary cached observations into pending edits.
internal static class ResumeServerHistory
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
    internal static bool HomeCompleted(EmbyItem item)=>CompletedCards.TryGetValue(item,out _);
    internal static bool Rewatch(EmbyItem item)=>item.UserData is {Played:true,PlaybackPositionTicks:>0} data
        &&(item.RunTimeTicks is not >0||data.PlaybackPositionTicks<item.RunTimeTicks.Value);
    internal static bool Show(EmbyItem item)=>item.UserData?.Played!=true||Rewatch(item);
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
        if(!States.TryGetValue(page,out var state)||!ReferenceEquals(state.Session,session)
            ||!ReferenceEquals(state.Client,client)||state.Reading is not {IsCompletedSuccessfully:true})return;
        var recent=state.Reading.Result;
        var next=state.Next?.IsCompletedSuccessfully==true?state.Next.Result:state.NextItems;
        var cutoff=DateTimeOffset.UtcNow.AddMinutes(-15);
        var local=history.Where(i=>i.Type=="Episode"&&i.UserData?.LastPlayedDate>=cutoff)
            .GroupBy(Key,StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g=>g.Key,g=>g.OrderByDescending(i=>i.UserData?.LastPlayedDate).First(),StringComparer.OrdinalIgnoreCase);
        bool Same(EmbyItem row,string key)=>string.Equals(Key(row),key,StringComparison.OrdinalIgnoreCase);
        DateTimeOffset At(EmbyItem? row)=>row?.UserData?.LastPlayedDate??DateTimeOffset.MinValue;
        void Offer(EmbyItem candidate)
        {
            string key=Key(candidate);
            int existing=displayed.FindIndex(row=>Same(row,key));
            if(existing>=0)
            {
                var current=displayed[existing];
                if(!Waiting(current)&&(At(current)==DateTimeOffset.MinValue||At(current)>=At(candidate)))return;
                displayed.RemoveAt(existing);
            }
            if(!Show(candidate))CompletedCards.GetValue(candidate,_=>new object());
            int at=displayed.FindIndex(row=>At(row)<At(candidate));
            if(at<0)displayed.Add(candidate);else displayed.Insert(at,candidate);
        }
        foreach(var item in next)
        {
            if(!Waiting(item)||string.IsNullOrWhiteSpace(item.SeriesId))continue;
            string key=Key(item);
            var latestRemote=recent.Where(row=>Same(row,key)).MaxBy(At);
            var completion=edits.Where(e=>e.Completed&&Same(e.Item,key)).OrderByDescending(e=>e.At).FirstOrDefault();
            local.TryGetValue(key,out var saved);
            if(saved?.UserData is {PlaybackPositionTicks:>0,LastPlayedDate:{ } savedAt} progress&&Show(saved)
                &&(saved.RunTimeTicks is not >0||progress.PlaybackPositionTicks<saved.RunTimeTicks)
                &&savedAt>At(latestRemote)&&savedAt>At(item)&&savedAt>completion.At)
            {Offer(saved);continue;}

            var lastPlayed=new[]{latestRemote,saved,completion.Item}
                .OfType<EmbyItem>().Where(row=>At(row)>=At(item)).MaxBy(At);
            if(lastPlayed is not null&&!Show(lastPlayed)){Offer(lastPlayed);continue;}
            if(latestRemote is null&&item.IndexNumber is not >1&&item.ParentIndexNumber is not >1)continue;
            if(!displayed.Any(row=>Same(row,key)))displayed.Add(item);
        }
        // A finale need not have a NextUp row. Preserve a recent actual finish.
        var recentCompleted=local.Values.Concat(recent).Concat(edits.Where(e=>e.Completed).Select(e=>e.Item))
            .Where(row=>row.Type=="Episode"&&At(row)>=cutoff).GroupBy(Key,StringComparer.OrdinalIgnoreCase);
        foreach(var group in recentCompleted)
        {
            var latest=group.MaxBy(At)!;
            if(!Show(latest))Offer(latest);
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
        string path=$"Users/{Uri.EscapeDataString(session.UserId)}/Items?Limit=36&Recursive=true&IncludeItemTypes=Movie,Episode&MediaTypes=Video&SortBy=DatePlayed&SortOrder=Descending&Filters=IsPlayed&EnableUserData=true&EnableImages=true&ImageTypeLimit=1&EnableImageTypes=Primary,Thumb,Backdrop&Fields=ProviderIds,Overview,RunTimeTicks,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,Genres,OfficialRating,ProductionYear,CommunityRating";
        var json=await new EmbyPeopleApi(client,session.UserId).Get(path,timeout.Token);
        if(!json.TryGetProperty("Items",out var values)||values.ValueKind!=JsonValueKind.Array)throw new InvalidDataException("Missing recent history rows");
        var options=new JsonSerializerOptions{PropertyNameCaseInsensitive=true};
        return values.EnumerateArray().Take(36).Select(v=>JsonSerializer.Deserialize<EmbyItem>(v.GetRawText(),options)).OfType<EmbyItem>().Where(i=>!string.IsNullOrWhiteSpace(i.Id)).ToArray();
    }
    static IReadOnlyList<EmbyItem> Merge(IReadOnlyList<EmbyItem> resume,IReadOnlyList<EmbyItem> history)
    {
        var result=resume.ToList();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var candidate in history)
        {
            // Consume the newest title observation before filtering progress:
            // a latest completed-zero row must suppress older partial episodes.
            string key=Key(candidate);if(!seen.Add(key)||!Rewatch(candidate))continue;
            var current=result.FirstOrDefault(i=>Key(i).Equals(key,StringComparison.OrdinalIgnoreCase));
            var at=candidate.UserData?.LastPlayedDate;var before=current?.UserData?.LastPlayedDate;
            if(current!=null)
            {
                bool same=current.Id.Equals(candidate.Id,StringComparison.OrdinalIgnoreCase);
                if(same&&!(at.HasValue&&before.HasValue&&at.Value>before.Value))continue;
                if(!same&&current.UserData?.PlaybackPositionTicks>0&&!(at.HasValue&&before.HasValue&&at.Value>before.Value))continue;
                if(!same&&at.HasValue&&before.HasValue&&at.Value<before.Value)continue;
                result.Remove(current);
            }
            // Preserve the Resume endpoint's own relative order. Only insert
            // fresh history where explicit server dates establish its recency.
            int index=at.HasValue?result.FindIndex(i=>i.UserData?.LastPlayedDate is {} other&&at.Value>other):-1;
            if(index<0)result.Add(candidate);else result.Insert(index,candidate);
        }
        return ResumeSeriesMergePolicy.Collapse(result.Where(Show),18);
    }
    internal static string Caption(EmbyItem item,string fallback)
    {
        if(Waiting(item)&&item.IndexNumber is {} next)return (item.ParentIndexNumber is {} s?$"第 {s} 季 · ":"")+$"第 {next} 集 · 待播放";
        if(item.Type is "Series" or "Season")return fallback.Replace("已看完","已看至当前进度");
        if(item.UserData is null)return fallback;
        string episode=item.Type=="Episode"&&item.IndexNumber is {} number?(item.ParentIndexNumber is {} season?$"第 {season} 季 · 第 {number} 集 · ":$"第 {number} 集 · "):"";
        if(item.UserData.Played&&item.UserData.PlaybackPositionTicks==0)return episode+"已看完";
        if(item.UserData.PlaybackPositionTicks<=0||!Show(item))return fallback;
        string Stamp(long ticks){var time=TimeSpan.FromTicks(Math.Max(0,ticks));return time.TotalHours>=1?$"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}":$"{(int)time.TotalMinutes}:{time.Seconds:00}";}
        return episode+"继续 "+Stamp(item.UserData!.PlaybackPositionTicks)+(item.RunTimeTicks is >0?" / "+Stamp(item.RunTimeTicks.Value):"");
    }
}
